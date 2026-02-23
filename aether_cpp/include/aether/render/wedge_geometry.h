// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_CPP_RENDER_WEDGE_GEOMETRY_H
#define AETHER_CPP_RENDER_WEDGE_GEOMETRY_H

#ifdef __cplusplus

#include "aether/core/status.h"
#include "aether/innovation/core_types.h"

#include <cstddef>
#include <cstdint>
#include <vector>

namespace aether {
namespace render {

enum class WedgeLodLevel : int {
    kFull = 0,
    kMedium = 1,
    kLow = 2,
    kFlat = 3,
};

struct WedgeTriangleInput {
    innovation::Float3 v0;
    innovation::Float3 v1;
    innovation::Float3 v2;
    innovation::Float3 normal;
    float metallic{0.0f};
    float roughness{0.0f};
    float display{0.0f};
    float thickness{0.0f};
    std::uint32_t triangle_id{0u};
};

struct WedgeVertex {
    innovation::Float3 position;
    innovation::Float3 normal;
    float metallic{0.0f};
    float roughness{0.0f};
    float display{0.0f};
    float thickness{0.0f};
    std::uint32_t triangle_id{0u};
};

core::Status generate_wedge_geometry(
    const WedgeTriangleInput* triangles,
    std::size_t triangle_count,
    WedgeLodLevel lod,
    std::vector<WedgeVertex>* out_vertices,
    std::vector<std::uint32_t>* out_indices);

}  // namespace render
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_CPP_RENDER_WEDGE_GEOMETRY_H
