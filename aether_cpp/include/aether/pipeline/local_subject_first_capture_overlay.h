// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_PIPELINE_LOCAL_SUBJECT_FIRST_CAPTURE_OVERLAY_H
#define AETHER_PIPELINE_LOCAL_SUBJECT_FIRST_CAPTURE_OVERLAY_H

#include <cstddef>
#include <cstdint>

namespace aether {
namespace pipeline {
namespace local_subject_first_capture_overlay {

inline constexpr std::size_t kCaptureDenseSampleBlocks = 8192u;
inline constexpr std::size_t kCaptureDenseVisibleCap = 32000u;
inline constexpr std::size_t kCaptureDenseReserveCap = 40000u;
inline constexpr float kCaptureDenseVisibleBucketNear = 0.024f;
inline constexpr float kCaptureDenseVisibleBucketMid = 0.040f;
inline constexpr float kCaptureDenseVisibleBucketFar = 0.060f;
inline constexpr float kCaptureDenseVisibleBucketVeryFar = 0.085f;
inline constexpr float kCaptureDenseQualifiedQuality = 0.62f;
inline constexpr float kCaptureDenseFarSoftDistanceM = 1.6f;
inline constexpr float kCaptureDenseFarMidDistanceM = 2.0f;
inline constexpr float kCaptureDenseFarHardDistanceM = 2.6f;
inline constexpr double kCaptureDenseWeakHoldSeconds = 1.35;
inline constexpr std::uint32_t kCaptureDenseWeakKeyframeAge = 1u;

struct CaptureDenseSamplingConfig {
    std::size_t sample_blocks{kCaptureDenseSampleBlocks};
    bool bucketing_enabled{false};
    const char* perf_tier{"full"};
};

CaptureDenseSamplingConfig choose_capture_dense_sampling(
    std::size_t dense_confirmed_count,
    double previous_overlay_total_ms) noexcept;

int overlay_throttle_ms(
    bool capture_sparse_dense_map,
    std::size_t capture_dense_sample_blocks) noexcept;

bool should_use_strict_depth_filter(
    bool capture_sparse_dense_map,
    std::size_t depth_keyframe_count,
    bool warmup_overlay) noexcept;

std::size_t max_depth_filter_keyframes(
    bool capture_sparse_dense_map,
    std::size_t depth_keyframe_count) noexcept;

struct RelaxedCaptureDepthDecision {
    bool accept{false};
    float support_views{0.0f};
};

RelaxedCaptureDepthDecision evaluate_relaxed_capture_depth_gate(
    bool warmup_overlay,
    bool ne_depth_is_metric,
    int checked,
    int consistent) noexcept;

double overlay_hold_seconds(float stability) noexcept;

float overlay_display_quality(
    float quality,
    float support_count,
    float stability) noexcept;

bool is_weak_capture_dense_cell(
    bool capture_sparse_dense_map,
    std::uint32_t unique_keyframes_seen,
    float display_quality_peak) noexcept;

double dense_hold_seconds(
    bool capture_sparse_dense_map,
    bool weak_capture_cell,
    float stability,
    std::uint32_t unique_keyframes_seen) noexcept;

std::uint32_t dense_capture_max_keyframe_age(
    bool weak_capture_cell,
    std::uint32_t unique_keyframes_seen) noexcept;

float dense_anchor_bias(float stability) noexcept;

float dense_average_display_quality(
    float confidence_accum,
    std::uint32_t update_count) noexcept;

float dense_render_display_quality(
    float average_display_quality,
    float display_quality_peak,
    std::uint32_t unique_keyframes_seen) noexcept;

enum class DenseSuppressionReason : std::uint8_t {
    kNone = 0,
    kLowQuality = 1,
    kFar = 2,
};

DenseSuppressionReason classify_capture_dense_suppression(
    bool capture_sparse_dense_map,
    bool ne_depth_is_metric,
    std::uint32_t unique_keyframes_seen,
    float display_quality,
    float distance_m) noexcept;

bool is_dense_point_fresh(
    bool seen_this_frame,
    double staleness,
    std::uint32_t keyframe_age) noexcept;

float dense_point_size(bool capture_sparse_dense_map) noexcept;

float dense_point_alpha(float display_quality) noexcept;

float dense_visible_bucket_size(float dist_sq) noexcept;

}  // namespace local_subject_first_capture_overlay
}  // namespace pipeline
}  // namespace aether

#endif  // AETHER_PIPELINE_LOCAL_SUBJECT_FIRST_CAPTURE_OVERLAY_H
