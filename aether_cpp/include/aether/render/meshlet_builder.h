// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_CPP_RENDER_MESHLET_BUILDER_H
#define AETHER_CPP_RENDER_MESHLET_BUILDER_H

#ifdef __cplusplus

#include "aether/core/status.h"
#include "aether/tsdf/mesh_output.h"

#include <cstddef>
#include <cstdint>
#include <vector>

namespace aether {
namespace render {

struct MeshletBounds {
    float min_x{0.0f};
    float min_y{0.0f};
    float min_z{0.0f};
    float max_x{0.0f};
    float max_y{0.0f};
    float max_z{0.0f};
};

struct Meshlet {
    std::vector<std::uint32_t> triangle_indices{};
    MeshletBounds bounds{};
    std::uint32_t lod_level{0u};
    float lod_error{0.0f};
};

struct MeshletBuildConfig {
    std::size_t min_triangles_per_meshlet{64u};
    std::size_t max_triangles_per_meshlet{128u};
    std::size_t lod_activation_meshlet_threshold{500u};
};

struct MeshletBuildResult {
    std::vector<Meshlet> meshlets{};
    std::size_t source_triangle_count{0u};
    bool lod_enabled{false};
};

core::Status build_meshlets(
    const tsdf::MeshOutput& mesh,
    const MeshletBuildConfig& config,
    MeshletBuildResult* out_result);

}  // namespace render
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_CPP_RENDER_MESHLET_BUILDER_H
