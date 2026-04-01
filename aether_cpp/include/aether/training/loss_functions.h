// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_TRAINING_LOSS_FUNCTIONS_H
#define AETHER_TRAINING_LOSS_FUNCTIONS_H

#ifdef __cplusplus

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <vector>

namespace aether {
namespace training {

// ═══════════════════════════════════════════════════════════════════════
// Loss Functions for 3DGS Training
// ═══════════════════════════════════════════════════════════════════════
// Combined loss: L = (1 - lambda) * L1 + lambda * D-SSIM
// Default lambda = 0.2 (standard 3DGS convention)
//
// D-SSIM gradient: Fused separable backward via sum filters.
// Reference: fused-ssim (Lirui 2024), Taming 3DGS (Mallick 2024)
//
// Derivation (box filter window, size n = (2R+1)²):
//   SSIM_W = N_W / D_W  where
//     N = (2μ_xμ_y + C1)(2σ_xy + C2),  D = (μ²_x+μ²_y + C1)(σ²_x+σ²_y + C2)
//   D-SSIM = (1 - SSIM) / 2
//
//   For pixel r_i in window W:
//     dSSIM/dr_i = [D·dN/dr_i − N·dD/dr_i] / D²
//   where dN/dr_i = (2/n)[μ_y·A2 + A1·(t_i − μ_y)]
//         dD/dr_i = (2/n)[μ_x·B2 + B1·(r_i − μ_x)]
//
//   Decompose into window-only maps + pixel-specific terms:
//     map1 = A1/D,  map2 = N·B1/D²,  map3 = K/D²
//     K = D·μ_y·(A2−A1) + N·μ_x·(B1−B2)
//
//   Total gradient at pixel (px,py):
//     dL/dr = -(1/(count·n)) × [t·ΣW map1 − r·ΣW map2 + ΣW map3]
//   where ΣW = sum filter (not mean!) of per-window maps.

// ─── Internal helpers: Separable sum filters ────────────────────────

namespace detail {

/// 1D horizontal running-sum filter (radius R).
/// For each pixel (x,y), computes sum over [x-R, x+R] (clamped to image).
inline void sum_filter_h(const float* src, float* dst,
                          std::uint32_t w, std::uint32_t h,
                          int R) noexcept {
    for (std::uint32_t y = 0; y < h; ++y) {
        const float* row = src + y * w;
        float* out = dst + y * w;

        // Initial sum: elements in [0, R]
        float sum = 0.0f;
        for (int i = 0; i <= R && i < static_cast<int>(w); ++i) {
            sum += row[i];
        }
        out[0] = sum;

        for (std::uint32_t x = 1; x < w; ++x) {
            int add_x = static_cast<int>(x) + R;
            int rem_x = static_cast<int>(x) - R - 1;
            if (add_x < static_cast<int>(w)) sum += row[add_x];
            if (rem_x >= 0) sum -= row[rem_x];
            out[x] = sum;
        }
    }
}

/// 1D vertical running-sum filter (radius R).
inline void sum_filter_v(const float* src, float* dst,
                          std::uint32_t w, std::uint32_t h,
                          int R) noexcept {
    for (std::uint32_t x = 0; x < w; ++x) {
        // Initial sum: rows [0, R]
        float sum = 0.0f;
        for (int i = 0; i <= R && i < static_cast<int>(h); ++i) {
            sum += src[i * w + x];
        }
        dst[x] = sum;

        for (std::uint32_t y = 1; y < h; ++y) {
            int add_y = static_cast<int>(y) + R;
            int rem_y = static_cast<int>(y) - R - 1;
            if (add_y < static_cast<int>(h)) sum += src[add_y * w + x];
            if (rem_y >= 0) sum -= src[rem_y * w + x];
            dst[y * w + x] = sum;
        }
    }
}

/// Separable 2D SUM filter (radius R). Computes sum over (2R+1)×(2R+1) window.
/// Requires tmp buffer of size w*h.
inline void sum_filter_2d(const float* src, float* dst, float* tmp,
                           std::uint32_t w, std::uint32_t h,
                           int R) noexcept {
    sum_filter_h(src, tmp, w, h, R);
    sum_filter_v(tmp, dst, w, h, R);
}

}  // namespace detail

// ─── L1 Loss ────────────────────────────────────────────────────────

/// Compute L1 (mean absolute error) loss between two RGB images.
/// Both images are float arrays [h * w * 3], channels interleaved.
inline float compute_l1_loss(const float* rendered, const float* target,
                              std::uint32_t w, std::uint32_t h) noexcept {
    std::size_t total = static_cast<std::size_t>(w) * h * 3;
    if (total == 0) return 0.0f;

    double sum = 0.0;
    for (std::size_t i = 0; i < total; ++i) {
        sum += std::fabs(static_cast<double>(rendered[i]) -
                         static_cast<double>(target[i]));
    }
    return static_cast<float>(sum / static_cast<double>(total));
}

/// Compute L1 loss gradient.
/// out_grad[h * w * 3]: gradient w.r.t. rendered image.
inline void compute_l1_gradient(const float* rendered, const float* target,
                                 std::uint32_t w, std::uint32_t h,
                                 float* out_grad) noexcept {
    std::size_t total = static_cast<std::size_t>(w) * h * 3;
    // Bug 0.14/0.15 fix: guard against total==0 to prevent division by zero / NaN
    if (total == 0) {
        return;
    }
    float inv_n = 1.0f / static_cast<float>(total);
    for (std::size_t i = 0; i < total; ++i) {
        float diff = rendered[i] - target[i];
        // Bug 0.2 fix: use >= 0 so that diff == 0 gets consistent +inv_n
        // instead of random sign, preventing gradient oscillation at zero-crossings.
        out_grad[i] = (diff >= 0.0f ? inv_n : -inv_n);
    }
}

// ─── D-SSIM Loss ────────────────────────────────────────────────────

/// Compute D-SSIM (1 - SSIM) / 2 loss for a single channel.
/// Uses 11x11 box filter window (separable for efficiency).
/// Returns D-SSIM in [0, 1].
inline float compute_dssim_channel(const float* rendered, const float* target,
                                    std::uint32_t w, std::uint32_t h,
                                    std::uint32_t /*stride*/,
                                    std::uint32_t channel,
                                    std::uint32_t channels) noexcept {
    constexpr float C1 = 0.01f * 0.01f;  // (K1 * L)^2, L=1
    constexpr float C2 = 0.03f * 0.03f;
    constexpr int kRadius = 5;  // 11x11 window
    constexpr int kWinSize = (2 * kRadius + 1) * (2 * kRadius + 1);  // 121
    constexpr float kInvWin = 1.0f / static_cast<float>(kWinSize);

    if (w < 11 || h < 11) return 0.0f;

    const std::size_t npix = static_cast<std::size_t>(w) * h;

    // Extract single-channel data
    std::vector<float> r_ch(npix), t_ch(npix), r2(npix), t2(npix), rt(npix);
    for (std::uint32_t y = 0; y < h; ++y) {
        for (std::uint32_t x = 0; x < w; ++x) {
            std::size_t idx = y * w + x;
            std::size_t cidx = idx * channels + channel;
            float rv = rendered[cidx], tv = target[cidx];
            r_ch[idx] = rv;
            t_ch[idx] = tv;
            r2[idx] = rv * rv;
            t2[idx] = tv * tv;
            rt[idx] = rv * tv;
        }
    }

    // Sum filter all 5 quantities
    // Bug 0.40 fix: zero-initialize tmp
    std::vector<float> tmp(npix, 0.0f);
    std::vector<float> sum_r(npix), sum_t(npix), sum_r2(npix), sum_t2(npix), sum_rt(npix);
    detail::sum_filter_2d(r_ch.data(), sum_r.data(), tmp.data(), w, h, kRadius);
    detail::sum_filter_2d(t_ch.data(), sum_t.data(), tmp.data(), w, h, kRadius);
    detail::sum_filter_2d(r2.data(), sum_r2.data(), tmp.data(), w, h, kRadius);
    detail::sum_filter_2d(t2.data(), sum_t2.data(), tmp.data(), w, h, kRadius);
    detail::sum_filter_2d(rt.data(), sum_rt.data(), tmp.data(), w, h, kRadius);

    double dssim_sum = 0.0;
    std::size_t count = 0;

    for (std::uint32_t y = kRadius; y < h - kRadius; ++y) {
        for (std::uint32_t x = kRadius; x < w - kRadius; ++x) {
            std::size_t idx = y * w + x;

            float mu_r = sum_r[idx] * kInvWin;
            float mu_t = sum_t[idx] * kInvWin;
            float sx2 = std::max(sum_r2[idx] * kInvWin - mu_r * mu_r, 0.0f);
            float sy2 = std::max(sum_t2[idx] * kInvWin - mu_t * mu_t, 0.0f);
            float sxy = sum_rt[idx] * kInvWin - mu_r * mu_t;

            float numerator = (2.0f * mu_r * mu_t + C1) * (2.0f * sxy + C2);
            float denominator = (mu_r * mu_r + mu_t * mu_t + C1) * (sx2 + sy2 + C2);

            // Bug 0.16 fix: when denominator is tiny (low contrast), set ssim=0
            // (not 1.0). ssim=1.0 means "perfect match" which kills gradients
            // for that region. ssim=0.0 forces optimization to continue.
            float ssim = (denominator > 1e-12f) ? numerator / denominator : 0.0f;
            dssim_sum += static_cast<double>((1.0f - ssim) * 0.5f);
            count++;
        }
    }

    return (count > 0) ? static_cast<float>(dssim_sum / static_cast<double>(count)) : 0.0f;
}

/// Compute D-SSIM loss across all 3 RGB channels.
inline float compute_dssim_loss(const float* rendered, const float* target,
                                 std::uint32_t w, std::uint32_t h) noexcept {
    float sum = 0.0f;
    for (std::uint32_t c = 0; c < 3; ++c) {
        sum += compute_dssim_channel(rendered, target, w, h, w * 3, c, 3);
    }
    return sum / 3.0f;
}

/// Combined loss: (1 - lambda) * L1 + lambda * D-SSIM.
inline float compute_combined_loss(const float* rendered, const float* target,
                                    std::uint32_t w, std::uint32_t h,
                                    float lambda_dssim = 0.2f) noexcept {
    float l1 = compute_l1_loss(rendered, target, w, h);
    float dssim = compute_dssim_loss(rendered, target, w, h);
    return (1.0f - lambda_dssim) * l1 + lambda_dssim * dssim;
}

// ─── D-SSIM Gradient (Fused Separable Backward) ─────────────────────

/// Compute D-SSIM gradient w.r.t. rendered image for a single channel.
///
/// Algorithm (separable sum filter approach, O(W×H) per channel):
///   1. Compute per-window statistics via separable sum filters (5 filters)
///   2. At each valid window center, compute gradient scatter maps:
///        map1 = A1/D,  map2 = N·B1/D²,  map3 = K/D²
///   3. Sum-filter the 3 maps to scatter gradients (3 filters)
///   4. Combine: dL/dr = -(1/(count·n))[t·Σmap1 − r·Σmap2 + Σmap3]
///
/// Total: 8 separable sum filters per channel = O(16·W·H) per channel.
/// At 640×480: ~5M ops/channel ≈ ~1ms/channel on A14 CPU.
///
/// @param r_ch      Rendered single-channel image [h×w]
/// @param t_ch      Target single-channel image [h×w]
/// @param w,h       Image dimensions
/// @param out_grad  Output gradient [h×w] (ADDITIVE — adds to existing values)
inline void compute_dssim_gradient_channel(
    const float* r_ch, const float* t_ch,
    std::uint32_t w, std::uint32_t h,
    float* out_grad) noexcept
{
    constexpr float C1 = 0.01f * 0.01f;
    constexpr float C2 = 0.03f * 0.03f;
    constexpr int R = 5;
    constexpr int kWinSize = (2 * R + 1) * (2 * R + 1);  // 121
    constexpr float kInvWin = 1.0f / static_cast<float>(kWinSize);

    if (w < 11 || h < 11) return;

    const std::size_t npix = static_cast<std::size_t>(w) * h;

    // Count valid window centers (at least R from each edge)
    const std::uint32_t valid_w = w - 2 * R;
    const std::uint32_t valid_h = h - 2 * R;
    const std::size_t count = static_cast<std::size_t>(valid_w) * valid_h;
    if (count == 0) return;

    // ── Step 1: Compute per-pixel products ──
    std::vector<float> r2(npix), t2(npix), rt(npix);
    for (std::size_t i = 0; i < npix; ++i) {
        r2[i] = r_ch[i] * r_ch[i];
        t2[i] = t_ch[i] * t_ch[i];
        rt[i] = r_ch[i] * t_ch[i];
    }

    // ── Step 2: Sum-filter all 5 quantities ──
    // Bug 0.40 fix: zero-initialize tmp to prevent garbage in first separable pass
    std::vector<float> tmp(npix, 0.0f);
    std::vector<float> sum_r(npix), sum_t(npix), sum_r2(npix), sum_t2(npix), sum_rt(npix);
    detail::sum_filter_2d(r_ch, sum_r.data(), tmp.data(), w, h, R);
    detail::sum_filter_2d(t_ch, sum_t.data(), tmp.data(), w, h, R);
    detail::sum_filter_2d(r2.data(), sum_r2.data(), tmp.data(), w, h, R);
    detail::sum_filter_2d(t2.data(), sum_t2.data(), tmp.data(), w, h, R);
    detail::sum_filter_2d(rt.data(), sum_rt.data(), tmp.data(), w, h, R);

    // ── Step 3: Compute per-window gradient scatter maps ──
    // Only at valid window centers [R, w-R-1] × [R, h-R-1]
    // map1 = A1/D,  map2 = N·B1/D²,  map3 = K/D²
    std::vector<float> map1(npix, 0.0f), map2(npix, 0.0f), map3(npix, 0.0f);

    for (std::uint32_t y = R; y < h - R; ++y) {
        for (std::uint32_t x = R; x < w - R; ++x) {
            std::size_t idx = y * w + x;

            // Window statistics (mean = sum / n)
            float mu_x = sum_r[idx] * kInvWin;
            float mu_y = sum_t[idx] * kInvWin;
            float sx2 = std::max(sum_r2[idx] * kInvWin - mu_x * mu_x, 0.0f);
            float sy2 = std::max(sum_t2[idx] * kInvWin - mu_y * mu_y, 0.0f);
            float sxy = sum_rt[idx] * kInvWin - mu_x * mu_y;

            // SSIM components
            float A1 = 2.0f * mu_x * mu_y + C1;
            float A2 = 2.0f * sxy + C2;
            float B1 = mu_x * mu_x + mu_y * mu_y + C1;
            float B2 = sx2 + sy2 + C2;
            float N = A1 * A2;
            float D = B1 * B2;

            if (D < 1e-12f) continue;

            float inv_D = 1.0f / D;
            // Bug 0.17 fix: clamp inv_D to prevent gradient explosion when D is
            // near the threshold. inv_D of 1e6 is already extreme.
            inv_D = std::min(inv_D, 1e6f);
            float inv_D2 = inv_D * inv_D;

            // K = D·μ_y·(A2−A1) + N·μ_x·(B1−B2)
            float K = D * mu_y * (A2 - A1) + N * mu_x * (B1 - B2);

            map1[idx] = A1 * inv_D;
            map2[idx] = N * B1 * inv_D2;
            map3[idx] = K * inv_D2;
        }
    }

    // ── Step 4: Sum-filter the scatter maps ──
    std::vector<float> smap1(npix), smap2(npix), smap3(npix);
    detail::sum_filter_2d(map1.data(), smap1.data(), tmp.data(), w, h, R);
    detail::sum_filter_2d(map2.data(), smap2.data(), tmp.data(), w, h, R);
    detail::sum_filter_2d(map3.data(), smap3.data(), tmp.data(), w, h, R);

    // ── Step 5: Combine to get per-pixel gradient ──
    // dL/dr[px,py] = -(1/(count·n)) × [t·Σmap1 − r·Σmap2 + Σmap3]
    float scale = -1.0f / (static_cast<float>(count) * static_cast<float>(kWinSize));

    for (std::size_t i = 0; i < npix; ++i) {
        float g = scale * (t_ch[i] * smap1[i] - r_ch[i] * smap2[i] + smap3[i]);
        out_grad[i] += g;
    }
}

/// Compute D-SSIM gradient across all 3 RGB channels.
/// out_grad[h * w * 3]: gradient to ADD to existing values (interleaved RGB).
inline void compute_dssim_gradient(const float* rendered, const float* target,
                                    std::uint32_t w, std::uint32_t h,
                                    float* out_grad) noexcept {
    if (w < 11 || h < 11) return;

    const std::size_t npix = static_cast<std::size_t>(w) * h;

    // Process each channel with single-channel buffers
    std::vector<float> r_ch(npix), t_ch(npix), g_ch(npix);

    for (std::uint32_t c = 0; c < 3; ++c) {
        // De-interleave channel c
        for (std::size_t i = 0; i < npix; ++i) {
            r_ch[i] = rendered[i * 3 + c];
            t_ch[i] = target[i * 3 + c];
        }

        // Compute D-SSIM gradient for this channel
        std::fill(g_ch.begin(), g_ch.end(), 0.0f);
        compute_dssim_gradient_channel(r_ch.data(), t_ch.data(), w, h, g_ch.data());

        // Average over 3 channels (consistent with compute_dssim_loss /= 3)
        float ch_scale = 1.0f / 3.0f;

        // Interleave back into out_grad
        for (std::size_t i = 0; i < npix; ++i) {
            out_grad[i * 3 + c] += g_ch[i] * ch_scale;
        }
    }
}

// ─── Combined Loss Gradient ─────────────────────────────────────────

/// Compute combined loss gradient: (1−λ)·dL1/dr + λ·dDSSIM/dr.
///
/// This is the primary entry point for backward_pass() in the training engine.
/// Both L1 and D-SSIM gradients now flow into the backward chain.
///
/// @param rendered    Rendered image [h×w×3], float, linear RGB
/// @param target      Target image [h×w×3], float, linear RGB
/// @param w,h         Image dimensions
/// @param out_grad    Output gradient [h×w×3] (overwritten, not accumulated)
/// @param lambda_dssim  D-SSIM weight (default 0.2, standard 3DGS)
inline void compute_loss_gradient(const float* rendered, const float* target,
                                   std::uint32_t w, std::uint32_t h,
                                   float* out_grad,
                                   float lambda_dssim = 0.2f) noexcept {
    const std::size_t total = static_cast<std::size_t>(w) * h * 3;

    // ── L1 gradient, scaled by (1 − λ) ──
    compute_l1_gradient(rendered, target, w, h, out_grad);
    float l1_scale = 1.0f - lambda_dssim;
    for (std::size_t i = 0; i < total; ++i) {
        out_grad[i] *= l1_scale;
    }

    // ── D-SSIM gradient, scaled by λ ──
    if (lambda_dssim > 0.0f && w >= 11 && h >= 11) {
        std::vector<float> dssim_grad(total, 0.0f);
        compute_dssim_gradient(rendered, target, w, h, dssim_grad.data());

        for (std::size_t i = 0; i < total; ++i) {
            out_grad[i] += lambda_dssim * dssim_grad[i];
        }
    }
}

}  // namespace training
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_TRAINING_LOSS_FUNCTIONS_H
