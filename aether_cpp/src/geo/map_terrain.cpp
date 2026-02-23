// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/geo/map_terrain.h"

#include <cmath>

namespace aether {
namespace geo {

// ---------------------------------------------------------------------------
// terrain_decode_rgb: Mapbox Terrain-RGB formula
//   h = -10000 + ((R*256*256 + G*256 + B) * 0.1)
// ---------------------------------------------------------------------------
core::Status terrain_decode_rgb(const uint8_t* rgb_data, size_t pixel_count,
                                float* out_heights) {
    if (!rgb_data || !out_heights) return core::Status::kInvalidArgument;
    if (pixel_count == 0) return core::Status::kInvalidArgument;

    for (size_t i = 0; i < pixel_count; ++i) {
        uint8_t r = rgb_data[i * 3];
        uint8_t g = rgb_data[i * 3 + 1];
        uint8_t b = rgb_data[i * 3 + 2];
        double encoded = static_cast<double>(r) * 256.0 * 256.0
                       + static_cast<double>(g) * 256.0
                       + static_cast<double>(b);
        out_heights[i] = static_cast<float>(-10000.0 + encoded * 0.1);
    }

    return core::Status::kOk;
}

// ---------------------------------------------------------------------------
// terrain_select_lod: log2-based LOD from camera distance
// ---------------------------------------------------------------------------
core::Status terrain_select_lod(float camera_distance,
                                const TerrainConfig& config,
                                uint32_t* out_lod) {
    if (!out_lod) return core::Status::kInvalidArgument;
    if (camera_distance < 0.0f) return core::Status::kInvalidArgument;
    if (config.lod_levels == 0) return core::Status::kInvalidArgument;

    // LOD 0 = highest detail (closest), higher = coarser
    // Use base distance of tile_size as the reference for LOD 0
    float base_distance = static_cast<float>(config.tile_size);
    if (base_distance < 1.0f) base_distance = 1.0f;

    float ratio = camera_distance / base_distance;
    if (ratio < 1.0f) ratio = 1.0f;

    uint32_t lod = static_cast<uint32_t>(std::log2(ratio));

    // Clamp to [0, lod_levels - 1]
    if (lod >= config.lod_levels) {
        lod = config.lod_levels - 1;
    }

    *out_lod = lod;
    return core::Status::kOk;
}

// ---------------------------------------------------------------------------
// terrain_morph_factor: smooth morph in [0,1] near LOD switch distance
// ---------------------------------------------------------------------------
float terrain_morph_factor(float camera_distance,
                           float lod_switch_distance,
                           float morph_range) {
    if (morph_range <= 0.0f) return 0.0f;
    if (lod_switch_distance <= 0.0f) return 0.0f;

    // morph_range is a fraction of the LOD switch distance
    float morph_start = lod_switch_distance * (1.0f - morph_range);
    float morph_end   = lod_switch_distance;

    if (camera_distance <= morph_start) return 0.0f;
    if (camera_distance >= morph_end) return 1.0f;

    // Linear interpolation within the morph zone, then smoothstep
    float t = (camera_distance - morph_start) / (morph_end - morph_start);
    // Smoothstep: 3t^2 - 2t^3
    return t * t * (3.0f - 2.0f * t);
}

}  // namespace geo
}  // namespace aether
