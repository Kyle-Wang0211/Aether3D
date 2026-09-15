// dense_fuse.cc — see dense_fuse.h for provenance. Every numbered comment "filter.py:N" is a
// line of cvg/diffmvs filter.py (HEAD cd10d5c); "fuse_official.py" is the certified producer.
#include "dense_fuse.h"

#include <opencv2/core.hpp>
#include <opencv2/imgproc.hpp>   // cv::remap — filter.py:41 cv2.remap(..., interpolation=cv2.INTER_LINEAR)

#include <algorithm>
#include <cfloat>
#include <cmath>
#include <cstdio>
#include <cstring>

namespace aether::dense {

int g_fuse_matmul_mode = 1;   // see dense_fuse.h: measured against the reference, not chosen

// ---------------------------------------------------------------------------------------------
// numpy float64 matmul (reference side: BLAS dgemm). k-term dot products with a selectable
// accumulation pattern (see g_fuse_matmul_mode). n <= 4.
static inline double dotk(const double* a, int astride, const double* b, int bstride, int n) {
    const int mode = g_fuse_matmul_mode;
    double acc;
    if (mode < 2) {
        acc = a[0] * b[0];
        for (int k = 1; k < n; ++k) {
            const double x = a[k * astride], y = b[k * bstride];
            acc = (mode == 1) ? std::fma(x, y, acc) : acc + x * y;
        }
    } else {
        acc = a[(n - 1) * astride] * b[(n - 1) * bstride];
        for (int k = n - 2; k >= 0; --k) {
            const double x = a[k * astride], y = b[k * bstride];
            acc = (mode == 3) ? std::fma(x, y, acc) : acc + x * y;
        }
    }
    return acc;
}
// out(3) = M(3x3 row-major) @ v(3)
static inline void mat3vec(const double* M, const double* v, double* out) {
    for (int r = 0; r < 3; ++r) out[r] = dotk(M + r * 3, 1, v, 1, 3);
}
// out(4) = M(4x4 row-major) @ v(4)
static inline void mat4vec(const double* M, const double* v, double* out) {
    for (int r = 0; r < 4; ++r) out[r] = dotk(M + r * 4, 1, v, 1, 4);
}
// C = A @ B, all 4x4 row-major
static inline void mat4mul(const double* A, const double* B, double* C) {
    for (int r = 0; r < 4; ++r)
        for (int c = 0; c < 4; ++c) C[r * 4 + c] = dotk(A + r * 4, 1, B + c, 4, 4);
}

// ---------------------------------------------------------------------------------------------
// numpy.linalg.inv(a) == LAPACK ?gesv(a, identity)  (numpy/linalg/umath_linalg.cpp, inv -> gesv).
// Reference LAPACK dgetf2.f (unblocked LU, partial pivoting) + dgetrs.f (dlaswp, dtrsm L unit,
// dtrsm U non-unit), ported with the same loop order and the same idamax/dscal/dger/dtrsm
// element operations. Column-major working copy, n <= 4.
bool lapack_inv(int n, const double* A_rm, double* out_rm) {
    double a[16], b[16];
    int ipiv[4];
    for (int i = 0; i < n; ++i)
        for (int j = 0; j < n; ++j) { a[i + j * n] = A_rm[i * n + j]; b[i + j * n] = (i == j) ? 1.0 : 0.0; }
    const double sfmin = DBL_MIN;  // dlamch('S') for IEEE double
    // ---- dgetf2 ----
    for (int j = 0; j < n; ++j) {
        // JP = J-1 + IDAMAX(M-J+1, A(J,J), 1): first index of max |.|
        int jp = j; double amax = std::fabs(a[j + j * n]);
        for (int i = j + 1; i < n; ++i) { const double v = std::fabs(a[i + j * n]); if (v > amax) { amax = v; jp = i; } }
        ipiv[j] = jp;
        if (a[jp + j * n] != 0.0) {
            if (jp != j) for (int k = 0; k < n; ++k) std::swap(a[j + k * n], a[jp + k * n]);   // DSWAP(N, A(J,1), LDA, A(JP,1), LDA)
            if (j < n - 1) {
                const double d = a[j + j * n];
                if (std::fabs(d) >= sfmin) { const double r = 1.0 / d; for (int i = j + 1; i < n; ++i) a[i + j * n] *= r; }  // DSCAL(M-J, ONE/A(J,J), ...)
                else for (int i = j + 1; i < n; ++i) a[i + j * n] /= d;
            }
        } else {
            return false;  // INFO = J (singular)
        }
        if (j < n - 1) {
            // DGER(M-J, N-J, -ONE, A(J+1,J), 1, A(J,J+1), LDA, A(J+1,J+1), LDA):
            //   TEMP = ALPHA*Y(JY); A(I,J) = A(I,J) + X(I)*TEMP
            for (int k = j + 1; k < n; ++k) {
                const double yk = a[j + k * n];
                if (yk != 0.0) { const double temp = -1.0 * yk; for (int i = j + 1; i < n; ++i) a[i + k * n] = a[i + k * n] + a[i + j * n] * temp; }
            }
        }
    }
    // ---- dgetrs (NoTrans) ----
    for (int i = 0; i < n; ++i)                       // DLASWP(NRHS, B, LDB, 1, N, IPIV, 1)
        if (ipiv[i] != i) for (int k = 0; k < n; ++k) std::swap(b[i + k * n], b[ipiv[i] + k * n]);
    for (int j = 0; j < n; ++j) {                     // DTRSM('Left','Lower','No transpose','Unit')
        for (int k = 0; k < n; ++k) {
            const double bkj = b[k + j * n];
            if (bkj != 0.0) for (int i = k + 1; i < n; ++i) b[i + j * n] = b[i + j * n] - bkj * a[i + k * n];
        }
    }
    for (int j = 0; j < n; ++j) {                     // DTRSM('Left','Upper','No transpose','Non-unit')
        for (int k = n - 1; k >= 0; --k) {
            if (b[k + j * n] != 0.0) {
                b[k + j * n] = b[k + j * n] / a[k + k * n];
                const double bkj = b[k + j * n];
                for (int i = 0; i < k; ++i) b[i + j * n] = b[i + j * n] - bkj * a[i + k * n];
            }
        }
    }
    for (int i = 0; i < n; ++i)
        for (int j = 0; j < n; ++j) out_rm[i * n + j] = b[i + j * n];
    return true;
}

bool fuse_camera_finalize(FuseCamera& c) {
    return lapack_inv(3, c.K, c.invK) && lapack_inv(4, c.E, c.invE);
}

// ---------------------------------------------------------------------------------------------
// filter.py:8-61 reproject_with_depth + filter.py:64-105 check_geometric_consistency, one source.
void check_geometric_consistency(int W, int H, const float* depth_ref, const FuseCamera& cr,
                                 const float* depth_src, const FuseCamera& cs,
                                 float geo_pixel_thres, float geo_depth_thres,
                                 std::vector<uint8_t>& mask, std::vector<float>& depth_reproj,
                                 GeoProbe* probe) {
    const size_t N = (size_t)W * H;
    mask.assign(N, 0); depth_reproj.assign(N, 0.f);

    // filter.py:28  np.matmul(extrinsics_src, np.linalg.inv(extrinsics_ref))   (4x4 @ 4x4, float64)
    double P_sr[16]; mat4mul(cs.E, cr.invE, P_sr);
    // filter.py:49  np.matmul(extrinsics_ref, np.linalg.inv(extrinsics_src))
    double P_rs[16]; mat4mul(cr.E, cs.invE, P_rs);

    std::vector<double> xs64(N), ys64(N);            // xy_src float64 (filter.py:38), reused at :46
    cv::Mat x_src(H, W, CV_32F), y_src(H, W, CV_32F); // filter.py:39-40 .astype(np.float32)
    for (int y = 0; y < H; ++y) {
        float* xrow = x_src.ptr<float>(y); float* yrow = y_src.ptr<float>(y);
        for (int x = 0; x < W; ++x) {
            const size_t i = (size_t)y * W + x;
            const double d = (double)depth_ref[i];
            // filter.py:22-25  inv(K_ref) @ (vstack(x,y,1) * depth)   (int64*float32 -> float64)
            const double v[3] = {(double)x * d, (double)y * d, 1.0 * d};
            double xyz_ref[3]; mat3vec(cr.invK, v, xyz_ref);
            // filter.py:28-29  (E_src @ inv(E_ref)) @ vstack(xyz_ref, 1)  [:3]
            const double h[4] = {xyz_ref[0], xyz_ref[1], xyz_ref[2], 1.0};
            double xyz_src[4]; mat4vec(P_sr, h, xyz_src);
            // filter.py:37-38  K_src @ xyz_src ; xy = [:2] / [2:3]
            double Kx[3]; mat3vec(cs.K, xyz_src, Kx);
            const double xsd = Kx[0] / Kx[2], ysd = Kx[1] / Kx[2];
            xs64[i] = xsd; ys64[i] = ysd;
            xrow[x] = (float)xsd; yrow[x] = (float)ysd;
        }
    }
    // filter.py:41  cv2.remap(depth_src, x_src, y_src, interpolation=cv2.INTER_LINEAR)
    //   -> cv::remap defaults borderMode=BORDER_CONSTANT, borderValue=Scalar() (=0), same as cv2.
    cv::Mat src(H, W, CV_32F, const_cast<float*>(depth_src));
    cv::Mat sampled;
    cv::remap(src, sampled, x_src, y_src, cv::INTER_LINEAR);

    if (probe) {
        probe->x_src.assign((float*)x_src.data, (float*)x_src.data + N);
        probe->y_src.assign((float*)y_src.data, (float*)y_src.data + N);
        probe->sampled.assign((float*)sampled.data, (float*)sampled.data + N);
        probe->depth_reproj_raw.resize(N); probe->x_reproj.resize(N); probe->y_reproj.resize(N);
        probe->x_src64 = xs64; probe->y_src64 = ys64;
    }

    const double thr_px = (double)geo_pixel_thres;      // filter.py:98  dist(float64) < geo_pixel_thres
    const float  thr_d  = geo_depth_thres;              // filter.py:99  rel(float32) < geo_depth_thres (weak scalar -> float32)
    const float  dmin = cr.depth_min, dmax = cr.depth_max;   // filter.py:100
    for (int y = 0; y < H; ++y) {
        const float* srow = sampled.ptr<float>(y);
        for (int x = 0; x < W; ++x) {
            const size_t i = (size_t)y * W + x;
            const double s = (double)srow[x];
            // filter.py:44-47  inv(K_src) @ (vstack(xy_src, 1) * sampled)   (float64 * float32 -> float64)
            const double v[3] = {xs64[i] * s, ys64[i] * s, 1.0 * s};
            double xyz_src[3]; mat3vec(cs.invK, v, xyz_src);
            // filter.py:49-50  (E_ref @ inv(E_src)) @ vstack(xyz_src, 1) [:3]
            const double h[4] = {xyz_src[0], xyz_src[1], xyz_src[2], 1.0};
            double xyz_rep[4]; mat4vec(P_rs, h, xyz_rep);
            const float d_rep = (float)xyz_rep[2];        // filter.py:51 .astype(np.float32)
            // filter.py:52-57
            double Kx[3]; mat3vec(cr.K, xyz_rep, Kx);
            for (int k = 0; k < 3; ++k) if (Kx[k] == 0.0) Kx[k] = 1e-5;     // np.where(K_xyz == 0, 1e-5, K_xyz)
            double xr = Kx[0] / Kx[2], yr = Kx[1] / Kx[2];
            xr = std::min(std::max(xr, -1e8), 1e8); yr = std::min(std::max(yr, -1e8), 1e8);  // np.clip(xy, -1e8, 1e8)
            const float xrf = (float)xr, yrf = (float)yr;   // .astype(np.float32)
            // filter.py:93  dist = sqrt((x2d_reproj - x_ref)**2 + (y2d_reproj - y_ref)**2)   float32 - int64 -> float64
            const double dx = (double)xrf - (double)x, dy = (double)yrf - (double)y;
            const double dist = std::sqrt(dx * dx + dy * dy);
            // filter.py:95-96  float32 ops
            const float dd = std::fabs(d_rep - depth_ref[i]);
            const float rel = dd / depth_ref[i];
            // filter.py:98-101
            const bool m = (dist < thr_px) && (rel < thr_d) && (depth_ref[i] > dmin) && (depth_ref[i] < dmax);
            mask[i] = m ? 1 : 0;
            depth_reproj[i] = m ? d_rep : 0.f;           // filter.py:102 depth_reproj[~mask] = 0
            if (probe) { probe->depth_reproj_raw[i] = d_rep; probe->x_reproj[i] = xrf; probe->y_reproj[i] = yrf; }
        }
    }
}

// ---------------------------------------------------------------------------------------------
// fuse_official.py per-frame loop.
void fuse_frame(int W, int H, const float* depth_ref, const float* const conf[3], const uint8_t* rgb,
                const FuseCamera& cr, const std::vector<const float*>& depth_srcs,
                const std::vector<const FuseCamera*>& cam_srcs, const FuseParams& p, FrameFusion& out) {
    const size_t N = (size_t)W * H;
    std::vector<uint8_t> photo(N);
    size_t nphoto = 0;
    for (size_t i = 0; i < N; ++i) {            // photo = AND_k (conf_k > thres_k)   (float32 compare)
        const bool ok = conf[0][i] > p.photo_thres[0] && conf[1][i] > p.photo_thres[1] && conf[2][i] > p.photo_thres[2];
        photo[i] = ok; nphoto += ok;
    }
    out.geo_sum.assign(N, 0);
    std::vector<double> acc(N, 0.0);            // float64 accumulator of depth_reproj
    std::vector<uint8_t> gm; std::vector<float> d_rep;
    for (size_t s = 0; s < depth_srcs.size(); ++s) {
        check_geometric_consistency(W, H, depth_ref, cr, depth_srcs[s], *cam_srcs[s], p.geo_pixel_thres, p.geo_depth_thres, gm, d_rep);
        for (size_t i = 0; i < N; ++i) { out.geo_sum[i] += gm[i]; acc[i] += (double)d_rep[i]; }
    }
    out.d_avg.resize(N); out.final_mask.resize(N);
    size_t ngeo = 0, nfinal = 0;
    for (size_t i = 0; i < N; ++i) {
        out.d_avg[i] = (acc[i] + (double)depth_ref[i]) / (double)(out.geo_sum[i] + 1);   // (acc + ref_d) / (geo_sum + 1)
        const bool geo = out.geo_sum[i] >= p.geo_mask_thres;
        const bool fin = photo[i] && geo;
        out.final_mask[i] = fin; ngeo += geo; nfinal += fin;
    }
    out.photo_frac = (double)nphoto / N; out.geo_frac = (double)ngeo / N; out.final_frac = (double)nfinal / N;
    // xyz = inv(K) @ (vstack(x, y, 1) * d) ; world = ((xyz.T - t) @ R).astype(float32)
    out.xyz.clear(); out.rgb.clear(); out.xyz64.clear(); out.xyz.reserve(nfinal * 3); out.rgb.reserve(nfinal * 3); out.xyz64.reserve(nfinal * 3);
    const double t[3] = {cr.E[3], cr.E[7], cr.E[11]};
    for (int y = 0; y < H; ++y)
        for (int x = 0; x < W; ++x) {
            const size_t i = (size_t)y * W + x;
            if (!out.final_mask[i]) continue;
            const double d = out.d_avg[i];
            const double v[3] = {(double)x * d, (double)y * d, 1.0 * d};
            double xyz[3]; mat3vec(cr.invK, v, xyz);
            const double q[3] = {xyz[0] - t[0], xyz[1] - t[1], xyz[2] - t[2]};
            for (int j = 0; j < 3; ++j) { const double w = dotk(q, 1, cr.E + j, 4, 3); out.xyz64.push_back(w); out.xyz.push_back((float)w); }   // sum_i q_i * R[i][j]
            out.rgb.push_back(rgb[i * 3 + 0]); out.rgb.push_back(rgb[i * 3 + 1]); out.rgb.push_back(rgb[i * 3 + 2]);
        }
}

bool write_ply(const char* path, const std::vector<float>& xyz, const std::vector<uint8_t>& rgb) {
    FILE* f = std::fopen(path, "wb");
    if (!f) return false;
    const size_t n = xyz.size() / 3;
    std::fprintf(f, "ply\nformat binary_little_endian 1.0\nelement vertex %zu\nproperty float x\nproperty float y\nproperty float z\n"
                    "property uchar red\nproperty uchar green\nproperty uchar blue\nend_header\n", n);
    for (size_t i = 0; i < n; ++i) {
        std::fwrite(&xyz[i * 3], sizeof(float), 3, f);
        std::fwrite(&rgb[i * 3], 1, 3, f);
    }
    std::fclose(f);
    return true;
}

}  // namespace aether::dense
