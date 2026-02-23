// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/render/tri_tet_splat_projector.h"

#include <cmath>

namespace aether {
namespace render {

ProjectedSplat project_tri_tet_splat(
    float x,
    float y,
    float z,
    float radius,
    const CameraIntrinsics& intrinsics,
    std::uint32_t tile_size) {
    ProjectedSplat output{};
    output.valid = false;
    output.u = 0.0f;
    output.v = 0.0f;
    output.depth = z;
    output.tile_x = 0;
    output.tile_y = 0;

    if (z <= 0.0f || tile_size == 0 || intrinsics.width == 0 || intrinsics.height == 0) {
        return output;
    }

    const float clamped_radius = radius < 0.0f ? 0.0f : radius;
    output.u = intrinsics.fx * (x / z) + intrinsics.cx;
    output.v = intrinsics.fy * (y / z) + intrinsics.cy;
    output.depth = z + clamped_radius * 0.01f;

    const bool in_x = output.u >= 0.0f && output.u < static_cast<float>(intrinsics.width);
    const bool in_y = output.v >= 0.0f && output.v < static_cast<float>(intrinsics.height);
    if (!in_x || !in_y) {
        return output;
    }

    const std::uint32_t ux = static_cast<std::uint32_t>(std::floor(output.u));
    const std::uint32_t uy = static_cast<std::uint32_t>(std::floor(output.v));
    output.tile_x = ux / tile_size;
    output.tile_y = uy / tile_size;
    output.valid = true;
    return output;
}

std::uint32_t tri_tet_tile_digest(
    std::uint32_t tile_x,
    std::uint32_t tile_y,
    std::uint8_t tri_tet_class) {
    std::uint32_t h = 0x9e3779b9u;
    h ^= tile_x + 0x7f4a7c15u + (h << 6) + (h >> 2);
    h ^= tile_y + 0x94d049bfu + (h << 6) + (h >> 2);
    h ^= static_cast<std::uint32_t>(tri_tet_class) + 0x165667b1u + (h << 6) + (h >> 2);
    return h;
}

}  // namespace render
}  // namespace aether
