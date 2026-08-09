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

#include "aether/sfm/canonical_feature_selector_v1.h"
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
        // [SCALE-PERSIST 2026-08-06] K continuous detection scales /
        // orientations derived from the oriented kp record's affine ellipse
        // (a11,a12,a21,a22) with COLMAP's own FeatureKeypoint::ComputeScale()
        // / ComputeOrientation() formulas (colmap/feature/types.cc) — the same
        // quantities the CPU covariant extractor reports.
        std::vector<float> kp_scale;        // K (pixels)
        std::vector<float> kp_orientation;  // K (radians)
        std::vector<float> raw_desc;    // K*128 (the kDspNumScales-scale DSP mean, VLFeat bin order)
        std::vector<uint64_t> stable_ids;  // canonical row ranks; empty in legacy mode
        aether::sfm::FeatureSelectionPolicyV1 selection_policy =
            aether::sfm::FeatureSelectionPolicyV1::kLegacyColmapGroup;
        aether::sfm::FeatureSelectionPolicyReasonV1 selection_policy_reason =
            aether::sfm::FeatureSelectionPolicyReasonV1::kAbsent;
        int count = 0;
    };

    // Reads the one compile-time-selected official or self-test environment
    // namespace. The C ABI uses this same decision before choosing whether a
    // legacy CPU fallback is semantically valid.
    static aether::sfm::FeatureSelectionPolicyDecisionV1
    feature_selection_policy();

    // Extract from a grayscale image (row-major, width*height bytes). Returns
    // false on any GPU failure / capacity overflow / NaN. The C ABI preserves
    // transparent CPU fallback only for legacy policy; an explicit canonical
    // policy converts false to canonical-unavailable status 2 rather than
    // returning legacy output under a canonical label. `harness` must be
    // init()'d. peak/edge thresholds + DSP params are the production defaults
    // (colmap/feature/sift.h).
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
    // valid 3-scale DSP; header + shaders must move TOGETHER (CPU reference
    // dsp_sift_c.cc follows this constant automatically).
    // dsp_descriptor_parity.cc consumes this constant, so drift now fails the gate.
    // [SCALE-6 2026-07-11] 10→6, a LEGAL identity change (unlike the S5
    // attempt): both header and all 4 shaders move together, dstep becomes
    // (3 - 1/6)/6 and the top pooled scale lands exactly at kDspMaxScale=3.0.
    // Host A/B (cap44 87-frame replay): descriptor parity gate PASS, delivered
    // cloud inside the noise band; host batch wall 25.9-26.4s → 24.1-24.2s
    // (alternating runs, ~-7%; descriptor stage is a small share on M3 — the
    // device share is larger but ungrounded until the next on-device capture).
    static constexpr int kDspNumScales = 6;

private:
    static constexpr uint32_t kKpStride = 8u;
    // [DETECT-CAP 2026-08-10] 48000→131072:酒店高频纹理场景(未命名(2)/(4))
    // 原始 DoG 检测数爆 48k 上限 → 整帧确定性失败 → 欠账 → 补算 GPU 重试
    // 同图必再爆 → 100% 掉 CPU(39s/帧)。上限是缓冲容量非算法语义:同图
    // 低于旧上限的帧结果逐位不变;曾失败的帧现在完整成功(严格变好)。
    // 成本:检测缓冲 1.5MB→4MB(每帧多 ~1ms 上传);shader 有越界钳,
    // 回读按实际 n_detect 走,与上限无关。
    static constexpr uint32_t kDetectCap = 131072u;  // pre-suppression detect cap
    // [DETECT-CAP 2026-08-10 连环] 检测上限 48k→128k 后,高频纹理场景的
    // 朝向候选顶爆 65536(host 用失败照实测 80,904)。同族一起抬:
    // 65536→196608(3×,给 1→K 多朝向留量;缓冲 ~2MB→6MB)。
    static constexpr uint32_t kOrientCap = 196608u;  // 1→K oriented cap
};

}  // namespace tools
}  // namespace aether

#endif  // AETHER_CPP_TOOLS_SIFT_EXTRACT_DAWN_H
