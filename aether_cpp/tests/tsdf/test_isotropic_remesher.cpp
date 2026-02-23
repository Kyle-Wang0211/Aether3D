// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/tsdf/isotropic_remesher.h"

#include <cstdint>
#include <cstdio>

namespace {

using aether::tsdf::MeshTriangle;

bool tri_valid_local(const MeshTriangle& tri, std::size_t vertex_count) {
    return tri.i0 < vertex_count && tri.i1 < vertex_count && tri.i2 < vertex_count &&
        tri.i0 != tri.i1 && tri.i1 != tri.i2 && tri.i0 != tri.i2;
}

bool edge_exists(const MeshTriangle* triangles, std::size_t triangle_count, std::uint32_t a, std::uint32_t b) {
    const std::uint32_t lo = a < b ? a : b;
    const std::uint32_t hi = a < b ? b : a;
    for (std::size_t i = 0u; i < triangle_count; ++i) {
        const MeshTriangle tri = triangles[i];
        const std::uint32_t v[3] = {tri.i0, tri.i1, tri.i2};
        for (int k = 0; k < 3; ++k) {
            const std::uint32_t e0 = v[k];
            const std::uint32_t e1 = v[(k + 1) % 3];
            const std::uint32_t elo = e0 < e1 ? e0 : e1;
            const std::uint32_t ehi = e0 < e1 ? e1 : e0;
            if (elo == lo && ehi == hi) {
                return true;
            }
        }
    }
    return false;
}

int test_basic_remesh_path() {
    using namespace aether::tsdf;
    int failed = 0;

    MeshVertex vertices[16]{};
    vertices[0].position = aether::math::Vec3(0.0f, 0.0f, 0.0f);
    vertices[1].position = aether::math::Vec3(1.0f, 0.0f, 0.0f);
    vertices[2].position = aether::math::Vec3(1.0f, 1.0f, 0.0f);
    vertices[3].position = aether::math::Vec3(0.0f, 1.0f, 0.0f);

    MeshTriangle triangles[16]{};
    triangles[0] = MeshTriangle{0u, 1u, 2u};
    triangles[1] = MeshTriangle{0u, 2u, 3u};

    std::size_t vertex_count = 4u;
    std::size_t triangle_count = 2u;
    RemeshResult result{};
    RemeshConfig cfg{};
    cfg.target_edge_length = 0.5f;
    cfg.max_iterations = 3;
    cfg.collapse_threshold_ratio = 0.2f;
    cfg.collapse_threshold_ratio = 0.2f;
    cfg.collapse_threshold_ratio = 0.2f;

    const aether::core::Status status = isotropic_remesh(
        vertices,
        &vertex_count,
        triangles,
        &triangle_count,
        16u,
        16u,
        cfg,
        &result);
    if (status != aether::core::Status::kOk) {
        std::fprintf(stderr, "isotropic_remesh failed\n");
        return 1;
    }
    if (result.output_vertex_count == 0u || result.output_triangle_count == 0u) {
        std::fprintf(stderr, "isotropic_remesh produced empty output\n");
        failed++;
    }
    if (result.iterations_used <= 0) {
        std::fprintf(stderr, "isotropic_remesh did not run iterations\n");
        failed++;
    }
    return failed;
}

int test_edge_flip_improves_quality() {
    using namespace aether::tsdf;
    int failed = 0;

    MeshVertex vertices[8]{};
    vertices[0].position = aether::math::Vec3(-1.0f, 0.0f, 0.0f);
    vertices[1].position = aether::math::Vec3(0.0f, 0.05f, 0.0f);
    vertices[2].position = aether::math::Vec3(1.0f, 0.0f, 0.0f);
    vertices[3].position = aether::math::Vec3(0.0f, 2.0f, 0.0f);

    MeshTriangle triangles[8]{};
    triangles[0] = MeshTriangle{0u, 1u, 2u};
    triangles[1] = MeshTriangle{0u, 2u, 3u};
    std::size_t vertex_count = 4u;
    std::size_t triangle_count = 2u;

    RemeshConfig cfg{};
    cfg.target_edge_length = 1.0f;
    cfg.max_iterations = 1;
    cfg.split_threshold_ratio = 10.0f;
    cfg.collapse_threshold_ratio = 0.01f;
    cfg.smoothing_lambda = 0.0f;

    RemeshResult result{};
    const aether::core::Status status = isotropic_remesh(
        vertices,
        &vertex_count,
        triangles,
        &triangle_count,
        8u,
        8u,
        cfg,
        &result);
    if (status != aether::core::Status::kOk) {
        std::fprintf(stderr, "edge flip case remesh failed\n");
        return 1;
    }
    if (result.flips_performed == 0u) {
        std::fprintf(stderr, "edge flip was not performed on skinny quad\n");
        failed++;
    }
    if (!edge_exists(triangles, triangle_count, 1u, 3u)) {
        std::fprintf(stderr, "expected flipped diagonal (1,3) not found\n");
        failed++;
    }
    return failed;
}

int test_collapse_reindexes_topology() {
    using namespace aether::tsdf;
    int failed = 0;

    MeshVertex vertices[8]{};
    vertices[0].position = aether::math::Vec3(0.0f, 0.0f, 0.0f);
    vertices[1].position = aether::math::Vec3(0.01f, 0.0f, 0.0f);
    vertices[2].position = aether::math::Vec3(1.0f, 0.5f, 0.0f);
    vertices[3].position = aether::math::Vec3(0.0f, 1.0f, 0.0f);

    MeshTriangle triangles[8]{};
    triangles[0] = MeshTriangle{0u, 1u, 2u};
    triangles[1] = MeshTriangle{0u, 2u, 3u};
    std::size_t vertex_count = 4u;
    std::size_t triangle_count = 2u;

    RemeshConfig cfg{};
    cfg.target_edge_length = 1.0f;
    cfg.max_iterations = 1;
    cfg.split_threshold_ratio = 10.0f;
    cfg.collapse_threshold_ratio = 0.6f;
    cfg.smoothing_lambda = 0.0f;

    RemeshResult result{};
    const aether::core::Status status = isotropic_remesh(
        vertices,
        &vertex_count,
        triangles,
        &triangle_count,
        8u,
        8u,
        cfg,
        &result);
    if (status != aether::core::Status::kOk) {
        std::fprintf(stderr, "collapse reindex case remesh failed\n");
        return 1;
    }
    if (result.collapses_performed == 0u) {
        std::fprintf(stderr, "expected collapse was not performed\n");
        failed++;
    }
    for (std::size_t i = 0u; i < triangle_count; ++i) {
        if (!tri_valid_local(triangles[i], vertex_count)) {
            std::fprintf(stderr, "invalid triangle after collapse reindex\n");
            failed++;
            break;
        }
    }
    if (vertex_count >= 4u) {
        std::fprintf(stderr, "expected vertex compaction after collapse\n");
        failed++;
    }
    return failed;
}

}  // namespace

int main() {
    int failed = 0;
    failed += test_basic_remesh_path();
    failed += test_edge_flip_improves_quality();
    failed += test_collapse_reindexes_topology();
    return failed;
}
