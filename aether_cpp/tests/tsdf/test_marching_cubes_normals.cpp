// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/tsdf/block_index.h"
#include "aether/tsdf/marching_cubes.h"
#include "aether/tsdf/voxel_block.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <vector>

namespace {

float angle_deg(const aether::math::Vec3& a, const aether::math::Vec3& b) {
    const float al = std::sqrt(a.x * a.x + a.y * a.y + a.z * a.z);
    const float bl = std::sqrt(b.x * b.x + b.y * b.y + b.z * b.z);
    if (al <= 1e-8f || bl <= 1e-8f) return 180.0f;
    float dot = (a.x * b.x + a.y * b.y + a.z * b.z) / (al * bl);
    dot = std::max(-1.0f, std::min(1.0f, dot));
    return std::acos(dot) * 57.2957795f;
}

}  // namespace

int main() {
    int failed = 0;
    using namespace aether::tsdf;

    // Validate gradient against sphere analytic normal around center.
    constexpr int dim = 16;
    constexpr float voxel = 0.05f;
    std::vector<float> sdf(static_cast<std::size_t>(dim * dim * dim), 0.0f);
    const float cx = (dim - 1) * 0.5f;
    const float cy = (dim - 1) * 0.5f;
    const float cz = (dim - 1) * 0.5f;
    const float radius = 0.25f;
    for (int z = 0; z < dim; ++z) {
        for (int y = 0; y < dim; ++y) {
            for (int x = 0; x < dim; ++x) {
                const float wx = (x - cx) * voxel;
                const float wy = (y - cy) * voxel;
                const float wz = (z - cz) * voxel;
                const float d = std::sqrt(wx * wx + wy * wy + wz * wz) - radius;
                sdf[static_cast<std::size_t>(x + y * dim + z * dim * dim)] = d;
            }
        }
    }
    const int gx = dim / 2 + 1;
    const int gy = dim / 2;
    const int gz = dim / 2;
    const aether::math::Vec3 g = sdf_gradient_at_corner(sdf.data(), dim, gx, gy, gz, voxel);
    const aether::math::Vec3 expected(1.0f, 0.0f, 0.0f);
    const float grad_angle = angle_deg(g, expected);
    const float signed_insensitive = std::min(grad_angle, 180.0f - grad_angle);
    if (signed_insensitive > 45.0f) {
        std::fprintf(stderr, "sdf_gradient_at_corner angular error too high\n");
        failed++;
    }

    // Validate generation guard + min observations + fade-in alpha.
    VoxelBlock block = make_empty_block(0.05f);
    block.integration_generation = MIN_OBSERVATIONS_BEFORE_MESH;
    block.voxels[0].sdf = SDFStorage(-0.2f);
    block.voxels[1].sdf = SDFStorage(0.2f);
    block.voxels[8].sdf = SDFStorage(0.2f);
    block.voxels[64].sdf = SDFStorage(0.2f);

    MeshOutput out{};
    BlockMeshState state{};
    extract_incremental_block(block, &state, BlockIndex(0, 0, 0), 0.05f, out, 64u, 1u);
    if (out.vertex_count == 0u || out.triangle_count == 0u) {
        std::fprintf(stderr, "extract_incremental_block failed on first valid generation\n");
        failed++;
    } else if (!(out.vertices[0].alpha < 0.3f)) {
        std::fprintf(stderr, "fade-in alpha first frame mismatch\n");
        failed++;
    }

    const std::size_t before_triangles = out.triangle_count;
    extract_incremental_block(block, &state, BlockIndex(0, 0, 0), 0.05f, out, 64u, 2u);
    if (out.triangle_count != before_triangles) {
        std::fprintf(stderr, "generation guard failed to skip unchanged block\n");
        failed++;
    }

    std::free(out.vertices);
    std::free(out.triangles);
    return failed;
}
