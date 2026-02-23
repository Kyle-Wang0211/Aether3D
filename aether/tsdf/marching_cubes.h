// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_TSDF_MARCHING_CUBES_H
#define AETHER_TSDF_MARCHING_CUBES_H

#include "aether/tsdf/block_index.h"
#include "aether/tsdf/mesh_output.h"
#include "aether/tsdf/voxel_block.h"
#include "aether/math/vec3.h"
#include <cstddef>
#include <cstdint>

namespace aether {
namespace tsdf {

struct McVertex {
    float x, y, z;
};

struct MarchingCubesResult {
    McVertex* vertices{nullptr};
    uint32_t* indices{nullptr};
    size_t vertex_count{0};
    size_t index_count{0};
};

void marching_cubes(const float* sdf_grid, int dim,
                    float origin_x, float origin_y, float origin_z,
                    float voxel_size, MarchingCubesResult& out);

bool is_degenerate_triangle(const McVertex& v0, const McVertex& v1, const McVertex& v2);

// P6-T01: normal generation helpers.
aether::math::Vec3 sdf_gradient_at_corner(
    const float* sdf_grid,
    int dim,
    int gx,
    int gy,
    int gz,
    float voxel_size);

aether::math::Vec3 interpolate_normal(
    const aether::math::Vec3& n0,
    const aether::math::Vec3& n1,
    float t);

aether::math::Vec3 face_normal(const McVertex& a, const McVertex& b, const McVertex& c);

// P6-T03: interpolation stability helper.
float quantize_interpolation(float t, float step);

void extract_incremental_block(
    VoxelBlock& block,
    BlockMeshState* state,
    const BlockIndex& block_index,
    float voxel_size,
    MeshOutput& out,
    size_t triangle_budget,
    std::uint64_t current_frame);

// Backward-compatible wrapper.
inline void extract_incremental_block(
    const VoxelBlock& block,
    const BlockIndex& block_index,
    float voxel_size,
    MeshOutput& out,
    size_t triangle_budget) {
    VoxelBlock mutable_block = block;
    BlockMeshState state{};
    extract_incremental_block(
        mutable_block,
        &state,
        block_index,
        voxel_size,
        out,
        triangle_budget,
        0u);
}

}  // namespace tsdf
}  // namespace aether

#endif  // AETHER_TSDF_MARCHING_CUBES_H
