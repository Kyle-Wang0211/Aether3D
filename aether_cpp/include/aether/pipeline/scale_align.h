// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// Plan G W2 D2: Per-frame scale + translation alignment between AI monocular
// depth (DA3-LARGE-1.1 output, scale-invariant relative depth) and metric
// depth from ARKit sparse anchors.
//
// Problem
// -------
// DA3 returns a relative depth map D_ai(u, v) per frame, unitless. ARKit
// gives N sparse 3D anchors per frame with metric world positions. Projecting
// each anchor through the camera intrinsics yields (u_i, v_i, z_metric_i)
// triplets, where z_metric_i is the anchor's depth in meters in camera frame.
//
// Find per-frame (s, t) ∈ ℝ² such that:
//   s · D_ai(u_i, v_i) + t ≈ z_metric_i   for all anchors i
//
// Closed-form least squares (line fit through (z_ai, z_metric) cloud):
//   bar_a = mean(z_ai),  bar_m = mean(z_metric)
//   s = Σ (z_ai_i - bar_a)(z_metric_i - bar_m) / Σ (z_ai_i - bar_a)²
//   t = bar_m - s · bar_a
//   rmse = sqrt(Σ (s·z_ai_i + t - z_metric_i)² / n)
//
// Optional outlier rejection (RANSAC-lite): after initial fit, drop anchors
// with residual > outlier_thresh · rmse and re-fit. One iteration suffices
// for the per-frame use case where most anchors are reliable and outliers
// are obvious (e.g. anchors that drift after frame settles).
//
// Cross-platform: pure header API + .cpp impl, no Apple deps. Caller (Swift /
// Kotlin / Dart) feeds pre-sampled (z_ai, z_metric) pairs.

#ifndef AETHER_PIPELINE_SCALE_ALIGN_H
#define AETHER_PIPELINE_SCALE_ALIGN_H

#ifdef __cplusplus

#include <cstdint>

namespace aether {
namespace pipeline {

/// Result of per-frame LSQ scale + translation fit.
struct ScaleAlignResult {
    float scale{1.0f};       ///< s in: metric ≈ s · z_ai + t
    float translation{0.0f}; ///< t (meters offset)
    float rmse{0.0f};        ///< Root mean squared residual (meters)
    std::int32_t n_used{0};  ///< Anchors used in final fit (after outlier reject)
    std::int32_t n_input{0}; ///< Anchors passed in by caller
    bool ok{false};          ///< true if fit converged (var(z_ai) > 0, n_used >= 2)
};

/// Solve (s, t) by closed-form linear least squares.
///
/// @param z_ai            N AI depth samples at anchor pixel coords.
/// @param z_metric        N metric depths from ARKit (meters).
/// @param n               Number of anchor samples. Minimum 2 for a fit; ideal ≥ 8.
/// @param inlier_dist_m   ABSOLUTE inlier residual threshold in meters.
///                        - inlier_dist_m == 0 → plain LSQ (no outlier rejection)
///                        - inlier_dist_m  > 0 → RANSAC robust fit: random
///                          minimal samples (2 anchors), refit on best inlier
///                          set with |s·z_ai + t - z_metric| < inlier_dist_m.
///                          Plan G suggested 0.05 (= 5 cm) for indoor capture.
///                        rmse-based "K-sigma" rejection was tried and is
///                        non-robust (initial bad fit inflates rmse → outliers
///                        stay inside the threshold). RANSAC handles >50%
///                        outlier fraction reliably.
/// @return ScaleAlignResult. `ok=false` if fewer than 2 anchors usable or all
///         z_ai are identical (zero variance → s undefined).
///
/// Numerical stability: closed-form fit_st + 50-iteration RANSAC. For N up to
/// 1e6 (we expect 10-100), single-precision accumulation has no concerns.
ScaleAlignResult scale_align_lsq(
    const float* z_ai,
    const float* z_metric,
    std::int32_t n,
    float inlier_dist_m = 0.0f) noexcept;

}  // namespace pipeline
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_PIPELINE_SCALE_ALIGN_H
