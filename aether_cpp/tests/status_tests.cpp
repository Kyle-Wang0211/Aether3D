// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// Status / TSDF constants parity and integration tests

#include "aether/tsdf/tsdf_constants.h"
#include "aether/tsdf/block_index.h"
#include "aether/tsdf/tsdf_types.h"
#include "aether/tsdf/tsdf_volume.h"
#include <cmath>
#include <cstdio>
#include <vector>

int main() {
    int failed = 0;

    // Constants parity (Swift TSDFConstants)
    if (std::abs(aether::tsdf::VOXEL_SIZE_NEAR - 0.002f) > 1e-6f) {
        std::fprintf(stderr, "VOXEL_SIZE_NEAR mismatch\n");
        failed++;
    }
    if (aether::tsdf::BLOCK_SIZE != 8) {
        std::fprintf(stderr, "BLOCK_SIZE mismatch\n");
        failed++;
    }
    if (aether::tsdf::MAX_TOTAL_VOXEL_BLOCKS != 10000000) {
        std::fprintf(stderr, "MAX_TOTAL_VOXEL_BLOCKS mismatch\n");
        failed++;
    }

    // BlockIndex Niessner hash
    aether::tsdf::BlockIndex bi(1, 2, 3);
    int h = bi.niessner_hash(65536);
    if (h < 0 || h >= 65536) {
        std::fprintf(stderr, "BlockIndex hash out of range\n");
        failed++;
    }

    // Illegal input: null depth_data -> fail
    {
        aether::tsdf::IntegrationInput input{};
        input.depth_width = 8;
        input.depth_height = 8;
        input.fx = 500.f;
        input.fy = 500.f;
        input.cx = 4.f;
        input.cy = 4.f;
        input.voxel_size = 0.01f;
        float identity[16] = {1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1};
        input.view_matrix = identity;
        aether::tsdf::IntegrationResult result{};
        int rc = aether::tsdf::integrate(input, result);
        if (rc == 0 || result.success) {
            std::fprintf(stderr, "expected null depth_data to fail\n");
            failed++;
        }
    }

    // Normal fusion: valid depth -> voxels_integrated > 0, blocks_updated > 0
    {
        std::vector<float> depth(64, 0.5f);
        float identity[16] = {1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1};
        aether::tsdf::IntegrationInput input{};
        input.depth_data = depth.data();
        input.depth_width = 8;
        input.depth_height = 8;
        input.fx = 500.f;
        input.fy = 500.f;
        input.cx = 4.f;
        input.cy = 4.f;
        input.voxel_size = 0.01f;
        input.view_matrix = identity;

        aether::tsdf::IntegrationResult result{};
        int rc = aether::tsdf::integrate(input, result);
        if (rc != 0 || !result.success) {
            std::fprintf(stderr, "integrate: rc=%d success=%d\n", rc, result.success ? 1 : 0);
            failed++;
        }
        if (result.voxels_integrated <= 0) {
            std::fprintf(stderr, "voxels_integrated=%d (expected > 0)\n", result.voxels_integrated);
            failed++;
        }
        if (result.blocks_updated <= 0) {
            std::fprintf(stderr, "blocks_updated=%d (expected > 0)\n", result.blocks_updated);
            failed++;
        }
    }

    // Determinism: same input 20 times -> same result
    {
        std::vector<float> depth(64, 0.7f);
        float identity[16] = {1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1};
        aether::tsdf::IntegrationInput input{};
        input.depth_data = depth.data();
        input.depth_width = 8;
        input.depth_height = 8;
        input.fx = 600.f;
        input.fy = 600.f;
        input.cx = 4.f;
        input.cy = 4.f;
        input.voxel_size = 0.01f;
        input.view_matrix = identity;

        int first_voxels = 0;
        int first_blocks = 0;
        for (int i = 0; i < 20; ++i) {
            aether::tsdf::IntegrationResult result{};
            int rc = aether::tsdf::integrate(input, result);
            if (rc != 0 || !result.success) {
                std::fprintf(stderr, "determinism run %d: rc=%d\n", i, rc);
                failed++;
                break;
            }
            if (i == 0) {
                first_voxels = result.voxels_integrated;
                first_blocks = result.blocks_updated;
            } else if (result.voxels_integrated != first_voxels || result.blocks_updated != first_blocks) {
                std::fprintf(stderr, "determinism violated at run %d: %d,%d vs %d,%d\n",
                    i, result.voxels_integrated, result.blocks_updated, first_voxels, first_blocks);
                failed++;
                break;
            }
        }
    }

    return failed;
}
