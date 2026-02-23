// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/render/meshlet_builder.h"

#include <cstdio>
#include <vector>

int main() {
    int failed = 0;

    std::vector<aether::tsdf::MeshVertex> vertices(6u);
    vertices[0].position = aether::math::Vec3(0.0f, 0.0f, 0.4f);
    vertices[1].position = aether::math::Vec3(0.5f, 0.0f, 0.4f);
    vertices[2].position = aether::math::Vec3(0.0f, 0.5f, 0.4f);
    vertices[3].position = aether::math::Vec3(0.5f, 0.5f, 0.4f);
    vertices[4].position = aether::math::Vec3(0.0f, 0.0f, 0.8f);
    vertices[5].position = aether::math::Vec3(0.5f, 0.5f, 0.8f);

    std::vector<aether::tsdf::MeshTriangle> triangles;
    triangles.push_back({0u, 1u, 2u});
    triangles.push_back({1u, 3u, 2u});
    triangles.push_back({0u, 1u, 4u});
    triangles.push_back({1u, 5u, 4u});
    triangles.push_back({2u, 3u, 5u});

    aether::tsdf::MeshOutput mesh{};
    mesh.vertices = vertices.data();
    mesh.triangles = triangles.data();
    mesh.vertex_count = vertices.size();
    mesh.triangle_count = triangles.size();

    aether::render::MeshletBuildConfig cfg{};
    cfg.min_triangles_per_meshlet = 2u;
    cfg.max_triangles_per_meshlet = 2u;
    cfg.lod_activation_meshlet_threshold = 1u;

    aether::render::MeshletBuildResult out{};
    const aether::core::Status status = aether::render::build_meshlets(mesh, cfg, &out);
    if (status != aether::core::Status::kOk) {
        std::fprintf(stderr, "build_meshlets failed on valid mesh\n");
        failed++;
    }
    if (out.meshlets.size() != 3u) {
        std::fprintf(stderr, "meshlet partition count mismatch\n");
        failed++;
    }
    if (!out.lod_enabled) {
        std::fprintf(stderr, "lod should be enabled when threshold is exceeded\n");
        failed++;
    }

    for (const auto& meshlet : out.meshlets) {
        if (meshlet.triangle_indices.empty()) {
            std::fprintf(stderr, "meshlet must contain triangles\n");
            failed++;
            break;
        }
        if (meshlet.bounds.min_x > meshlet.bounds.max_x ||
            meshlet.bounds.min_y > meshlet.bounds.max_y ||
            meshlet.bounds.min_z > meshlet.bounds.max_z) {
            std::fprintf(stderr, "meshlet bounds invalid\n");
            failed++;
            break;
        }
    }

    aether::render::MeshletBuildConfig invalid_cfg{};
    invalid_cfg.min_triangles_per_meshlet = 4u;
    invalid_cfg.max_triangles_per_meshlet = 2u;
    if (aether::render::build_meshlets(mesh, invalid_cfg, &out) != aether::core::Status::kInvalidArgument) {
        std::fprintf(stderr, "build_meshlets should reject invalid config\n");
        failed++;
    }

    std::vector<aether::tsdf::MeshTriangle> bad_triangles = triangles;
    bad_triangles[0].i0 = 99u;
    mesh.triangles = bad_triangles.data();
    if (aether::render::build_meshlets(mesh, cfg, &out) != aether::core::Status::kOutOfRange) {
        std::fprintf(stderr, "build_meshlets should reject out-of-range indices\n");
        failed++;
    }

    return failed;
}
