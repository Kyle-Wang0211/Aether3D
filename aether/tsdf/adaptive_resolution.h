// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_TSDF_ADAPTIVE_RESOLUTION_H
#define AETHER_TSDF_ADAPTIVE_RESOLUTION_H

#include "aether/math/vec3.h"
#include "aether/tsdf/block_index.h"
#include "aether/tsdf/tsdf_constants.h"
#include <algorithm>
#include <cmath>

namespace aether {
namespace tsdf {

struct ContinuousResolutionConfig {
    float min_voxel_size{0.002f};
    float max_voxel_size{0.032f};
    float min_edge_length{0.005f};
    float max_edge_length{0.5f};
    float depth_range_min{0.3f};
    float depth_range_max{4.5f};
    float display_exponent{0.7f};
    float depth_exponent{1.2f};
    float edge_boost{0.6f};
};

inline float clamp01(float value) {
    return std::max(0.0f, std::min(1.0f, value));
}

inline float smoothstep(float edge0, float edge1, float x) {
    if (edge1 <= edge0) {
        return x >= edge1 ? 1.0f : 0.0f;
    }
    const float t = clamp01((x - edge0) / (edge1 - edge0));
    return t * t * (3.0f - 2.0f * t);
}

inline float exp_lerp(float min_value, float max_value, float t) {
    if (!(min_value > 0.0f) || !(max_value > min_value)) {
        return max_value;
    }
    const float ratio = max_value / min_value;
    return min_value * std::pow(ratio, clamp01(t));
}

inline ContinuousResolutionConfig default_continuous_resolution_config() {
    return ContinuousResolutionConfig{};
}

inline float continuous_voxel_size(
    float depth,
    float display,
    bool is_color_boundary,
    const ContinuousResolutionConfig& config) {
    if (!std::isfinite(depth)) {
        return config.max_voxel_size;
    }
    if (config.min_voxel_size <= 0.0f ||
        config.max_voxel_size <= config.min_voxel_size ||
        config.depth_range_max <= config.depth_range_min ||
        config.depth_exponent <= 0.0f ||
        config.display_exponent <= 0.0f) {
        return VOXEL_SIZE_MID;
    }

    const float inv_depth_range = 1.0f / (config.depth_range_max - config.depth_range_min);
    const float depth_norm = clamp01((depth - config.depth_range_min) * inv_depth_range);
    const float depth_t = std::pow(depth_norm, config.depth_exponent);
    const float display_t = std::pow(1.0f - clamp01(display), config.display_exponent);
    float t = 0.5f * depth_t + 0.5f * display_t;

    const float boundary_mask = is_color_boundary ? 1.0f : 0.0f;
    t *= 1.0f - (1.0f - config.edge_boost) * boundary_mask;
    t = clamp01(t);
    return exp_lerp(config.min_voxel_size, config.max_voxel_size, t);
}

inline float continuous_edge_length(
    float depth,
    float display,
    bool is_color_boundary,
    const ContinuousResolutionConfig& config) {
    if (config.min_edge_length <= 0.0f ||
        config.max_edge_length <= config.min_edge_length) {
        return config.max_edge_length;
    }
    const float inv_depth_range = 1.0f / std::max(1e-6f, config.depth_range_max - config.depth_range_min);
    const float depth_norm = clamp01((depth - config.depth_range_min) * inv_depth_range);
    const float depth_t = std::pow(depth_norm, std::max(1e-3f, config.depth_exponent));
    const float display_t = std::pow(1.0f - clamp01(display), std::max(1e-3f, config.display_exponent));
    float t = 0.5f * depth_t + 0.5f * display_t;
    const float boundary_mask = is_color_boundary ? 1.0f : 0.0f;
    t *= 1.0f - (1.0f - config.edge_boost) * boundary_mask;
    t = clamp01(t);
    return exp_lerp(config.min_edge_length, config.max_edge_length, t);
}

inline float continuous_gap_width(float display, const ContinuousResolutionConfig&) {
    const float t = clamp01(display);
    const float s = t * t;
    return (0.001f * (1.0f - s)) + (0.00005f * s);
}

inline float continuous_fill_opacity(float display) {
    return smoothstep(0.0f, 0.92f, clamp01(display));
}

inline float continuous_border_width(float display, float triangle_area) {
    const float display_factor = std::pow(1.0f - clamp01(display), 1.4f);
    const float area_factor = std::max(0.3f, std::min(3.0f, triangle_area));
    const float raw = 6.0f * (0.6f * display_factor + 0.4f * area_factor);
    return std::max(1.0f, std::min(12.0f, raw));
}

inline float truncation_distance(float voxel_size) {
    const float configured = TRUNCATION_MULTIPLIER * voxel_size;
    const float safe_minimum = 2.0f * voxel_size;
    const float floor = configured > TRUNCATION_MINIMUM ? configured : TRUNCATION_MINIMUM;
    return floor > safe_minimum ? floor : safe_minimum;
}

inline float distance_weight(float depth) {
    return 1.0f / (1.0f + DISTANCE_DECAY_ALPHA * depth * depth);
}

inline float confidence_weight(uint8_t level) {
    if (level == 0) return CONFIDENCE_WEIGHT_LOW;
    if (level == 1) return CONFIDENCE_WEIGHT_MID;
    return CONFIDENCE_WEIGHT_HIGH;
}

inline float viewing_angle_weight(float cosine) {
    const float abs_cos = cosine >= 0.0f ? cosine : -cosine;
    return abs_cos > VIEWING_ANGLE_WEIGHT_FLOOR ? abs_cos : VIEWING_ANGLE_WEIGHT_FLOOR;
}

inline BlockIndex block_index_from_world(const aether::math::Vec3& world_position, float voxel_size) {
    const float block_world_size = voxel_size * static_cast<float>(BLOCK_SIZE);
    return BlockIndex(
        static_cast<int32_t>(std::floor(world_position.x / block_world_size)),
        static_cast<int32_t>(std::floor(world_position.y / block_world_size)),
        static_cast<int32_t>(std::floor(world_position.z / block_world_size)));
}

[[deprecated("Use continuous_voxel_size(depth, display, is_color_boundary, config)")]]
inline float voxel_size_for_depth(float depth) {
    return continuous_voxel_size(
        depth,
        0.5f,
        false,
        default_continuous_resolution_config());
}

}  // namespace tsdf
}  // namespace aether

#endif  // AETHER_TSDF_ADAPTIVE_RESOLUTION_H
