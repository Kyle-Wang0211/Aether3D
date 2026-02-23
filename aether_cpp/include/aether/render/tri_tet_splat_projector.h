// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_CPP_RENDER_TRI_TET_SPLAT_PROJECTOR_H
#define AETHER_CPP_RENDER_TRI_TET_SPLAT_PROJECTOR_H

#ifdef __cplusplus

#include <cstdint>

namespace aether {
namespace render {

struct CameraIntrinsics {
    float fx;
    float fy;
    float cx;
    float cy;
    std::uint32_t width;
    std::uint32_t height;
};

struct ProjectedSplat {
    float u;
    float v;
    float depth;
    std::uint32_t tile_x;
    std::uint32_t tile_y;
    bool valid;
};

ProjectedSplat project_tri_tet_splat(
    float x,
    float y,
    float z,
    float radius,
    const CameraIntrinsics& intrinsics,
    std::uint32_t tile_size);

std::uint32_t tri_tet_tile_digest(
    std::uint32_t tile_x,
    std::uint32_t tile_y,
    std::uint8_t tri_tet_class);

}  // namespace render
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_CPP_RENDER_TRI_TET_SPLAT_PROJECTOR_H
