// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/quality/spatial_hash_adjacency.h"

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <vector>

static int g_failed = 0;

static void check(bool cond, const char* msg, int line) {
    if (!cond) {
        std::fprintf(stderr, "FAIL [line %d]: %s\n", line, msg);
        ++g_failed;
    }
}
#define CHECK(cond) check((cond), #cond, __LINE__)

using Tri = aether::quality::Triangle3f;

// Helper: make a triangle from 3 vertices
static Tri make_tri(float ax, float ay, float az,
                    float bx, float by, float bz,
                    float cx, float cy, float cz) {
    Tri t{};
    t.ax = ax; t.ay = ay; t.az = az;
    t.bx = bx; t.by = by; t.bz = bz;
    t.cx = cx; t.cy = cy; t.cz = cz;
    return t;
}

// ---------------------------------------------------------------------------
// build_spatial_hash_adjacency
// ---------------------------------------------------------------------------

static void test_adjacency_two_sharing_edge() {
    // Two triangles sharing edge (0,0,0)-(1,0,0)
    Tri tris[2] = {
        make_tri(0, 0, 0, 1, 0, 0, 0, 1, 0),
        make_tri(0, 0, 0, 1, 0, 0, 0, -1, 0),
    };
    std::vector<std::uint32_t> offsets;
    std::vector<std::uint32_t> neighbors;
    CHECK(aether::quality::build_spatial_hash_adjacency(
              tris, 2, 2.0f, 1e-5f, &offsets, &neighbors) ==
          aether::core::Status::kOk);
    CHECK(offsets.size() == 3u);
    // Each should be neighbor of the other
    bool tri0_has_1 = false;
    bool tri1_has_0 = false;
    for (std::uint32_t i = offsets[0]; i < offsets[1]; ++i) {
        if (neighbors[i] == 1u) { tri0_has_1 = true; }
    }
    for (std::uint32_t i = offsets[1]; i < offsets[2]; ++i) {
        if (neighbors[i] == 0u) { tri1_has_0 = true; }
    }
    CHECK(tri0_has_1);
    CHECK(tri1_has_0);
}

static void test_adjacency_no_shared_edge() {
    // Two triangles far apart
    Tri tris[2] = {
        make_tri(0, 0, 0, 1, 0, 0, 0, 1, 0),
        make_tri(100, 100, 100, 101, 100, 100, 100, 101, 100),
    };
    std::vector<std::uint32_t> offsets;
    std::vector<std::uint32_t> neighbors;
    CHECK(aether::quality::build_spatial_hash_adjacency(
              tris, 2, 2.0f, 1e-5f, &offsets, &neighbors) ==
          aether::core::Status::kOk);
    CHECK(offsets.size() == 3u);
    // No neighbors
    CHECK(offsets[0] == offsets[1]);
    CHECK(offsets[1] == offsets[2]);
}

static void test_adjacency_vertex_sharing_not_edge() {
    // Two triangles sharing exactly one vertex (not an edge)
    Tri tris[2] = {
        make_tri(0, 0, 0, 1, 0, 0, 0, 1, 0),
        make_tri(0, 0, 0, -1, 0, 0, 0, -1, 0),
    };
    std::vector<std::uint32_t> offsets;
    std::vector<std::uint32_t> neighbors;
    CHECK(aether::quality::build_spatial_hash_adjacency(
              tris, 2, 2.0f, 1e-5f, &offsets, &neighbors) ==
          aether::core::Status::kOk);
    // Sharing only 1 vertex => NOT adjacent (need >= 2)
    bool found_neighbor = false;
    for (std::uint32_t i = offsets[0]; i < offsets[1]; ++i) {
        if (neighbors[i] == 1u) { found_neighbor = true; }
    }
    CHECK(!found_neighbor);
}

static void test_adjacency_nearly_coincident_vertices() {
    // Two triangles with vertices that are close but not identical
    // The rv_used fix prevents double-counting
    const float eps = 1e-5f;
    Tri tris[2] = {
        make_tri(0, 0, 0, 1, 0, 0, 0.5f, 1, 0),
        make_tri(eps * 0.1f, 0, 0, 1.0f + eps * 0.1f, 0, 0, 0.5f, -1, 0),
    };
    std::vector<std::uint32_t> offsets;
    std::vector<std::uint32_t> neighbors;
    CHECK(aether::quality::build_spatial_hash_adjacency(
              tris, 2, 2.0f, eps, &offsets, &neighbors) ==
          aether::core::Status::kOk);
    // Should detect as adjacent (2 shared vertices within epsilon)
    bool found = false;
    for (std::uint32_t i = offsets[0]; i < offsets[1]; ++i) {
        if (neighbors[i] == 1u) { found = true; }
    }
    CHECK(found);
}

static void test_adjacency_null_params() {
    Tri tris[1] = {make_tri(0, 0, 0, 1, 0, 0, 0, 1, 0)};
    std::vector<std::uint32_t> offsets;
    std::vector<std::uint32_t> neighbors;
    CHECK(aether::quality::build_spatial_hash_adjacency(
              tris, 1, 2.0f, 1e-5f, nullptr, &neighbors) ==
          aether::core::Status::kInvalidArgument);
    CHECK(aether::quality::build_spatial_hash_adjacency(
              tris, 1, 2.0f, 1e-5f, &offsets, nullptr) ==
          aether::core::Status::kInvalidArgument);
}

static void test_adjacency_empty() {
    std::vector<std::uint32_t> offsets;
    std::vector<std::uint32_t> neighbors;
    CHECK(aether::quality::build_spatial_hash_adjacency(
              nullptr, 0, 2.0f, 1e-5f, &offsets, &neighbors) ==
          aether::core::Status::kOk);
    CHECK(offsets.size() == 1u);  // Just the 0 sentinel
}

// ---------------------------------------------------------------------------
// bfs_distances
// ---------------------------------------------------------------------------

static void test_bfs_chain() {
    // 3 triangles in a chain: 0-1-2
    Tri tris[3] = {
        make_tri(0, 0, 0, 1, 0, 0, 0, 1, 0),
        make_tri(1, 0, 0, 0, 0, 0, 1, 1, 0),  // shares edge with 0
        make_tri(1, 0, 0, 1, 1, 0, 2, 0, 0),   // shares edge with 1
    };
    std::vector<std::uint32_t> offsets;
    std::vector<std::uint32_t> neighbors;
    CHECK(aether::quality::build_spatial_hash_adjacency(
              tris, 3, 3.0f, 1e-5f, &offsets, &neighbors) ==
          aether::core::Status::kOk);

    std::uint32_t source = 0;
    std::vector<std::int32_t> distances;
    CHECK(aether::quality::bfs_distances(
              offsets.data(), neighbors.data(), 3, &source, 1, 10, &distances) ==
          aether::core::Status::kOk);
    CHECK(distances.size() == 3u);
    CHECK(distances[0] == 0);
    CHECK(distances[1] == 1);
    CHECK(distances[2] == 2);
}

static void test_bfs_unreachable() {
    // Two isolated triangles
    Tri tris[2] = {
        make_tri(0, 0, 0, 1, 0, 0, 0, 1, 0),
        make_tri(100, 100, 100, 101, 100, 100, 100, 101, 100),
    };
    std::vector<std::uint32_t> offsets;
    std::vector<std::uint32_t> neighbors;
    CHECK(aether::quality::build_spatial_hash_adjacency(
              tris, 2, 2.0f, 1e-5f, &offsets, &neighbors) ==
          aether::core::Status::kOk);

    std::uint32_t source = 0;
    std::vector<std::int32_t> distances;
    CHECK(aether::quality::bfs_distances(
              offsets.data(), neighbors.data(), 2, &source, 1, 10, &distances) ==
          aether::core::Status::kOk);
    CHECK(distances[0] == 0);
    CHECK(distances[1] == -1);  // Unreachable
}

int main() {
    test_adjacency_two_sharing_edge();
    test_adjacency_no_shared_edge();
    test_adjacency_vertex_sharing_not_edge();
    test_adjacency_nearly_coincident_vertices();
    test_adjacency_null_params();
    test_adjacency_empty();
    test_bfs_chain();
    test_bfs_unreachable();

    if (g_failed == 0) {
        std::fprintf(stdout, "spatial_hash_adjacency_test: all tests passed\n");
    }
    return g_failed;
}
