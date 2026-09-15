// dense_fuse.h — CasDiffMVS depth-map fusion for the on-device dense point cloud (Stage 2).
//
// Ported LINE-BY-LINE from the official cvg/diffmvs filter.py (HEAD cd10d5c, Apache-2.0):
//   reproject_with_depth        filter.py:8-61
//   check_geometric_consistency filter.py:64-105
// and from the certified gate producer fuse_official.py (pocketworld_research_benchmarks/
// experiments/casdiffmvs_blendmvg_scratch_2026-08-16/tools/fuse_official.py): photometric mask
// AND(conf0>0.3, conf1>0.5, conf2>0.5), geo_sum, depth averaging (acc+ref)/(geo_sum+1), final =
// photo & geo_sum>=3, back-projection to world, PLY.
//
// NOTHING is re-implemented that the official code takes from a library:
//   * bilinear resampling = cv::remap(depth_src, x_src, y_src, INTER_LINEAR) — the very same
//     OpenCV function filter.py:41 calls (BORDER_CONSTANT, value 0 are its defaults). OpenCV
//     is already linked into the iPhone product (pocketworld ios/Runner.xcodeproj:470,
//     libopencv_generic_4_0_1.a; remapBilinear<float> kernel identical in 4.0.1/4.13.0/5.0.0,
//     diffed 2026-09-15).
//   * numpy.linalg.inv = LAPACK ?gesv(A, I) (numpy/linalg/umath_linalg.cpp). Here: reference
//     LAPACK dgetf2 + dgetrs ported verbatim in structure (n<=4). Whether Accelerate's dgesv
//     rounds identically is MEASURED by the gate (inject arm, see test_fuse.cc), not assumed.
//
// Numeric contract: every numpy float64 stage is double, every .astype(np.float32) is a float
// cast at the same point, every float32 op stays float. Compile with -ffp-contract=off (the
// device OpenCV builds are; opencv-pw/docs_fp_contract.md).
#pragma once
#include <cstdint>
#include <vector>

namespace aether::dense {

// Matmul accumulation mode for the numpy float64 matmuls (BLAS dgemm on the reference side).
// 0: acc = acc + a*b (two roundings, k ascending)   1: acc = fma(a,b,acc) (k ascending)
// 2: like 0 but k descending                          3: like 1 but k descending
// MEASURED 2026-09-15 on fixture97 against numpy 2.4.6 + Accelerate: mode 1 reproduces every float32
// output bit-for-bit (masks/geosum/davg/xyz/col, 22,021,292 points); mode 0 left 1 xyz element in 66 M
// differing by one float32 ULP. Default is therefore 1. std::fma is correctly rounded on every platform.
extern int g_fuse_matmul_mode;

struct FuseCamera {
    double K[9];        // row-major 3x3 intrinsics (fixture cams.f32[0:9])
    double E[16];       // row-major 4x4 world->camera [R|t; 0 0 0 1] (cams.f32 R[9:18], t[18:21])
    float depth_min;    // cams.f32[24]  (filter.py ref_depth_min)
    float depth_max;    // cams.f32[25]  (filter.py ref_depth_max)
    double invK[9];     // numpy.linalg.inv(K)
    double invE[16];    // numpy.linalg.inv(E)
};

// Fill invK/invE with the LAPACK-style LU inverse (numpy.linalg.inv semantics). Returns false if singular.
bool fuse_camera_finalize(FuseCamera& c);

// Reference-LAPACK dgetf2 + dgetrs solve of A X = I, n<=4, row-major in/out. Exposed for the gate.
bool lapack_inv(int n, const double* A_rowmajor, double* out_rowmajor);

struct FuseParams {
    float photo_thres[3] = {0.3f, 0.5f, 0.5f}; // fuse_official.py: conf0>0.3 & conf1>0.5 & conf2>0.5
    float geo_pixel_thres = 1.0f;             // filter.py:73 geo_pixel_thres
    float geo_depth_thres = 0.01f;            // filter.py:74 geo_depth_thres
    int   geo_mask_thres  = 3;                // fuse_official.py --geo-mask-thres (fixture97 certified run)
};

// Stage-level intermediates of one (ref,src) pair, for the probe arm (all H*W).
struct GeoProbe {
    std::vector<float> x_src, y_src, sampled, depth_reproj_raw, x_reproj, y_reproj;
    std::vector<double> x_src64, y_src64;   // filter.py:38 xy_src before the float32 cast (float64-level probe)
};

// filter.py:64-105 for ONE source view. depth_ref/depth_src: H*W float32 row-major.
// mask: H*W 0/1;  depth_reproj: H*W float32 zeroed where !mask (filter.py:102).
void check_geometric_consistency(int W, int H, const float* depth_ref, const FuseCamera& cam_ref,
                                 const float* depth_src, const FuseCamera& cam_src,
                                 float geo_pixel_thres, float geo_depth_thres,
                                 std::vector<uint8_t>& mask, std::vector<float>& depth_reproj,
                                 GeoProbe* probe = nullptr);

struct FrameFusion {
    std::vector<uint8_t> final_mask;   // H*W
    std::vector<int32_t> geo_sum;      // H*W
    std::vector<double>  d_avg;        // H*W  (acc + ref_d) / (geo_sum + 1)
    std::vector<float>   xyz;          // N*3 world points float32, row-major pixel order of final_mask
    std::vector<double>  xyz64;        // the same points before the float32 cast (float64-level probe)
    std::vector<uint8_t> rgb;          // N*3
    double photo_frac = 0, geo_frac = 0, final_frac = 0;
};

// fuse_official.py per-frame loop. conf[k]: H*W float32 at depth resolution. rgb: H*W*3 u8.
void fuse_frame(int W, int H, const float* depth_ref, const float* const conf[3], const uint8_t* rgb,
                const FuseCamera& cam_ref, const std::vector<const float*>& depth_srcs,
                const std::vector<const FuseCamera*>& cam_srcs, const FuseParams& p, FrameFusion& out);

// PLY binary_little_endian, x y z float32 + red green blue uchar (fuse_official.py writer).
bool write_ply(const char* path, const std::vector<float>& xyz, const std::vector<uint8_t>& rgb);

}  // namespace aether::dense
