// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/render/tri_tet_splat_projector.h"

#include <cstdio>

int main() {
    int failed = 0;

    aether::render::CameraIntrinsics intrinsics{};
    intrinsics.fx = 100.0f;
    intrinsics.fy = 100.0f;
    intrinsics.cx = 50.0f;
    intrinsics.cy = 50.0f;
    intrinsics.width = 100;
    intrinsics.height = 100;

    const auto projected =
        aether::render::project_tri_tet_splat(0.0f, 0.0f, 1.0f, 0.2f, intrinsics, 16u);
    if (!projected.valid) {
        std::fprintf(stderr, "projected splat should be valid for centered camera point\n");
        failed++;
    }
    if (projected.tile_x != 3u || projected.tile_y != 3u) {
        std::fprintf(stderr, "unexpected tile index for centered camera point\n");
        failed++;
    }

    const std::uint32_t digest_a = aether::render::tri_tet_tile_digest(3u, 3u, 0u);
    const std::uint32_t digest_b = aether::render::tri_tet_tile_digest(3u, 3u, 2u);
    if (digest_a == digest_b) {
        std::fprintf(stderr, "tile digest must vary with Tri/Tet class\n");
        failed++;
    }

    return failed;
}
