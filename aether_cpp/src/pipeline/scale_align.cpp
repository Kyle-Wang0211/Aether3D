// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/pipeline/scale_align.h"

#include <cmath>
#include <cstdint>

namespace aether {
namespace pipeline {

namespace {

/// Closed-form line fit: solves min_(s,t) Σ (s·a_i + t - m_i)²
/// Writes scale, translation to out. Returns true on success (var(a) > 0).
inline bool fit_st(
    const float* z_ai, const float* z_metric, std::int32_t n,
    float& out_scale, float& out_translation) noexcept {

    if (n < 2) return false;

    double sum_a = 0.0, sum_m = 0.0;
    for (std::int32_t i = 0; i < n; ++i) {
        sum_a += static_cast<double>(z_ai[i]);
        sum_m += static_cast<double>(z_metric[i]);
    }
    const double bar_a = sum_a / static_cast<double>(n);
    const double bar_m = sum_m / static_cast<double>(n);

    double cov_am = 0.0, var_a = 0.0;
    for (std::int32_t i = 0; i < n; ++i) {
        const double da = static_cast<double>(z_ai[i]) - bar_a;
        const double dm = static_cast<double>(z_metric[i]) - bar_m;
        cov_am += da * dm;
        var_a += da * da;
    }

    if (var_a < 1.0e-12) return false;

    const double s = cov_am / var_a;
    const double t = bar_m - s * bar_a;
    out_scale = static_cast<float>(s);
    out_translation = static_cast<float>(t);
    return true;
}

/// Compute RMSE of a given fit.
inline float compute_rmse(
    const float* z_ai, const float* z_metric, std::int32_t n,
    float s, float t) noexcept {
    if (n <= 0) return 0.0f;
    double sse = 0.0;
    for (std::int32_t i = 0; i < n; ++i) {
        const double r = static_cast<double>(s) * static_cast<double>(z_ai[i])
            + static_cast<double>(t) - static_cast<double>(z_metric[i]);
        sse += r * r;
    }
    return static_cast<float>(std::sqrt(sse / static_cast<double>(n)));
}

/// Count inliers (|s·z_ai + t - z_metric| < inlier_dist) for a candidate fit.
inline std::int32_t count_inliers(
    const float* z_ai, const float* z_metric, std::int32_t n,
    float s, float t, float inlier_dist) noexcept {
    std::int32_t count = 0;
    for (std::int32_t i = 0; i < n; ++i) {
        const float r = s * z_ai[i] + t - z_metric[i];
        if (std::fabs(r) < inlier_dist) ++count;
    }
    return count;
}

/// 2-point exact line fit (closed form). Returns false if z_ai_a == z_ai_b.
inline bool fit_st_2pt(
    float ai_a, float m_a, float ai_b, float m_b,
    float& out_scale, float& out_translation) noexcept {
    const float dx = ai_b - ai_a;
    if (std::fabs(dx) < 1.0e-6f) return false;
    out_scale = (m_b - m_a) / dx;
    out_translation = m_a - out_scale * ai_a;
    return true;
}

/// xorshift32 PRNG. Deterministic given seed → reproducible RANSAC.
inline std::uint32_t xorshift32(std::uint32_t& state) noexcept {
    std::uint32_t x = state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    state = x;
    return x;
}

}  // namespace

ScaleAlignResult scale_align_lsq(
    const float* z_ai,
    const float* z_metric,
    std::int32_t n,
    float inlier_dist_m) noexcept {

    ScaleAlignResult result;
    result.n_input = n;

    if (z_ai == nullptr || z_metric == nullptr || n < 2) {
        return result;  // ok=false, defaults
    }

    // Branch 1: plain LSQ (no outlier rejection).
    if (inlier_dist_m <= 0.0f) {
        float s, t;
        if (!fit_st(z_ai, z_metric, n, s, t)) {
            return result;
        }
        result.scale = s;
        result.translation = t;
        result.rmse = compute_rmse(z_ai, z_metric, n, s, t);
        result.n_used = n;
        result.ok = true;
        return result;
    }

    // Branch 2: RANSAC robust fit.
    // For 30 anchors with ≤50% outliers, K=50 iterations gives >99% chance of
    // sampling 2 inliers at least once:
    //   p_fail_per_iter = 1 - (1-eps)² ; for eps=0.5, p_fail=0.75
    //   total_failure(K=50) = 0.75^50 ≈ 7e-7
    // We over-allocate K=50 to also cover edge cases (clustered outliers).
    constexpr std::int32_t kMaxRansacIters = 50;
    std::uint32_t rng_state = 0xC0FFEE42u;  // Deterministic seed.

    std::int32_t best_inliers = 0;
    float best_s = 0.0f, best_t = 0.0f;

    for (std::int32_t iter = 0; iter < kMaxRansacIters; ++iter) {
        // Pick 2 distinct random indices via xorshift32.
        const std::int32_t i = static_cast<std::int32_t>(
            xorshift32(rng_state) % static_cast<std::uint32_t>(n));
        std::int32_t j;
        // Re-roll until j != i; bounded by 4 attempts (probability of repeated
        // collision drops exponentially).
        std::int32_t guard = 0;
        do {
            j = static_cast<std::int32_t>(
                xorshift32(rng_state) % static_cast<std::uint32_t>(n));
            ++guard;
        } while (j == i && guard < 4);
        if (j == i) continue;  // pathological — skip this iteration

        float s_cand, t_cand;
        if (!fit_st_2pt(z_ai[i], z_metric[i], z_ai[j], z_metric[j], s_cand, t_cand)) {
            continue;  // same x value — degenerate
        }

        const std::int32_t inliers = count_inliers(
            z_ai, z_metric, n, s_cand, t_cand, inlier_dist_m);

        if (inliers > best_inliers) {
            best_inliers = inliers;
            best_s = s_cand;
            best_t = t_cand;
        }
    }

    if (best_inliers < 2) {
        return result;  // RANSAC couldn't find any consensus
    }

    // Final LSQ refit on best inlier set (limited to 256 anchors stack budget;
    // for larger N caller can pre-filter or skip outlier rejection).
    constexpr std::int32_t kInlierBufCap = 256;
    float ai_in[kInlierBufCap];
    float m_in[kInlierBufCap];
    std::int32_t n_in = 0;
    for (std::int32_t k = 0; k < n && n_in < kInlierBufCap; ++k) {
        const float r = best_s * z_ai[k] + best_t - z_metric[k];
        if (std::fabs(r) < inlier_dist_m) {
            ai_in[n_in] = z_ai[k];
            m_in[n_in] = z_metric[k];
            ++n_in;
        }
    }
    if (n_in < 2) {
        return result;
    }

    float s, t;
    if (!fit_st(ai_in, m_in, n_in, s, t)) {
        // Fall back to the RANSAC 2-pt fit if refit fails (e.g., all inliers
        // collinear with same z_ai — extremely unlikely but defensible).
        result.scale = best_s;
        result.translation = best_t;
        result.rmse = compute_rmse(ai_in, m_in, n_in, best_s, best_t);
        result.n_used = n_in;
        result.ok = true;
        return result;
    }

    result.scale = s;
    result.translation = t;
    result.rmse = compute_rmse(ai_in, m_in, n_in, s, t);
    result.n_used = n_in;
    result.ok = true;
    return result;
}

}  // namespace pipeline
}  // namespace aether
