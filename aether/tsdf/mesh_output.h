// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_TSDF_MESH_OUTPUT_H
#define AETHER_TSDF_MESH_OUTPUT_H

#include "aether/math/vec3.h"
#include <cstddef>
#include <cstdint>

namespace aether {
namespace tsdf {

struct MeshVertex {
    aether::math::Vec3 position{};
    aether::math::Vec3 normal{};
    float alpha{1.0f};
    float quality{1.0f};
};

struct MeshTriangle {
    uint32_t i0{0};
    uint32_t i1{0};
    uint32_t i2{0};
};

struct MeshOutput {
    MeshVertex* vertices{nullptr};
    MeshTriangle* triangles{nullptr};
    size_t vertex_count{0};
    size_t triangle_count{0};
    double extraction_timestamp{0.0};
    int dirty_blocks_remaining{0};
};

}  // namespace tsdf
}  // namespace aether

#endif  // AETHER_TSDF_MESH_OUTPUT_H
