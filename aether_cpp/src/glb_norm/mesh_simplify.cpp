// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "mesh_simplify.h"

#include "meshoptimizer.h"

#include <cstddef>
#include <utility>

namespace aether::glb_norm {

bool simplify_chart_inplace(std::vector<float>& positions,
                            std::vector<uint32_t>& indices,
                            std::vector<float>& normals,
                            std::vector<float>& uvs,
                            uint32_t target_face_count,
                            float target_error) {
    if (positions.empty() || indices.empty()) {
        return true;
    }
    if (positions.size() % 3 != 0) return false;
    if (indices.size() % 3 != 0) return false;

    const std::size_t vertex_count = positions.size() / 3;
    if (!normals.empty() && normals.size() != positions.size()) return false;
    if (uvs.size() != vertex_count * 2) return false;

    if (target_face_count == 0) return true;
    const std::size_t current_face_count = indices.size() / 3;
    if (current_face_count <= target_face_count) return true;

    const std::size_t target_index_count =
        static_cast<std::size_t>(target_face_count) * 3u;

    std::vector<uint32_t> simplified(indices.size());
    float result_error = 0.0f;
    const std::size_t new_index_count = meshopt_simplify(
        simplified.data(),
        indices.data(), indices.size(),
        positions.data(), vertex_count, sizeof(float) * 3,
        target_index_count, target_error,
        meshopt_SimplifyLockBorder,
        &result_error);

    if (new_index_count == 0 || new_index_count > indices.size()) {
        return false;
    }
    if (new_index_count % 3 != 0) {
        return false;
    }
    simplified.resize(new_index_count);

    // Drop vertices no longer referenced and pack survivors into a
    // dense [0, new_vertex_count) range. The remap also reorders for
    // GPU vertex-fetch cache locality — free bonus, even though our
    // downstream consumer (Filament/three.js post atlas-merge) does
    // its own reorder internally on first draw.
    std::vector<uint32_t> remap(vertex_count);
    const std::size_t new_vertex_count = meshopt_optimizeVertexFetchRemap(
        remap.data(),
        simplified.data(), simplified.size(),
        vertex_count);

    if (new_vertex_count == 0 || new_vertex_count > vertex_count) {
        return false;
    }

    // meshopt_remapVertexBuffer disallows aliasing of dst and src, so
    // we always allocate fresh buffers and move them back in.
    std::vector<float> new_positions(new_vertex_count * 3u);
    meshopt_remapVertexBuffer(new_positions.data(), positions.data(),
                              vertex_count, sizeof(float) * 3, remap.data());

    std::vector<float> new_uvs(new_vertex_count * 2u);
    meshopt_remapVertexBuffer(new_uvs.data(), uvs.data(),
                              vertex_count, sizeof(float) * 2, remap.data());

    std::vector<float> new_normals;
    if (!normals.empty()) {
        new_normals.resize(new_vertex_count * 3u);
        meshopt_remapVertexBuffer(new_normals.data(), normals.data(),
                                  vertex_count, sizeof(float) * 3,
                                  remap.data());
    }

    std::vector<uint32_t> new_indices(simplified.size());
    meshopt_remapIndexBuffer(new_indices.data(), simplified.data(),
                             simplified.size(), remap.data());

    positions = std::move(new_positions);
    uvs       = std::move(new_uvs);
    normals   = std::move(new_normals);
    indices   = std::move(new_indices);
    return true;
}

}  // namespace aether::glb_norm
