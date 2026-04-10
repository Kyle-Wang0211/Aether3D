// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/pipeline/local_subject_first_capture_overlay.h"

#include <algorithm>
#include <cmath>

namespace aether {
namespace pipeline {
namespace local_subject_first_capture_overlay {

CaptureDenseSamplingConfig choose_capture_dense_sampling(
    std::size_t dense_confirmed_count,
    double previous_overlay_total_ms) noexcept
{
    CaptureDenseSamplingConfig config;
    if (dense_confirmed_count >= 180000u) {
        config.sample_blocks = 4096u;
        config.bucketing_enabled = true;
    } else if (dense_confirmed_count >= 90000u) {
        config.sample_blocks = 6144u;
        config.bucketing_enabled = true;
    } else if (dense_confirmed_count >= 45000u) {
        config.sample_blocks = 8192u;
        config.bucketing_enabled = true;
    }

    if (previous_overlay_total_ms > 160.0) {
        config.sample_blocks = std::min<std::size_t>(config.sample_blocks, 4096u);
    } else if (previous_overlay_total_ms > 105.0) {
        config.sample_blocks = std::min<std::size_t>(config.sample_blocks, 6144u);
    } else if (previous_overlay_total_ms > 70.0) {
        config.sample_blocks = std::min<std::size_t>(config.sample_blocks, 8192u);
    }

    if (config.sample_blocks <= 4096u) {
        config.perf_tier = "sample_4096";
    } else if (config.sample_blocks <= 6144u) {
        config.perf_tier = "sample_6144";
    } else if (config.sample_blocks <= 8192u) {
        config.perf_tier = "sample_8192";
    }
    return config;
}

int overlay_throttle_ms(
    bool capture_sparse_dense_map,
    std::size_t capture_dense_sample_blocks) noexcept
{
    if (!capture_sparse_dense_map) {
        return 3000;
    }
    if (capture_dense_sample_blocks <= 3072u) {
        return 260;
    }
    if (capture_dense_sample_blocks <= 4096u) {
        return 300;
    }
    if (capture_dense_sample_blocks <= 6144u) {
        return 340;
    }
    return 380;
}

bool should_use_strict_depth_filter(
    bool capture_sparse_dense_map,
    std::size_t depth_keyframe_count,
    bool warmup_overlay) noexcept
{
    return !capture_sparse_dense_map &&
           depth_keyframe_count >= 5u &&
           !warmup_overlay;
}

std::size_t max_depth_filter_keyframes(
    bool capture_sparse_dense_map,
    std::size_t depth_keyframe_count) noexcept
{
    return capture_sparse_dense_map ? 3u : depth_keyframe_count;
}

RelaxedCaptureDepthDecision evaluate_relaxed_capture_depth_gate(
    bool warmup_overlay,
    bool ne_depth_is_metric,
    int checked,
    int consistent) noexcept
{
    RelaxedCaptureDepthDecision decision;
    const int min_relaxed_checks = warmup_overlay ? 1 : 2;
    if (checked < min_relaxed_checks) {
        return decision;
    }

    const int min_relaxed_consistent = 2;
    const float min_relaxed_consistency_ratio =
        ne_depth_is_metric ? 0.35f : 0.40f;
    const float consistency_ratio =
        checked > 0 ? static_cast<float>(consistent) / static_cast<float>(checked) : 0.0f;
    if (warmup_overlay && checked == 1 && consistent == 1) {
        decision.accept = true;
        decision.support_views = 1.0f;
        return decision;
    }
    if (consistent >= min_relaxed_consistent &&
        consistency_ratio >= min_relaxed_consistency_ratio) {
        decision.accept = true;
        decision.support_views = static_cast<float>(consistent);
    }
    return decision;
}

double overlay_hold_seconds(float stability) noexcept
{
    return 0.30 + 0.45 * static_cast<double>(std::clamp(stability, 0.0f, 1.0f));
}

float overlay_display_quality(
    float quality,
    float support_count,
    float stability) noexcept
{
    const float support_norm = std::clamp(support_count / 6.0f, 0.0f, 1.0f);
    const float stability_norm = std::clamp(stability, 0.0f, 1.0f);
    return std::clamp(
        0.30f * quality +
        0.40f * support_norm +
        0.30f * stability_norm,
        0.0f,
        1.0f);
}

bool is_weak_capture_dense_cell(
    bool capture_sparse_dense_map,
    std::uint32_t unique_keyframes_seen,
    float display_quality_peak) noexcept
{
    return capture_sparse_dense_map &&
           (unique_keyframes_seen < 2u || display_quality_peak < 0.70f);
}

double dense_hold_seconds(
    bool capture_sparse_dense_map,
    bool weak_capture_cell,
    float stability,
    std::uint32_t unique_keyframes_seen) noexcept
{
    if (capture_sparse_dense_map) {
        if (weak_capture_cell) {
            return kCaptureDenseWeakHoldSeconds +
                   0.20 * static_cast<double>(std::clamp(stability, 0.0f, 1.0f)) +
                   0.08 * static_cast<double>(std::min<std::uint32_t>(unique_keyframes_seen, 2u));
        }
        return 0.95 +
               0.55 * static_cast<double>(std::clamp(stability, 0.0f, 1.0f)) +
               0.12 * static_cast<double>(std::min<std::uint32_t>(unique_keyframes_seen, 8u));
    }

    return 0.90 +
           0.80 * static_cast<double>(std::clamp(stability, 0.0f, 1.0f)) +
           0.18 * static_cast<double>(std::min<std::uint32_t>(unique_keyframes_seen, 4u));
}

std::uint32_t dense_capture_max_keyframe_age(
    bool weak_capture_cell,
    std::uint32_t unique_keyframes_seen) noexcept
{
    return weak_capture_cell
        ? kCaptureDenseWeakKeyframeAge
        : (5u + std::min<std::uint32_t>(unique_keyframes_seen, 5u));
}

float dense_anchor_bias(float stability) noexcept
{
    return std::clamp(0.18f + 0.12f * stability, 0.18f, 0.30f);
}

float dense_average_display_quality(
    float confidence_accum,
    std::uint32_t update_count) noexcept
{
    const float average_confidence =
        confidence_accum / std::max(1.0f, static_cast<float>(update_count));
    return std::clamp(
        static_cast<float>(std::log1p(std::max(0.0f, average_confidence)) / std::log1p(4.0f)),
        0.0f,
        1.0f);
}

float dense_render_display_quality(
    float average_display_quality,
    float display_quality_peak,
    std::uint32_t unique_keyframes_seen) noexcept
{
    const float keyframe_support_norm = std::clamp(
        static_cast<float>(unique_keyframes_seen) / 3.0f,
        0.0f,
        1.0f);
    return std::clamp(
        0.85f * std::max(average_display_quality, display_quality_peak) +
        0.15f * keyframe_support_norm,
        0.0f,
        1.0f);
}

DenseSuppressionReason classify_capture_dense_suppression(
    bool capture_sparse_dense_map,
    bool ne_depth_is_metric,
    std::uint32_t unique_keyframes_seen,
    float display_quality,
    float distance_m) noexcept
{
    if (!capture_sparse_dense_map) {
        return DenseSuppressionReason::kNone;
    }

    const bool monocular_capture_depth = !ne_depth_is_metric;
    if (monocular_capture_depth &&
        unique_keyframes_seen < 2u &&
        display_quality < 0.68f &&
        distance_m > 1.20f) {
        return DenseSuppressionReason::kLowQuality;
    }
    if (monocular_capture_depth) {
        const bool far_soft_unstable =
            distance_m > kCaptureDenseFarSoftDistanceM && display_quality < 0.56f;
        const bool far_mid_unstable =
            distance_m > kCaptureDenseFarMidDistanceM && display_quality < 0.64f;
        const bool far_hard_unstable =
            distance_m > kCaptureDenseFarHardDistanceM && display_quality < 0.74f;
        if (far_soft_unstable || far_mid_unstable || far_hard_unstable) {
            return DenseSuppressionReason::kFar;
        }
    }
    if (display_quality < kCaptureDenseQualifiedQuality) {
        return DenseSuppressionReason::kLowQuality;
    }
    return DenseSuppressionReason::kNone;
}

bool is_dense_point_fresh(
    bool seen_this_frame,
    double staleness,
    std::uint32_t keyframe_age) noexcept
{
    return seen_this_frame || staleness <= 1.25 || keyframe_age <= 1u;
}

float dense_point_size(bool capture_sparse_dense_map) noexcept
{
    return capture_sparse_dense_map ? 8.5f : 8.5f;
}

float dense_point_alpha(float display_quality) noexcept
{
    return 0.88f + 0.08f * display_quality;
}

float dense_visible_bucket_size(float dist_sq) noexcept
{
    if (dist_sq > 9.0f) {
        return kCaptureDenseVisibleBucketVeryFar;
    }
    if (dist_sq > 4.0f) {
        return kCaptureDenseVisibleBucketFar;
    }
    if (dist_sq > 1.44f) {
        return kCaptureDenseVisibleBucketMid;
    }
    return kCaptureDenseVisibleBucketNear;
}

}  // namespace local_subject_first_capture_overlay
}  // namespace pipeline
}  // namespace aether
