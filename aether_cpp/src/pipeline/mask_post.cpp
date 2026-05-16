// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/pipeline/mask_post.h"

#include <cmath>
#include <cstring>

namespace aether {
namespace pipeline {

void sigmoid_inplace(float* data, std::size_t count) noexcept {
    if (data == nullptr) return;
    for (std::size_t i = 0; i < count; ++i) {
        const float x = data[i];
        // Numerically stable sigmoid:
        //   for x >= 0:  sig = 1 / (1 + exp(-x))
        //   for x <  0:  sig = exp(x) / (1 + exp(x))
        // Avoids overflow of exp(-x) for very negative x.
        if (x >= 0.0f) {
            data[i] = 1.0f / (1.0f + std::exp(-x));
        } else {
            const float ex = std::exp(x);
            data[i] = ex / (1.0f + ex);
        }
    }
}

float* extract_mask_plane(
    const float* multi_array, std::int32_t plane_idx,
    std::int32_t height, std::int32_t width,
    float* dst) noexcept {
    if (multi_array == nullptr || dst == nullptr || plane_idx < 0
        || height <= 0 || width <= 0) {
        return nullptr;
    }
    const std::size_t plane_size =
        static_cast<std::size_t>(height) * static_cast<std::size_t>(width);
    const float* src = multi_array + static_cast<std::size_t>(plane_idx) * plane_size;
    std::memcpy(dst, src, plane_size * sizeof(float));
    return dst;
}

void bilinear_resize(
    const float* src, std::int32_t src_w, std::int32_t src_h,
    float* dst, std::int32_t dst_w, std::int32_t dst_h) noexcept {
    if (src == nullptr || dst == nullptr || src_w <= 0 || src_h <= 0
        || dst_w <= 0 || dst_h <= 0) {
        return;
    }
    // Sample mapping: dst pixel (x, y) maps to src coord
    //   sx = (x + 0.5) * (src_w / dst_w) - 0.5
    //   sy = (y + 0.5) * (src_h / dst_h) - 0.5
    // (half-pixel-center convention; matches PIL.Image.resize default + OpenCV
    // INTER_LINEAR.)
    const float scale_x = static_cast<float>(src_w) / static_cast<float>(dst_w);
    const float scale_y = static_cast<float>(src_h) / static_cast<float>(dst_h);

    for (std::int32_t y = 0; y < dst_h; ++y) {
        float sy = (static_cast<float>(y) + 0.5f) * scale_y - 0.5f;
        if (sy < 0.0f) sy = 0.0f;
        if (sy > static_cast<float>(src_h - 1)) sy = static_cast<float>(src_h - 1);
        const std::int32_t y0 = static_cast<std::int32_t>(sy);
        const std::int32_t y1 = (y0 + 1 < src_h) ? (y0 + 1) : y0;
        const float fy = sy - static_cast<float>(y0);

        const float* row0 = src + static_cast<std::size_t>(y0) * src_w;
        const float* row1 = src + static_cast<std::size_t>(y1) * src_w;
        float* dst_row = dst + static_cast<std::size_t>(y) * dst_w;

        for (std::int32_t x = 0; x < dst_w; ++x) {
            float sx = (static_cast<float>(x) + 0.5f) * scale_x - 0.5f;
            if (sx < 0.0f) sx = 0.0f;
            if (sx > static_cast<float>(src_w - 1)) sx = static_cast<float>(src_w - 1);
            const std::int32_t x0 = static_cast<std::int32_t>(sx);
            const std::int32_t x1 = (x0 + 1 < src_w) ? (x0 + 1) : x0;
            const float fx = sx - static_cast<float>(x0);

            const float v00 = row0[x0];
            const float v01 = row0[x1];
            const float v10 = row1[x0];
            const float v11 = row1[x1];
            const float v0 = v00 + fx * (v01 - v00);
            const float v1 = v10 + fx * (v11 - v10);
            dst_row[x] = v0 + fy * (v1 - v0);
        }
    }
}

std::int32_t edgetam_post_process(
    const float* masks_logits, const float* iou_pred,
    std::int32_t n_hypotheses, std::int32_t mask_h, std::int32_t mask_w,
    float* out_mask) noexcept {
    if (masks_logits == nullptr || iou_pred == nullptr || out_mask == nullptr
        || n_hypotheses <= 0 || mask_h <= 0 || mask_w <= 0) {
        return 0;
    }
    const std::int32_t best_idx = pick_best_mask_hypothesis(iou_pred, n_hypotheses);
    extract_mask_plane(masks_logits, best_idx, mask_h, mask_w, out_mask);
    sigmoid_inplace(out_mask, static_cast<std::size_t>(mask_h) * mask_w);
    return best_idx;
}

}  // namespace pipeline
}  // namespace aether
