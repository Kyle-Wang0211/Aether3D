// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// Plan G W2 D1: EdgeTAM (SAM 2 distilled mobile) mask post-process.
//
// EdgeTAM mask decoder outputs 3 mask hypotheses (1, 3, 256, 256) fp16 logits
// + 3 IoU predictions (1, 3) fp16. Post-process:
//   1. fp16 → fp32 (done before reaching this layer).
//   2. Pick hypothesis with highest IoU.
//   3. Sigmoid extracted plane → [0, 1] foreground probability.
//   4. (Optional) Bilinear resize 256×256 → original frame size for use in
//      point-cloud subject-aware retention (W2 D3+).
//
// Cross-platform: pure header API + .cpp impl. Ported from EdgeTAMWrapper.swift
// post-process — bit-for-bit equivalent.

#ifndef AETHER_PIPELINE_MASK_POST_H
#define AETHER_PIPELINE_MASK_POST_H

#ifdef __cplusplus

#include <cstdint>
#include <vector>

namespace aether {
namespace pipeline {

/// Pick best hypothesis index by max IoU prediction.
/// Returns 0 if all IoUs are -inf or count == 0 (safe default).
inline std::int32_t pick_best_mask_hypothesis(
    const float* iou_pred, std::int32_t count) noexcept {
    if (iou_pred == nullptr || count <= 0) return 0;
    std::int32_t best_idx = 0;
    float best_iou = iou_pred[0];
    for (std::int32_t i = 1; i < count; ++i) {
        if (iou_pred[i] > best_iou) {
            best_iou = iou_pred[i];
            best_idx = i;
        }
    }
    return best_idx;
}

/// Apply sigmoid in-place: x ← 1 / (1 + exp(-x)).
/// Stable formulation for large negative x (avoid overflow in exp).
void sigmoid_inplace(float* data, std::size_t count) noexcept;

/// Extract a single (h, w) plane from a (n_planes, h, w) fp32 multi-array.
/// dst must have h*w capacity. Returns dst on success, nullptr on bad args.
float* extract_mask_plane(
    const float* multi_array, std::int32_t plane_idx,
    std::int32_t height, std::int32_t width,
    float* dst) noexcept;

/// Bilinear resize a 2D float map. src is (src_h, src_w) row-major, dst is
/// (dst_h, dst_w) row-major. No clamping, output range matches input.
/// Used for W6: scale 256×256 mask back to original frame resolution (~2K
/// or ~4K) for subject-aware point retention.
void bilinear_resize(
    const float* src, std::int32_t src_w, std::int32_t src_h,
    float* dst, std::int32_t dst_w, std::int32_t dst_h) noexcept;

/// Full EdgeTAM post-process: pick best hypothesis + sigmoid → fg probability.
///
/// Inputs:
///   masks_logits: 3 × mask_h × mask_w fp32 (already converted from fp16 by caller)
///   iou_pred: 3 fp32 IoU predictions
///   mask_h, mask_w: typically 256, 256
///
/// Output: out_mask is mask_h × mask_w fp32 with [0, 1] probabilities (sigmoid of
/// picked hypothesis). Caller allocates mask_h*mask_w capacity in out_mask.
///
/// Returns: index of picked hypothesis (0, 1, or 2), and writes its sigmoid'd
/// probability map to out_mask.
std::int32_t edgetam_post_process(
    const float* masks_logits, const float* iou_pred,
    std::int32_t n_hypotheses, std::int32_t mask_h, std::int32_t mask_w,
    float* out_mask) noexcept;

}  // namespace pipeline
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_PIPELINE_MASK_POST_H
