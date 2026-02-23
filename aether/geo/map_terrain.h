// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_GEO_MAP_TERRAIN_H
#define AETHER_GEO_MAP_TERRAIN_H

#include "aether/core/status.h"

#include <cstddef>
#include <cstdint>

namespace aether {
namespace geo {

struct TerrainConfig {
    uint32_t tile_size{256};
    uint32_t lod_levels{8};
    float morph_range{0.3f};
};

struct TerrainTile {
    float* heights;
    uint32_t width;
    uint32_t height;
    float min_h;
    float max_h;
};

/// Decode Mapbox Terrain-RGB elevation data.
/// h = -10000 + ((R*256*256 + G*256 + B) * 0.1)
core::Status terrain_decode_rgb(const uint8_t* rgb_data, size_t pixel_count,
                                float* out_heights);

/// Select LOD level based on camera distance.
/// Uses log2-based LOD, clamped to [0, lod_levels-1].
core::Status terrain_select_lod(float camera_distance,
                                const TerrainConfig& config,
                                uint32_t* out_lod);

/// Compute morph factor in [0,1] for smooth LOD transitions.
/// Returns 0 when far from switch distance, 1 at the switch point.
float terrain_morph_factor(float camera_distance,
                           float lod_switch_distance,
                           float morph_range);

}  // namespace geo
}  // namespace aether

#endif  // AETHER_GEO_MAP_TERRAIN_H
