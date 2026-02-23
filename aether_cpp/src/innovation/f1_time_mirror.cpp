// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/innovation/f1_time_mirror.h"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <utility>
#include <vector>

namespace aether {
namespace innovation {
namespace {

constexpr float kPi = 3.14159265358979323846f;
constexpr float kEpsilon = 1e-6f;
constexpr float kDefaultAreaPowerFloor = 0.01f;
constexpr float kDefaultDurationFloorS = 0.01f;

inline float clampf(float value, float low, float high) {
    return std::max(low, std::min(value, high));
}

inline float smoothstep01(float x) {
    const float t = clampf(x, 0.0f, 1.0f);
    return t * t * (3.0f - 2.0f * t);
}

inline float ease_out_cubic(float x) {
    const float t = clampf(x, 0.0f, 1.0f);
    const float one_minus_t = 1.0f - t;
    return 1.0f - one_minus_t * one_minus_t * one_minus_t;
}

// Minimum-jerk trajectory profile used in robot motion planning.
inline float minimum_jerk(float x) {
    const float t = clampf(x, 0.0f, 1.0f);
    const float t2 = t * t;
    const float t3 = t2 * t;
    const float t4 = t3 * t;
    const float t5 = t4 * t;
    return 10.0f * t3 - 15.0f * t4 + 6.0f * t5;
}

inline Float3 lerp3(const Float3& a, const Float3& b, float t) {
    return add(a, mul(sub(b, a), t));
}

Float3 safe_normalize(const Float3& v, const Float3& fallback) {
    const float len = length(v);
    if (len <= kEpsilon) {
        return normalize(fallback);
    }
    return make_float3(v.x / len, v.y / len, v.z / len);
}

Float3 rodrigues_rotate(const Float3& v, const Float3& axis, float angle) {
    const float c = std::cos(angle);
    const float s = std::sin(angle);
    return add(
        add(mul(v, c), mul(cross(axis, v), s)),
        mul(axis, dot(axis, v) * (1.0f - c)));
}

Float3 rotate_between_normals(
    const Float3& v,
    const Float3& from_normal,
    const Float3& to_normal) {
    const Float3 from = safe_normalize(from_normal, make_float3(0.0f, 0.0f, 1.0f));
    const Float3 to = safe_normalize(to_normal, make_float3(0.0f, 0.0f, 1.0f));
    float c = clampf(dot(from, to), -1.0f, 1.0f);
    if (c >= 1.0f - 1e-5f) {
        return v;
    }
    if (c <= -1.0f + 1e-5f) {
        Float3 axis = cross(from, make_float3(1.0f, 0.0f, 0.0f));
        if (length_sq(axis) < 1e-6f) {
            axis = cross(from, make_float3(0.0f, 1.0f, 0.0f));
        }
        axis = safe_normalize(axis, make_float3(0.0f, 0.0f, 1.0f));
        return rodrigues_rotate(v, axis, kPi);
    }

    Float3 axis = safe_normalize(cross(from, to), make_float3(0.0f, 0.0f, 1.0f));
    const float angle = std::acos(c);
    return rodrigues_rotate(v, axis, angle);
}

std::size_t lower_bound_gaussian_id(
    const std::vector<std::pair<GaussianId, std::size_t>>& map,
    GaussianId id) {
    std::size_t left = 0u;
    std::size_t right = map.size();
    while (left < right) {
        const std::size_t mid = left + (right - left) / 2u;
        if (map[mid].first < id) {
            left = mid + 1u;
        } else {
            right = mid;
        }
    }
    return left;
}

std::size_t lower_bound_unit_id(
    const std::vector<std::pair<ScaffoldUnitId, std::size_t>>& map,
    ScaffoldUnitId unit_id) {
    std::size_t left = 0u;
    std::size_t right = map.size();
    while (left < right) {
        const std::size_t mid = left + (right - left) / 2u;
        if (map[mid].first < unit_id) {
            left = mid + 1u;
        } else {
            right = mid;
        }
    }
    return left;
}

const CameraTrajectoryEntry* lookup_trajectory(
    const std::vector<CameraTrajectoryEntry>& sorted_trajectory,
    std::uint64_t frame_id) {
    if (sorted_trajectory.empty()) {
        return nullptr;
    }
    std::size_t left = 0u;
    std::size_t right = sorted_trajectory.size();
    while (left < right) {
        const std::size_t mid = left + (right - left) / 2u;
        if (sorted_trajectory[mid].frame_id < frame_id) {
            left = mid + 1u;
        } else {
            right = mid;
        }
    }
    if (left < sorted_trajectory.size() && sorted_trajectory[left].frame_id == frame_id) {
        return &sorted_trajectory[left];
    }
    if (left == 0u) {
        return &sorted_trajectory.front();
    }
    if (left >= sorted_trajectory.size()) {
        return &sorted_trajectory.back();
    }
    const auto& before = sorted_trajectory[left - 1u];
    const auto& after = sorted_trajectory[left];
    const std::uint64_t d_before = frame_id - before.frame_id;
    const std::uint64_t d_after = after.frame_id - frame_id;
    return (d_before <= d_after) ? &before : &after;
}

Float3 centroid_from_vertices(
    const ScaffoldUnit& unit,
    const ScaffoldVertex* vertices,
    std::size_t vertex_count,
    const GaussianPrimitive* gaussians,
    const std::vector<std::size_t>& gaussian_indices) {
    if (vertices != nullptr &&
        unit.v0 < vertex_count &&
        unit.v1 < vertex_count &&
        unit.v2 < vertex_count) {
        const Float3 a = vertices[unit.v0].position;
        const Float3 b = vertices[unit.v1].position;
        const Float3 c = vertices[unit.v2].position;
        return make_float3(
            (a.x + b.x + c.x) / 3.0f,
            (a.y + b.y + c.y) / 3.0f,
            (a.z + b.z + c.z) / 3.0f);
    }
    if (gaussian_indices.empty()) {
        return make_float3(0.0f, 0.0f, 0.0f);
    }
    Float3 sum{};
    for (std::size_t idx : gaussian_indices) {
        sum = add(sum, gaussians[idx].position);
    }
    return mul(sum, 1.0f / static_cast<float>(gaussian_indices.size()));
}

float compute_flight_duration(
    float unit_area,
    float flight_distance,
    float min_area,
    float max_area,
    const F1TimeMirrorConfig& config) {
    const float min_duration = std::max(kDefaultDurationFloorS, config.min_flight_duration_s);
    const float max_duration = std::max(min_duration, config.max_flight_duration_s);
    if (!(max_area > min_area)) {
        return 0.5f * (min_duration + max_duration);
    }
    float t = clampf((unit_area - min_area) / (max_area - min_area), 0.0f, 1.0f);
    const float area_power = std::max(kDefaultAreaPowerFloor, config.area_duration_power);
    t = std::pow(t, area_power);
    const float area_duration = min_duration + t * (max_duration - min_duration);
    const float distance_normalizer = std::max(kDefaultDurationFloorS, config.flight_distance_normalizer_m);
    const float distance_factor = clampf(
        flight_distance / distance_normalizer,
        config.flight_distance_factor_min,
        config.flight_distance_factor_max);
    const float distance_blend =
        config.flight_duration_distance_blend_base +
        config.flight_duration_distance_blend_gain * distance_factor;
    return clampf(area_duration * distance_blend, min_duration, max_duration);
}

float stable_unit_jitter01(ScaffoldUnitId unit_id) {
    const std::uint64_t h = splitmix64(unit_id ^ 0x9e3779b97f4a7c15ULL);
    const std::uint32_t top = static_cast<std::uint32_t>((h >> 32u) & 0xffffffffu);
    return static_cast<float>(top) / static_cast<float>(0xffffffffu);
}

core::Status gather_indices_for_unit(
    ScaffoldUnitId unit_id,
    const GaussianPrimitive* gaussians,
    std::size_t gaussian_count,
    const ScaffoldPatchMap* patch_map,
    const std::vector<std::pair<GaussianId, std::size_t>>& id_to_index,
    std::vector<std::size_t>* out_indices) {
    if (out_indices == nullptr) {
        return core::Status::kInvalidArgument;
    }
    out_indices->clear();
    if (gaussians == nullptr || gaussian_count == 0u || unit_id == 0u) {
        return core::Status::kOk;
    }

    if (patch_map != nullptr) {
        std::vector<GaussianId> ids;
        const core::Status ids_status = patch_map->gaussian_ids_for_unit(unit_id, &ids);
        if (ids_status == core::Status::kOk) {
            out_indices->reserve(ids.size());
            for (GaussianId id : ids) {
                const std::size_t pos = lower_bound_gaussian_id(id_to_index, id);
                if (pos < id_to_index.size() && id_to_index[pos].first == id) {
                    out_indices->push_back(id_to_index[pos].second);
                }
            }
            if (!out_indices->empty()) {
                return core::Status::kOk;
            }
        }
    }

    out_indices->reserve(16u);
    for (std::size_t i = 0u; i < gaussian_count; ++i) {
        if (gaussians[i].host_unit_id == unit_id) {
            out_indices->push_back(i);
        }
    }
    return core::Status::kOk;
}

const FragmentFlightParams* find_fragment_params(
    ScaffoldUnitId unit_id,
    const std::vector<std::pair<ScaffoldUnitId, std::size_t>>& unit_to_fragment,
    const std::vector<FragmentFlightParams>& params) {
    if (unit_id == 0u || unit_to_fragment.empty()) {
        return nullptr;
    }
    const std::size_t pos = lower_bound_unit_id(unit_to_fragment, unit_id);
    if (pos < unit_to_fragment.size() && unit_to_fragment[pos].first == unit_id) {
        const std::size_t idx = unit_to_fragment[pos].second;
        if (idx < params.size()) {
            return &params[idx];
        }
    }
    return nullptr;
}

}  // namespace

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
    std::vector<FragmentFlightParams>* out_params) {
    if (out_params == nullptr) {
        return core::Status::kInvalidArgument;
    }
    if ((unit_count > 0u && units == nullptr) ||
        (gaussian_count > 0u && gaussians == nullptr) ||
        (trajectory_count > 0u && trajectory == nullptr)) {
        return core::Status::kInvalidArgument;
    }
    if (unit_count == 0u || gaussian_count == 0u) {
        out_params->clear();
        return core::Status::kOutOfRange;
    }
    if (config.start_offset_meters < 0.0f ||
        config.min_flight_duration_s <= 0.0f ||
        config.max_flight_duration_s <= 0.0f ||
        config.appear_stagger_s < 0.0f ||
        config.appear_jitter_ratio < 0.0f ||
        config.priority_boost_appear_gain < 0.0f ||
        config.priority_boost_cap < 0.0f ||
        config.area_duration_power <= 0.0f ||
        config.flight_distance_normalizer_m <= 0.0f ||
        config.flight_distance_factor_min < 0.0f ||
        config.flight_distance_factor_max < config.flight_distance_factor_min ||
        config.min_opacity_ramp_ratio <= 0.0f ||
        config.min_sh_crossfade_span <= 0.0f ||
        config.arc_height_base_m < 0.0f ||
        config.arc_height_distance_gain < 0.0f ||
        config.arc_area_normalizer <= 0.0f ||
        config.arc_area_factor_min < 0.0f ||
        config.spin_degrees_min < 0.0f ||
        config.spin_degrees_range < 0.0f ||
        config.min_progress_denominator_s <= 0.0f ||
        config.safe_total_time_epsilon_s <= 0.0f) {
        return core::Status::kInvalidArgument;
    }

    std::vector<std::pair<GaussianId, std::size_t>> id_to_index;
    id_to_index.reserve(gaussian_count);
    for (std::size_t i = 0u; i < gaussian_count; ++i) {
        id_to_index.push_back(std::make_pair(gaussians[i].id, i));
    }
    std::sort(id_to_index.begin(), id_to_index.end(), [](const auto& lhs, const auto& rhs) {
        if (lhs.first != rhs.first) {
            return lhs.first < rhs.first;
        }
        return lhs.second < rhs.second;
    });

    std::vector<CameraTrajectoryEntry> sorted_trajectory;
    sorted_trajectory.reserve(trajectory_count);
    for (std::size_t i = 0u; i < trajectory_count; ++i) {
        sorted_trajectory.push_back(trajectory[i]);
    }
    std::sort(sorted_trajectory.begin(), sorted_trajectory.end(), [](const CameraTrajectoryEntry& lhs, const CameraTrajectoryEntry& rhs) {
        if (lhs.frame_id != rhs.frame_id) {
            return lhs.frame_id < rhs.frame_id;
        }
        return lhs.timestamp_ms < rhs.timestamp_ms;
    });

    float min_area = std::numeric_limits<float>::max();
    float max_area = 0.0f;
    for (std::size_t i = 0u; i < unit_count; ++i) {
        min_area = std::min(min_area, units[i].area);
        max_area = std::max(max_area, units[i].area);
    }
    if (min_area == std::numeric_limits<float>::max()) {
        min_area = 0.0f;
    }

    std::vector<FragmentFlightParams> fragments;
    fragments.reserve(unit_count);
    std::vector<std::size_t> bound_indices;
    for (std::size_t i = 0u; i < unit_count; ++i) {
        const ScaffoldUnit& unit = units[i];
        core::Status gather_status = gather_indices_for_unit(
            unit.unit_id,
            gaussians,
            gaussian_count,
            patch_map,
            id_to_index,
            &bound_indices);
        if (gather_status != core::Status::kOk) {
            return gather_status;
        }
        if (bound_indices.empty()) {
            continue;
        }

        FragmentFlightParams params{};
        params.unit_id = unit.unit_id;
        params.end_position = centroid_from_vertices(
            unit, vertices, vertex_count, gaussians, bound_indices);

        std::uint64_t first_frame = 0u;
        std::int64_t first_ms = std::numeric_limits<std::int64_t>::max();
        std::uint16_t max_priority_boost = 0u;
        std::uint32_t earliest_capture_sequence = std::numeric_limits<std::uint32_t>::max();
        for (std::size_t idx : bound_indices) {
            const GaussianPrimitive& g = gaussians[idx];
            if (first_frame == 0u || g.first_observed_frame_id < first_frame) {
                first_frame = g.first_observed_frame_id;
            }
            if (g.first_observed_ms < first_ms) {
                first_ms = g.first_observed_ms;
            }
            max_priority_boost = std::max(max_priority_boost, g.patch_priority);
            if (earliest_capture_sequence == std::numeric_limits<std::uint32_t>::max() ||
                g.capture_sequence < earliest_capture_sequence) {
                earliest_capture_sequence = g.capture_sequence;
            }
        }
        if (first_ms == std::numeric_limits<std::int64_t>::max()) {
            first_ms = 0;
        }
        if (earliest_capture_sequence == std::numeric_limits<std::uint32_t>::max()) {
            earliest_capture_sequence = 0u;
        }
        params.first_observed_frame_id = first_frame;
        params.first_observed_ms = first_ms;
        params.priority_boost = max_priority_boost;
        params.earliest_capture_sequence = earliest_capture_sequence;
        params.gaussian_count = static_cast<std::uint32_t>(bound_indices.size());

        CameraPose pose{};
        bool has_pose = false;
        if (!sorted_trajectory.empty()) {
            const CameraTrajectoryEntry* entry = lookup_trajectory(sorted_trajectory, first_frame);
            if (entry != nullptr) {
                pose = entry->pose;
                has_pose = true;
            }
        }
        if (!has_pose) {
            pose.position = add(params.end_position, make_float3(0.0f, 0.0f, -config.start_offset_meters));
            pose.forward = make_float3(0.0f, 0.0f, 1.0f);
            pose.up = make_float3(0.0f, 1.0f, 0.0f);
        }
        const Float3 forward = safe_normalize(pose.forward, make_float3(0.0f, 0.0f, 1.0f));
        params.start_position = add(pose.position, mul(forward, config.start_offset_meters));
        params.end_normal = safe_normalize(unit.normal, forward);
        params.start_normal = safe_normalize(sub(pose.position, params.end_position), forward);
        const float flight_distance = length(sub(params.end_position, params.start_position));
        params.flight_duration_s = compute_flight_duration(
            unit.area,
            flight_distance,
            min_area,
            max_area,
            config);

        fragments.push_back(params);
    }

    if (fragments.empty()) {
        out_params->clear();
        return core::Status::kOutOfRange;
    }

    std::sort(fragments.begin(), fragments.end(), [](const FragmentFlightParams& lhs, const FragmentFlightParams& rhs) {
        if (lhs.priority_boost != rhs.priority_boost) {
            return lhs.priority_boost > rhs.priority_boost;
        }
        if (lhs.earliest_capture_sequence != rhs.earliest_capture_sequence) {
            return lhs.earliest_capture_sequence < rhs.earliest_capture_sequence;
        }
        if (lhs.first_observed_ms != rhs.first_observed_ms) {
            return lhs.first_observed_ms < rhs.first_observed_ms;
        }
        if (lhs.first_observed_frame_id != rhs.first_observed_frame_id) {
            return lhs.first_observed_frame_id < rhs.first_observed_frame_id;
        }
        return lhs.unit_id < rhs.unit_id;
    });

    for (std::size_t i = 0u; i < fragments.size(); ++i) {
        const float base_offset = config.appear_stagger_s * static_cast<float>(i);
        const float jitter =
            (stable_unit_jitter01(fragments[i].unit_id) - 0.5f) *
            config.appear_stagger_s *
            config.appear_jitter_ratio;
        const float priority_norm =
            clampf(
                static_cast<float>(fragments[i].priority_boost),
                0.0f,
                config.priority_boost_cap) /
            std::max(1.0f, config.priority_boost_cap);
        const float priority_pull =
            config.priority_boost_appear_gain *
            priority_norm *
            config.appear_stagger_s;
        fragments[i].appear_offset_s = std::max(0.0f, base_offset - priority_pull + jitter);
    }
    *out_params = std::move(fragments);
    return core::Status::kOk;
}

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
    F1AnimationMetrics* out_metrics) {
    if (out_animated_gaussians == nullptr) {
        return core::Status::kInvalidArgument;
    }
    if ((gaussian_count > 0u && base_gaussians == nullptr) ||
        (param_count > 0u && params == nullptr)) {
        return core::Status::kInvalidArgument;
    }
    if (gaussian_count == 0u) {
        out_animated_gaussians->clear();
        if (out_metrics != nullptr) {
            *out_metrics = F1AnimationMetrics{};
        }
        return core::Status::kOutOfRange;
    }

    std::vector<GaussianPrimitive> animated(base_gaussians, base_gaussians + gaussian_count);
    if (param_count == 0u) {
        *out_animated_gaussians = std::move(animated);
        if (out_metrics != nullptr) {
            F1AnimationMetrics metrics{};
            metrics.visible_gaussian_count = gaussian_count;
            metrics.hidden_gaussian_count = 0u;
            metrics.active_fragment_count = 0u;
            metrics.completion_ratio = 1.0f;
            *out_metrics = metrics;
        }
        return core::Status::kOk;
    }

    std::vector<FragmentFlightParams> sorted_params(params, params + param_count);
    std::sort(sorted_params.begin(), sorted_params.end(), [](const FragmentFlightParams& lhs, const FragmentFlightParams& rhs) {
        if (lhs.unit_id != rhs.unit_id) {
            return lhs.unit_id < rhs.unit_id;
        }
        return lhs.first_observed_ms < rhs.first_observed_ms;
    });

    std::vector<std::pair<ScaffoldUnitId, std::size_t>> unit_to_fragment;
    unit_to_fragment.reserve(sorted_params.size());
    for (std::size_t i = 0u; i < sorted_params.size(); ++i) {
        unit_to_fragment.push_back(std::make_pair(sorted_params[i].unit_id, i));
    }

    float inferred_total_s = 0.0f;
    for (const auto& p : sorted_params) {
        inferred_total_s = std::max(inferred_total_s, p.appear_offset_s + p.flight_duration_s);
    }
    const float safe_total_s = animation_total_s > 0.0f ? animation_total_s : inferred_total_s;
    const float clamped_time = clampf(animation_time_s, 0.0f, std::max(safe_total_s, config.safe_total_time_epsilon_s));

    std::size_t active_fragment_count = 0u;
    for (const auto& p : sorted_params) {
        if (clamped_time >= p.appear_offset_s &&
            clamped_time < (p.appear_offset_s + p.flight_duration_s)) {
            active_fragment_count += 1u;
        }
    }

    F1AnimationMetrics metrics{};
    metrics.active_fragment_count = active_fragment_count;
    metrics.completion_ratio = (safe_total_s <= kEpsilon) ? 1.0f : clampf(clamped_time / safe_total_s, 0.0f, 1.0f);

    for (std::size_t i = 0u; i < gaussian_count; ++i) {
        GaussianPrimitive& out = animated[i];
        const GaussianPrimitive& base = base_gaussians[i];
        ScaffoldUnitId unit_id = base.host_unit_id;
        if (unit_id == 0u && patch_map != nullptr && !base.patch_id.empty()) {
            ScaffoldUnitId mapped = 0u;
            if (patch_map->unit_id_for_patch_id(base.patch_id, &mapped) == core::Status::kOk) {
                unit_id = mapped;
            }
        }
        const FragmentFlightParams* fragment = find_fragment_params(unit_id, unit_to_fragment, sorted_params);
        if (fragment == nullptr) {
            metrics.visible_gaussian_count += 1u;
            continue;
        }

        const float duration = std::max(config.min_progress_denominator_s, fragment->flight_duration_s);
        const float local_t = (clamped_time - fragment->appear_offset_s) / duration;
        const float progress = clampf(local_t, 0.0f, 1.0f);
        const float eased = minimum_jerk(progress);
        const float eased_fast = ease_out_cubic(progress);

        const Float3 local = sub(base.position, fragment->end_position);
        const Float3 normal_interp = safe_normalize(
            lerp3(fragment->start_normal, fragment->end_normal, eased),
            fragment->end_normal);
        const Float3 rotated_local = rotate_between_normals(local, fragment->end_normal, normal_interp);

        const Float3 chord = sub(fragment->end_position, fragment->start_position);
        const float chord_len = std::max(0.001f, length(chord));
        const Float3 travel_dir = safe_normalize(chord, fragment->end_normal);
        Float3 lift_axis = cross(travel_dir, make_float3(0.0f, 1.0f, 0.0f));
        if (length_sq(lift_axis) < 1e-6f) {
            lift_axis = cross(travel_dir, make_float3(1.0f, 0.0f, 0.0f));
        }
        lift_axis = safe_normalize(lift_axis, fragment->end_normal);
        const float area_factor =
            clampf(
                static_cast<float>(fragment->gaussian_count) / config.arc_area_normalizer,
                config.arc_area_factor_min,
                1.0f);
        const float arc_height =
            config.arc_height_base_m +
            config.arc_height_distance_gain * std::sqrt(chord_len) * area_factor;
        const float arc_t = 4.0f * progress * (1.0f - progress);
        const Float3 center_linear = lerp3(fragment->start_position, fragment->end_position, eased);
        const Float3 center = add(center_linear, mul(lift_axis, arc_height * arc_t));

        const float spin_jitter = stable_unit_jitter01(fragment->unit_id);
        const float spin_max =
            (config.spin_degrees_min + config.spin_degrees_range * spin_jitter) * (kPi / 180.0f);
        const float spin = (1.0f - eased_fast) * spin_max;
        const Float3 spun_local = rodrigues_rotate(rotated_local, travel_dir, spin);
        out.position = add(center, spun_local);

        if (progress <= 0.0f) {
            out.opacity = 0.0f;
            metrics.hidden_gaussian_count += 1u;
        } else {
            const float opacity_t = smoothstep01(progress / std::max(config.min_opacity_ramp_ratio, config.opacity_ramp_ratio));
            out.opacity = base.opacity * opacity_t;
            metrics.visible_gaussian_count += 1u;
        }

        const float sh_t = smoothstep01(
            (progress - config.sh_crossfade_start_ratio) /
            std::max(config.min_sh_crossfade_span, 1.0f - config.sh_crossfade_start_ratio));
        for (std::size_t coeff = 1u; coeff < out.sh_coeffs.size(); ++coeff) {
            out.sh_coeffs[coeff] = base.sh_coeffs[coeff] * sh_t;
        }
    }

    *out_animated_gaussians = std::move(animated);
    if (out_metrics != nullptr) {
        *out_metrics = metrics;
    }
    return core::Status::kOk;
}

}  // namespace innovation
}  // namespace aether
