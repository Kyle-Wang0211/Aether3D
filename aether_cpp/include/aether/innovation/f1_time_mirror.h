// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_INNOVATION_F1_TIME_MIRROR_H
#define AETHER_INNOVATION_F1_TIME_MIRROR_H

#ifdef __cplusplus

#include "aether/core/status.h"
#include "aether/innovation/core_types.h"
#include "aether/innovation/scaffold_patch_map.h"

#include <cstddef>
#include <cstdint>
#include <vector>

namespace aether {
namespace innovation {

struct CameraTrajectoryEntry {
    std::uint64_t frame_id{0};
    CameraPose pose{};
    std::int64_t timestamp_ms{0};
};

struct F1TimeMirrorConfig {
    float start_offset_meters{0.30f};
    float min_flight_duration_s{0.30f};
    float max_flight_duration_s{0.80f};
    float appear_stagger_s{0.015f};
    float appear_jitter_ratio{0.40f};
    float priority_boost_appear_gain{0.35f};
    float priority_boost_cap{8.0f};
    float area_duration_power{0.5f};
    float flight_distance_normalizer_m{2.5f};
    float flight_distance_factor_min{0.2f};
    float flight_distance_factor_max{1.8f};
    float flight_duration_distance_blend_base{0.75f};
    float flight_duration_distance_blend_gain{0.25f};
    float opacity_ramp_ratio{0.30f};
    float min_opacity_ramp_ratio{0.01f};
    float sh_crossfade_start_ratio{0.80f};
    float min_sh_crossfade_span{0.01f};
    float arc_height_base_m{0.03f};
    float arc_height_distance_gain{0.06f};
    float arc_area_normalizer{64.0f};
    float arc_area_factor_min{0.2f};
    float spin_degrees_min{10.0f};
    float spin_degrees_range{25.0f};
    float min_progress_denominator_s{0.001f};
    float safe_total_time_epsilon_s{0.0001f};
};

struct FragmentFlightParams {
    ScaffoldUnitId unit_id{0};
    Float3 start_position{};
    Float3 end_position{};
    Float3 start_normal{0.0f, 0.0f, 1.0f};
    Float3 end_normal{0.0f, 0.0f, 1.0f};
    std::uint64_t first_observed_frame_id{0};
    std::int64_t first_observed_ms{0};
    std::uint16_t priority_boost{0};
    std::uint32_t earliest_capture_sequence{0};
    float appear_offset_s{0.0f};
    float flight_duration_s{0.5f};
    std::uint32_t gaussian_count{0};
};

struct F1AnimationMetrics {
    std::size_t visible_gaussian_count{0};
    std::size_t hidden_gaussian_count{0};
    std::size_t active_fragment_count{0};
    float completion_ratio{0.0f};
};

core::Status f1_build_fragment_queue(
    const ScaffoldUnit* units,
    std::size_t unit_count,
    const ScaffoldVertex* vertices,
    std::size_t vertex_count,
    const GaussianPrimitive* gaussians,
    std::size_t gaussian_count,
    const ScaffoldPatchMap* patch_map,
    const CameraTrajectoryEntry* trajectory,
    std::size_t trajectory_count,
    const F1TimeMirrorConfig& config,
    std::vector<FragmentFlightParams>* out_params);

core::Status f1_animate_frame(
    const GaussianPrimitive* base_gaussians,
    std::size_t gaussian_count,
    const FragmentFlightParams* params,
    std::size_t param_count,
    const ScaffoldPatchMap* patch_map,
    const F1TimeMirrorConfig& config,
    float animation_time_s,
    float animation_total_s,
    std::vector<GaussianPrimitive>* out_animated_gaussians,
    F1AnimationMetrics* out_metrics);

}  // namespace innovation
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_INNOVATION_F1_TIME_MIRROR_H
