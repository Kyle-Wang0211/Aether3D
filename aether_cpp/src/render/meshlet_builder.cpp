// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/render/meshlet_builder.h"

#include <algorithm>
#include <limits>

namespace aether {
namespace render {
namespace {

MeshletBounds empty_bounds() {
    MeshletBounds bounds{};
    bounds.min_x = std::numeric_limits<float>::max();
    bounds.min_y = std::numeric_limits<float>::max();
    bounds.min_z = std::numeric_limits<float>::max();
    bounds.max_x = -std::numeric_limits<float>::max();
    bounds.max_y = -std::numeric_limits<float>::max();
    bounds.max_z = -std::numeric_limits<float>::max();
    return bounds;
}

void grow_bounds(const tsdf::MeshVertex& vertex, MeshletBounds* bounds) {
    if (bounds == nullptr) {
        return;
    }
    bounds->min_x = std::min(bounds->min_x, vertex.position.x);
    bounds->min_y = std::min(bounds->min_y, vertex.position.y);
    bounds->min_z = std::min(bounds->min_z, vertex.position.z);
    bounds->max_x = std::max(bounds->max_x, vertex.position.x);
    bounds->max_y = std::max(bounds->max_y, vertex.position.y);
    bounds->max_z = std::max(bounds->max_z, vertex.position.z);
}

void finalize_if_empty(MeshletBounds* bounds) {
    if (bounds == nullptr) {
        return;
    }
    if (bounds->min_x > bounds->max_x) {
        *bounds = MeshletBounds{};
    }
}

}  // namespace

core::Status build_meshlets(
    const tsdf::MeshOutput& mesh,
    const MeshletBuildConfig& config,
    MeshletBuildResult* out_result) {
    if (out_result == nullptr) {
        return core::Status::kInvalidArgument;
    }
    out_result->meshlets.clear();
    out_result->source_triangle_count = mesh.triangle_count;
    out_result->lod_enabled = false;

    if ((mesh.vertex_count > 0u && mesh.vertices == nullptr) ||
        (mesh.triangle_count > 0u && mesh.triangles == nullptr)) {
        return core::Status::kInvalidArgument;
    }
    if (mesh.triangle_count == 0u) {
        return core::Status::kOk;
    }
    if (config.min_triangles_per_meshlet == 0u ||
        config.max_triangles_per_meshlet == 0u ||
        config.min_triangles_per_meshlet > config.max_triangles_per_meshlet) {
        return core::Status::kInvalidArgument;
    }

    const std::size_t chunk_size = config.max_triangles_per_meshlet;
    const std::size_t expected_meshlets = (mesh.triangle_count + chunk_size - 1u) / chunk_size;
    out_result->lod_enabled = expected_meshlets > config.lod_activation_meshlet_threshold;
    out_result->meshlets.reserve(expected_meshlets);

    for (std::size_t tri_start = 0u; tri_start < mesh.triangle_count; tri_start += chunk_size) {
        const std::size_t tri_end = std::min(mesh.triangle_count, tri_start + chunk_size);

        Meshlet meshlet{};
        meshlet.bounds = empty_bounds();
        meshlet.triangle_indices.reserve(tri_end - tri_start);

        for (std::size_t tri_idx = tri_start; tri_idx < tri_end; ++tri_idx) {
            const tsdf::MeshTriangle& tri = mesh.triangles[tri_idx];
            if (tri.i0 >= mesh.vertex_count || tri.i1 >= mesh.vertex_count || tri.i2 >= mesh.vertex_count) {
                out_result->meshlets.clear();
                return core::Status::kOutOfRange;
            }
            meshlet.triangle_indices.push_back(static_cast<std::uint32_t>(tri_idx));
            grow_bounds(mesh.vertices[tri.i0], &meshlet.bounds);
            grow_bounds(mesh.vertices[tri.i1], &meshlet.bounds);
            grow_bounds(mesh.vertices[tri.i2], &meshlet.bounds);
        }

        const float coverage = static_cast<float>(meshlet.triangle_indices.size()) / static_cast<float>(chunk_size);
        meshlet.lod_error = std::max(0.0f, 1.0f - coverage);
        meshlet.lod_level = (out_result->lod_enabled && coverage < 0.75f) ? 1u : 0u;
        finalize_if_empty(&meshlet.bounds);

        out_result->meshlets.push_back(meshlet);
    }

    return core::Status::kOk;
}

}  // namespace render
}  // namespace aether
