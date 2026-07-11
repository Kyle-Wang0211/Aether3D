// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_CPP_TOOLS_SIFT_EXTRACT_DAWN_H
#define AETHER_CPP_TOOLS_SIFT_EXTRACT_DAWN_H

// GPU DSP-SIFT full-pipeline orchestrator (M2-1).
//
// Chains the seven validated WGSL passes into one extractor:
//   gray→f32 + GSS pyramid (sift_pyramid_dawn) →
//   sift_dog_detect (all octaves) → sift_nonextrema_suppress →
//   sift_affine_shape → sift_orientation → sift_dsp_descriptor.
//
// The Gaussian scale space stays RESIDENT on the GPU (packed once via
// pack_levels); only keypoint metadata (positions/ellipses, ~16k×32B) crosses
// to the host between detect→suppress→affine→orient repacks, and the raw 128-d
// descriptor mean is read back ONCE at the end. CPU finishing (8192 clamp by
// (octave,scale) desc, L1RootNormalize, round(512v) u8, VLFeat→UBC reorder)
// matches dsp_sift_c.cc / aether_threaded_extract.cc verbatim.
//
// Each per-stage pass already passed its own bit-faithful parity gate (M0..E);
// M2 is the first end-to-end run, so the host-side repacks are written to fail
// LOUD (NaN / capacity overflow → error return) so the C-ABI wrapper can fall
// back to the CPU _threaded path.

#include <cstdint>
#include <vector>

#include "dawn_kernel_harness.h"
#include "sift_pyramid_dawn.h"

namespace aether {
namespace tools {

class SiftExtractDawn {
public:
    // One oriented keypoint + its RootSIFT-ready raw descriptor (128-d f32 mean,
    // pre-finishing). x/y are VLFeat frame coords (the +0.5 half-pixel is added
    // by the C-ABI finishing, matching sift.cc:422).
    struct Result {
        std::vector<float> xy;          // 2*K (x,y interleaved, frame coords)
        std::vector<int> octave;        // K (for the 8192 clamp sort)
        std::vector<int> scale;         // K (sublevel s, for the clamp sort)
        std::vector<float> raw_desc;    // K*128 (the 10-scale DSP mean, VLFeat bin order)
        int count = 0;
    };

    // Extract from a grayscale image (row-major, width*height bytes). Returns
    // false on any GPU failure / capacity overflow / NaN (caller falls back to
    // CPU). `harness` must be init()'d. peak/edge thresholds + DSP params are the
    // production defaults (colmap/feature/sift.h).
    //
    // `max_features` applies the COLMAP (octave desc, scale desc) clamp to the
    // 1→K-expanded oriented keypoint set BEFORE the descriptor stage (sift.cc:
    // 403-444 computes descriptors ONLY for the clamped ≤max_features set). This
    // is the dominant-cost optimization: the descriptor kernel runs over ~8192
    // instead of ~21000-27000 keypoints. The surviving descriptors are
    // bit-identical (the kernel is deterministic per-keypoint); only the set
    // size shrinks. <=0 means "no clamp" (compute all). The C-ABI passes the
    // production 8192.
    bool extract(DawnKernelHarness& harness,
                 const uint8_t* gray, int width, int height,
                 int max_features,
                 Result* out);

    // Detector constants. COLMAP default peak = 0.02/3 ≈ 0.0067, edge = 10.
    // LOW-TEXTURE EXPERIMENT (2026-07-08): lowered peak to 0.004 + raised edge
    // to 15 so subtle low-contrast keypoints (white bedsheet weave/wrinkles) get
    // detected — the direction the COLMAP maintainers recommend (discussion
    // #3803: "lower peak_threshold to get more features, increase edge_threshold").
    // GPU + CPU (dsp_sift_c.cc) kept in lock-step so the parity gates hold.
    static constexpr int kOctaveResolution = SiftPyramidDawn::kOctaveResolution;  // 3
    static double peak_threshold() { return 0.004; }
    static constexpr double kEdgeThreshold = 15.0;
    static constexpr double kSuppressTol = 0.5;
    static constexpr float kDspMinScale = 1.0f / 6.0f;
    static constexpr float kDspMaxScale = 3.0f;
    // DSP pooling scale count. MUST stay identical to the DSP_NUM constant
    // hard-coded in the 4 dsp .wgsl shaders (sift_dsp_descriptor{,_f16,_par}.wgsl
    // + sift_dsp_mean.wgsl): the shader loops DSP_NUM times unconditionally and
    // load_wgsl does NO substitution, while THIS constant sizes the uploaded
    // dstep=(max-min)/kDspNumScales uniform and the ③-path scale_desc buffer
    // (n*kDspNumScales*128). Any drift stretches the per-scale spacing (or
    // under-allocates the ③ buffer → OOB reads) — the 2026-07-08 "S5 10→3"
    // attempt did exactly that: shader still pooled 10 scales but with 3.3×
    // spacing, pushing 6/10 scales past kDspMaxScale (max 8.67). It was NOT a
    // valid 3-scale DSP; certified config is 10 (= CPU dsp_sift_c.cc path).
    // dsp_descriptor_parity.cc consumes this constant, so drift now fails the gate.
    static constexpr int kDspNumScales = 10;

private:
    static constexpr uint32_t kKpStride = 8u;
    static constexpr uint32_t kDetectCap = 48000u;   // pre-suppression detect cap
    static constexpr uint32_t kOrientCap = 65536u;   // 1→K oriented cap
};

}  // namespace tools
}  // namespace aether

#endif  // AETHER_CPP_TOOLS_SIFT_EXTRACT_DAWN_H
