// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_GEO_MAP_TILE_MESH_H
#define AETHER_GEO_MAP_TILE_MESH_H

#include "aether/core/status.h"

#include <cstddef>
#include <cstdint>

namespace aether {
namespace geo {

struct MapVertex {
    float x{0}, y{0}, z{0};
    float u{0}, v{0};
    float nx{0}, ny{0}, nz{1.0f};
};

struct MVTLayer {
    char name[64]{};
    std::uint32_t extent{4096};
    std::uint32_t feature_count{0};
};

/// Self-contained MVT protobuf decoder.
/// Decodes layer metadata from tile data.
core::Status mvt_decode_tile(const std::uint8_t* data, std::size_t size,
                             MVTLayer* out_layers, std::size_t max_layers,
                             std::size_t* out_count);

/// Ear-clipping triangulation of a simple polygon.
/// ring_xy: interleaved (x,y) pairs. vertex_count: number of vertices.
/// out_indices: triangle indices (3 per triangle).
core::Status triangulate_polygon(const float* ring_xy, std::size_t vertex_count,
                                 std::uint32_t* out_indices, std::size_t max_indices,
                                 std::size_t* out_count);

/// Expand a polyline to a triangle strip with given width.
core::Status expand_polyline(const float* line_xy, std::size_t vertex_count,
                             float width,
                             MapVertex* out_vertices, std::size_t max_vertices,
                             std::size_t* out_count);

}  // namespace geo
}  // namespace aether

#endif  // AETHER_GEO_MAP_TILE_MESH_H
