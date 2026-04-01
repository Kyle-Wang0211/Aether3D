// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// depth_loss.h — Pearson-invariant depth supervision loss.
// Used to train 3DGS with relative depth from DAv2 (Neural Engine).
// The loss is invariant to global scale and shift, making it
// compatible with DAv2's relative depth output.

#ifndef AETHER_TRAINING_DEPTH_LOSS_H
#define AETHER_TRAINING_DEPTH_LOSS_H

#ifdef __cplusplus

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>

namespace aether {
namespace training {

// ═══════════════════════════════════════════════════════════════════════
// Pearson-Invariant Depth Loss
// ═══════════════════════════════════════════════════════════════════════
// Given rendered depth d_r and DAv2 relative depth d_ref:
//   1. Compute Pearson correlation ρ between d_r and d_ref
//   2. Loss = 1 - ρ  (0 when perfectly correlated, 2 when anti-correlated)
//   3. Gradient w.r.t. d_r computed analytically
//
// This handles DAv2's relative depth (arbitrary scale/shift) correctly,
// unlike MSE or L1 which require metric-aligned depth.

/// Compute Pearson-invariant depth loss and gradient.
/// @param rendered_depth  Rendered depth from forwardRasterize (W×H)
/// @param ref_depth       Reference depth from DAv2 (W×H, relative [0,1])
/// @param ref_depth_w     Reference depth width (may differ from rendered)
/// @param ref_depth_h     Reference depth height
/// @param render_w        Rendered depth width
/// @param render_h        Rendered depth height
/// @param lambda          Loss weight (from depth_loss_weight_at_step)
/// @param out_grad        Output gradient w.r.t. rendered_depth (W×H)
/// @return Weighted Pearson depth loss value
inline float pearson_depth_loss(
    const float* rendered_depth,
    const float* ref_depth,
    std::uint32_t ref_depth_w, std::uint32_t ref_depth_h,
    std::uint32_t render_w, std::uint32_t render_h,
    float lambda,
    float* out_grad) noexcept
{
    if (!rendered_depth || !ref_depth || !out_grad) return 0.0f;
    if (render_w == 0 || render_h == 0) return 0.0f;
    if (ref_depth_w == 0 || ref_depth_h == 0) return 0.0f;

    std::size_t npix = static_cast<std::size_t>(render_w) * render_h;

    // Step 1: Compute means (with nearest-neighbor resampling of ref_depth)
    double sum_r = 0.0, sum_d = 0.0;
    std::size_t valid_count = 0;

    float x_scale = static_cast<float>(ref_depth_w) / static_cast<float>(render_w);
    float y_scale = static_cast<float>(ref_depth_h) / static_cast<float>(render_h);

    for (std::uint32_t y = 0; y < render_h; ++y) {
        for (std::uint32_t x = 0; x < render_w; ++x) {
            std::size_t ridx = y * render_w + x;
            float rd = rendered_depth[ridx];
            if (rd <= 0.0f) continue;  // No rendered geometry at this pixel

            // Nearest-neighbor sample from reference depth
            std::uint32_t rx = std::min(static_cast<std::uint32_t>(x * x_scale), ref_depth_w - 1);
            std::uint32_t ry = std::min(static_cast<std::uint32_t>(y * y_scale), ref_depth_h - 1);
            float dd = ref_depth[ry * ref_depth_w + rx];
            if (dd <= 0.0f) continue;  // Invalid reference depth

            sum_r += rd;
            sum_d += dd;
            valid_count++;
        }
    }

    if (valid_count < 16) {
        // Too few valid pixels — skip depth loss
        for (std::size_t i = 0; i < npix; ++i) out_grad[i] = 0.0f;
        return 0.0f;
    }

    float mean_r = static_cast<float>(sum_r / valid_count);
    float mean_d = static_cast<float>(sum_d / valid_count);

    // Step 2: Compute Pearson correlation components
    double sum_rr = 0.0, sum_dd = 0.0, sum_rd = 0.0;
    for (std::uint32_t y = 0; y < render_h; ++y) {
        for (std::uint32_t x = 0; x < render_w; ++x) {
            std::size_t ridx = y * render_w + x;
            float rd = rendered_depth[ridx];
            if (rd <= 0.0f) continue;

            std::uint32_t rx = std::min(static_cast<std::uint32_t>(x * x_scale), ref_depth_w - 1);
            std::uint32_t ry = std::min(static_cast<std::uint32_t>(y * y_scale), ref_depth_h - 1);
            float dd = ref_depth[ry * ref_depth_w + rx];
            if (dd <= 0.0f) continue;

            float dr = rd - mean_r;
            float df = dd - mean_d;
            sum_rr += dr * dr;
            sum_dd += df * df;
            sum_rd += dr * df;
        }
    }

    float std_r = static_cast<float>(std::sqrt(sum_rr / valid_count));
    float std_d = static_cast<float>(std::sqrt(sum_dd / valid_count));

    // Guard against degenerate cases (constant depth)
    if (std_r < 1e-6f || std_d < 1e-6f) {
        for (std::size_t i = 0; i < npix; ++i) out_grad[i] = 0.0f;
        return 0.0f;
    }

    float pearson = static_cast<float>(sum_rd / (std::sqrt(sum_rr) * std::sqrt(sum_dd)));
    pearson = std::clamp(pearson, -1.0f, 1.0f);

    float loss = (1.0f - pearson) * lambda;

    // Step 3: Compute gradient
    // d(loss)/d(r_i) = -lambda × d(pearson)/d(r_i)
    // d(pearson)/d(r_i) = (1/(N×σ_r×σ_d)) × [(d_i - μ_d) - ρ × (σ_d/σ_r) × (r_i - μ_r)]
    float inv_n_sr_sd = 1.0f / (static_cast<float>(valid_count) * std_r * std_d);
    float rho_sd_over_sr = pearson * std_d / std_r;

    for (std::size_t i = 0; i < npix; ++i) out_grad[i] = 0.0f;

    for (std::uint32_t y = 0; y < render_h; ++y) {
        for (std::uint32_t x = 0; x < render_w; ++x) {
            std::size_t ridx = y * render_w + x;
            float rd = rendered_depth[ridx];
            if (rd <= 0.0f) continue;

            std::uint32_t rx = std::min(static_cast<std::uint32_t>(x * x_scale), ref_depth_w - 1);
            std::uint32_t ry = std::min(static_cast<std::uint32_t>(y * y_scale), ref_depth_h - 1);
            float dd = ref_depth[ry * ref_depth_w + rx];
            if (dd <= 0.0f) continue;

            float d_pearson_d_ri = inv_n_sr_sd * ((dd - mean_d) - rho_sd_over_sr * (rd - mean_r));
            out_grad[ridx] = -lambda * d_pearson_d_ri;
        }
    }

    return loss;
}

}  // namespace training
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_TRAINING_DEPTH_LOSS_H
