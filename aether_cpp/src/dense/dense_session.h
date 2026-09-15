// dense_session.h — per-session camera table for the on-device dense runner (Stage 1, input side).
//
// Ported LINE-BY-LINE from the certified fixture builder
//   pocketworld_research_benchmarks/experiments/casdiffmvs_blendmvg_scratch_2026-08-16/tools/prep_phone_fixture.py
// (lines 62-203: q2R, K scaling, projection visibility, MVSNet view scoring + minimum baseline,
// nearest-centre fill, depth range percentiles, the 36-float camera row). That script reproduces
// fx_official byte-for-byte with its default flags and FIX_NSRC=9 (verified 2026-09-15), so its
// constants are the production contract:
//   THETA0=5°, SIG1=1, SIG2=10   MVSNet view-selection score (colmap2mvsnet.py)
//   MIN_BASE=0.06 m              minimum baseline (interface rule)
//   depth range (p2*0.70, p99.5*1.50), <8 points -> (0.3, 4.0) m  (production rule)
//   common-visible >= 20 points, projection-inside-image visibility, no ARKit union, no frame gate.
// numpy semantics reproduced where the output is float32: percentiles use numpy's 'linear'
// method literally ((n-1)*q, floor, numpy _lerp), sums use numpy's pairwise_sum.
#pragma once
#include <cstdint>
#include <vector>

namespace aether::dense {

struct SessionFrame {
    double frame_id;
    double fx, fy, cx, cy;   // sidecar intrinsics_fxfycxcy at the capture resolution
    double image_w, image_h; // sidecar image_w / image_h
    double q[4];             // quat_wxyz (refined pose, COLMAP/OpenCV axes)
    double t[3];             // t (world -> camera)
};

struct SessionParams {
    int W = 768, H = 576;      // model resolution (4:3 like the 4032x3024 capture)
    int nsrc = 9;              // FIX_NSRC
    double theta0 = 5.0, sig1 = 1.0, sig2 = 10.0;   // THETA0, SIG1, SIG2
    double min_base = 0.06;    // MIN_BASE
    int min_common = 20;       // com.sum() < 20 -> skip
    double dr_lo = 0.70, dr_hi = 1.50;              // DR_LO, DR_HI
    int min_pts = 8;           // len(zc) >= 8 else fallback
    double fallback_lo = 0.3, fallback_hi = 4.0;
};

struct SessionTable {
    int NF = 0;
    std::vector<float> cams;        // NF*36: K[0:9] R[9:18] t[18:21] C[21:24] dmin[24] dmax[25] W[26] H[27]
    std::vector<int32_t> neighbors; // NF*nsrc
    std::vector<double> med_angle;  // per frame: median of the picked candidates' median angles (diagnostic)
    std::vector<uint8_t> vis;       // NF*NP: sparse point n visible in frame i (pf:111-115 projection test), row-major
    long NP = 0;
};

// frames: registered poses, MUST already be sorted by frame_id (poses.sort(key=frame_id)).
// points: sparse points, N*3 float32 (official_sfm_sparse.ply x y z).
void build_session_table(const std::vector<SessionFrame>& frames, const std::vector<float>& points,
                         const SessionParams& p, SessionTable& out);

// numpy.percentile(a, q) with the default 'linear' method, verbatim arithmetic. `sorted_vals` ascending.
double numpy_percentile_linear(const std::vector<double>& sorted_vals, double q_percent);

// numpy add.reduce pairwise summation (numpy/_core/src/umath/loops_utils.h.src pairwise_sum), verbatim.
double numpy_pairwise_sum(const double* a, long n);

}  // namespace aether::dense
