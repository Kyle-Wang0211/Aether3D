// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/innovation/f2_scaffold_collision.h"

#include <cmath>
#include <cstdio>
#include <vector>

namespace {

bool approx(float a, float b, float eps) {
    return std::fabs(a - b) <= eps;
}

void make_plane(
    std::vector<aether::innovation::ScaffoldVertex>* out_vertices,
    std::vector<aether::innovation::ScaffoldUnit>* out_units) {
    using namespace aether::innovation;
    out_vertices->clear();
    out_units->clear();

    out_vertices->push_back({0u, make_float3(0.0f, 0.0f, 0.0f)});
    out_vertices->push_back({1u, make_float3(1.0f, 0.0f, 0.0f)});
    out_vertices->push_back({2u, make_float3(1.0f, 1.0f, 0.0f)});
    out_vertices->push_back({3u, make_float3(0.0f, 1.0f, 0.0f)});

    ScaffoldUnit t0{};
    t0.unit_id = 10u;
    t0.v0 = 0u;
    t0.v1 = 1u;
    t0.v2 = 2u;
    out_units->push_back(t0);

    ScaffoldUnit t1{};
    t1.unit_id = 11u;
    t1.v0 = 0u;
    t1.v1 = 2u;
    t1.v2 = 3u;
    out_units->push_back(t1);
}

int test_build_and_queries() {
    int failed = 0;
    using namespace aether::innovation;

    std::vector<ScaffoldVertex> vertices;
    std::vector<ScaffoldUnit> units;
    make_plane(&vertices, &units);

    F2CollisionMesh mesh{};
    const auto st = f2_build_collision_mesh(
        vertices.data(), vertices.size(), units.data(), units.size(), &mesh);
    if (st != aether::core::Status::kOk) {
        std::fprintf(stderr, "f2_build_collision_mesh failed\n");
        return 1;
    }
    if (mesh.triangles.size() != 2u) {
        std::fprintf(stderr, "triangle count mismatch\n");
        failed++;
    }
    if (!(mesh.grid.dim_x > 0u && mesh.grid.dim_y > 0u && mesh.grid.dim_z > 0u)) {
        std::fprintf(stderr, "grid dimensions invalid\n");
        failed++;
    }

    F2CollisionHit hit{};
    const auto ray_status = f2_intersect_ray(
        mesh,
        make_float3(0.25f, 0.25f, 1.0f),
        make_float3(0.0f, 0.0f, -1.0f),
        2.0f,
        &hit);
    if (ray_status != aether::core::Status::kOk || !hit.hit) {
        std::fprintf(stderr, "ray cast should hit plane\n");
        failed++;
    } else if (!approx(hit.position.z, 0.0f, 1e-5f)) {
        std::fprintf(stderr, "ray hit z mismatch\n");
        failed++;
    }

    F2PointDistanceResult dist{};
    const auto dist_status = f2_query_point_distance(
        mesh,
        make_float3(0.2f, 0.2f, 0.3f),
        1.0f,
        &dist);
    if (dist_status != aether::core::Status::kOk || !dist.valid) {
        std::fprintf(stderr, "point distance should be valid\n");
        failed++;
    } else if (!approx(dist.distance, 0.3f, 1e-4f)) {
        std::fprintf(stderr, "point distance mismatch\n");
        failed++;
    }

    return failed;
}

int test_incremental_delta() {
    int failed = 0;
    using namespace aether::innovation;

    std::vector<ScaffoldVertex> vertices;
    std::vector<ScaffoldUnit> units;
    make_plane(&vertices, &units);

    F2CollisionMesh mesh{};
    if (f2_build_collision_mesh(
            vertices.data(), vertices.size(), units.data(), units.size(), &mesh) != aether::core::Status::kOk) {
        std::fprintf(stderr, "base build failed\n");
        return 1;
    }

    ScaffoldUnit upsert{};
    upsert.unit_id = 20u;
    upsert.v0 = 0u;
    upsert.v1 = 1u;
    upsert.v2 = 3u;
    const std::uint64_t remove_ids[1] = {10u};

    F2CollisionDelta delta{};
    delta.upsert_units = &upsert;
    delta.upsert_count = 1u;
    delta.remove_unit_ids = remove_ids;
    delta.remove_count = 1u;

    if (f2_apply_collision_delta(vertices.data(), vertices.size(), delta, &mesh) != aether::core::Status::kOk) {
        std::fprintf(stderr, "delta apply failed\n");
        return 1;
    }
    if (mesh.triangles.size() != 2u) {
        std::fprintf(stderr, "delta triangle count mismatch\n");
        failed++;
    }

    bool has_unit20 = false;
    bool has_unit10 = false;
    for (const auto& tri : mesh.triangles) {
        has_unit20 = has_unit20 || (tri.unit_id == 20u);
        has_unit10 = has_unit10 || (tri.unit_id == 10u);
    }
    if (!has_unit20 || has_unit10) {
        std::fprintf(stderr, "delta replacement mismatch\n");
        failed++;
    }

    return failed;
}

int test_invalid_paths() {
    int failed = 0;
    using namespace aether::innovation;
    std::vector<ScaffoldVertex> vertices;
    std::vector<ScaffoldUnit> units;
    make_plane(&vertices, &units);

    if (f2_build_collision_mesh(
            vertices.data(), vertices.size(), units.data(), units.size(), nullptr) !=
        aether::core::Status::kInvalidArgument) {
        std::fprintf(stderr, "null mesh should fail\n");
        failed++;
    }

    F2CollisionMesh mesh{};
    if (f2_build_collision_mesh(
            vertices.data(), vertices.size(), units.data(), units.size(), &mesh) !=
        aether::core::Status::kOk) {
        std::fprintf(stderr, "build for invalid path failed\n");
        return failed + 1;
    }

    if (f2_intersect_ray(
            mesh,
            make_float3(0.0f, 0.0f, 1.0f),
            make_float3(0.0f, 0.0f, 0.0f),
            1.0f,
            nullptr) != aether::core::Status::kInvalidArgument) {
        std::fprintf(stderr, "null hit output should fail\n");
        failed++;
    }

    return failed;
}

}  // namespace

int main() {
    int failed = 0;
    failed += test_build_and_queries();
    failed += test_incremental_delta();
    failed += test_invalid_paths();
    return failed;
}
