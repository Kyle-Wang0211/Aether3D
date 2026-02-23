// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/tsdf/marching_cubes.h"
#include "aether/tsdf/voxel_block.h"
#include "aether/tsdf/block_index.h"
#include <cstdio>
#include <cstdlib>
#include <vector>

int main() {
    int failed = 0;
    std::vector<float> sdf(4 * 4 * 4, 1.0f);
    sdf[21] = -0.5f;
    sdf[22] = -0.5f;
    aether::tsdf::MarchingCubesResult result;
    aether::tsdf::marching_cubes(sdf.data(), 4, 0, 0, 0, 0.1f, result);
    if (result.vertex_count == 0 && result.index_count == 0) {
        std::fprintf(stderr, "marching_cubes produced no output\n");
        failed++;
    }

    if (result.vertex_count >= 3) {
        if (aether::tsdf::is_degenerate_triangle(result.vertices[0], result.vertices[1], result.vertices[2])) {
            std::fprintf(stderr, "unexpected degenerate first triangle\n");
            failed++;
        }
    }
    std::free(result.vertices);
    std::free(result.indices);

    aether::tsdf::VoxelBlock block = aether::tsdf::make_empty_block(0.05f);
    block.integration_generation = aether::tsdf::MIN_OBSERVATIONS_BEFORE_MESH;
    block.voxels[0].sdf = aether::tsdf::SDFStorage(-0.2f);
    block.voxels[1].sdf = aether::tsdf::SDFStorage(0.2f);
    block.voxels[8].sdf = aether::tsdf::SDFStorage(0.2f);
    block.voxels[64].sdf = aether::tsdf::SDFStorage(0.2f);
    aether::tsdf::MeshOutput out{};
    aether::tsdf::extract_incremental_block(
        block,
        aether::tsdf::BlockIndex(0, 0, 0),
        0.05f,
        out,
        64);
    if (out.triangle_count == 0) {
        std::fprintf(stderr, "extract_incremental_block produced no triangles\n");
        failed++;
    }
    std::free(out.vertices);
    std::free(out.triangles);
    return failed;
}
