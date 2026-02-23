// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/render/frustum_culler.h"

#include <cstdio>
#include <vector>

int main() {
    int failed = 0;
    using namespace aether::render;
    using aether::tsdf::BlockIndex;

    // Identity-like view (camera at origin looking along +z in this simplified test).
    const float view[16] = {
        1,0,0,0,
        0,1,0,0,
        0,0,1,0,
        0,0,0,1,
    };
    const float proj[16] = {
        1,0,0,0,
        0,1,0,0,
        0,0,1,0,
        0,0,0,1,
    };

    std::vector<BlockIndex> blocks;
    blocks.emplace_back(0, 0, 0);
    blocks.emplace_back(1, 0, 0);
    blocks.emplace_back(100, 0, 0);
    std::vector<float> voxel_sizes(blocks.size(), 0.05f);

    FrustumCullResult result{};
    const aether::core::Status status = cull_blocks(
        blocks.data(),
        blocks.size(),
        voxel_sizes.data(),
        view,
        proj,
        FrustumCullConfig{},
        &result);
    if (status != aether::core::Status::kOk) {
        std::fprintf(stderr, "cull_blocks returned non-ok status\n");
        return 1;
    }
    if (result.total_blocks != blocks.size()) {
        std::fprintf(stderr, "cull_blocks total count mismatch\n");
        failed++;
    }
    if (result.visible_count + result.occluded_count + result.outside_count != result.total_blocks) {
        std::fprintf(stderr, "cull_blocks accounting mismatch\n");
        failed++;
    }

    FrustumPlane planes[6]{};
    float vp[16] = {
        1,0,0,0,
        0,1,0,0,
        0,0,1,0,
        0,0,0,1,
    };
    extract_frustum_planes(vp, planes);
    if (!aabb_outside_frustum(planes, 2.0f, 2.0f, 2.0f, 3.0f, 3.0f, 3.0f)) {
        // For identity clip volume, [2,3]^3 should be outside.
        std::fprintf(stderr, "aabb_outside_frustum expected outside box not rejected\n");
        failed++;
    }

    return failed;
}
