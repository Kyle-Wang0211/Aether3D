// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/tsdf/mesh_topology.h"
#include <cstdio>
#include <cstdlib>

using namespace aether::tsdf;

static int failed = 0;

static void check(bool condition, const char* msg) {
    if (!condition) {
        std::fprintf(stderr, "FAIL: %s\n", msg);
        ++failed;
    }
}

// Test 1: Single triangle — V=3, E=3, F=1, χ=1 (not closed → topology_ok=false)
static void test_single_triangle() {
    MeshTriangle tri{};
    tri.i0 = 0; tri.i1 = 1; tri.i2 = 2;
    auto diag = compute_mesh_topology(&tri, 1, 3);

    check(diag.vertex_count == 3, "single tri: V=3");
    check(diag.edge_count == 3, "single tri: E=3");
    check(diag.face_count == 1, "single tri: F=1");
    check(diag.euler_characteristic == 1, "single tri: chi=1");
    check(!diag.topology_ok, "single tri: not closed");
    check(diag.boundary_edge_count == 3, "single tri: 3 boundary edges");
    std::printf("  PASS test_single_triangle\n");
}

// Test 2: Closed tetrahedron — V=4, E=6, F=4, χ=2 (genus-0 closed)
static void test_tetrahedron() {
    // Tetrahedron: 4 triangles sharing 4 vertices
    MeshTriangle tris[4];
    tris[0] = {0, 1, 2};
    tris[1] = {0, 1, 3};
    tris[2] = {0, 2, 3};
    tris[3] = {1, 2, 3};

    auto diag = compute_mesh_topology(tris, 4, 4);

    check(diag.vertex_count == 4, "tetra: V=4");
    check(diag.edge_count == 6, "tetra: E=6");
    check(diag.face_count == 4, "tetra: F=4");
    check(diag.euler_characteristic == 2, "tetra: chi=2");
    check(diag.topology_ok, "tetra: topology OK (genus-0 closed)");
    check(diag.boundary_edge_count == 0, "tetra: 0 boundary edges");
    std::printf("  PASS test_tetrahedron\n");
}

// Test 3: Two disjoint triangles — V=6, E=6, F=2, χ=2
// Note: χ=2 but each component is open; this tests edge counting.
static void test_two_disjoint_triangles() {
    MeshTriangle tris[2];
    tris[0] = {0, 1, 2};
    tris[1] = {3, 4, 5};

    auto diag = compute_mesh_topology(tris, 2, 6);

    check(diag.vertex_count == 6, "disjoint: V=6");
    check(diag.edge_count == 6, "disjoint: E=6");
    check(diag.face_count == 2, "disjoint: F=2");
    check(diag.euler_characteristic == 2, "disjoint: chi=2");
    check(diag.boundary_edge_count == 6, "disjoint: 6 boundary edges");
    std::printf("  PASS test_two_disjoint_triangles\n");
}

// Test 4: Empty mesh
static void test_empty_mesh() {
    auto diag = compute_mesh_topology(nullptr, 0, 0);
    check(diag.vertex_count == 0, "empty: V=0");
    check(diag.face_count == 0, "empty: F=0");
    check(diag.topology_ok, "empty mesh is OK");
    std::printf("  PASS test_empty_mesh\n");
}

// Test 5: Index-based API
static void test_from_indices() {
    // Same tetrahedron but using raw indices
    uint32_t indices[] = {
        0, 1, 2,
        0, 1, 3,
        0, 2, 3,
        1, 2, 3
    };
    auto diag = compute_mesh_topology_from_indices(indices, 12, 4);

    check(diag.vertex_count == 4, "idx tetra: V=4");
    check(diag.edge_count == 6, "idx tetra: E=6");
    check(diag.face_count == 4, "idx tetra: F=4");
    check(diag.euler_characteristic == 2, "idx tetra: chi=2");
    check(diag.topology_ok, "idx tetra: topology OK");
    std::printf("  PASS test_from_indices\n");
}

// Test 6: Two shared triangles (strip) — V=4, E=5, F=2, χ=1
static void test_triangle_strip() {
    MeshTriangle tris[2];
    tris[0] = {0, 1, 2};
    tris[1] = {1, 2, 3};

    auto diag = compute_mesh_topology(tris, 2, 4);

    check(diag.vertex_count == 4, "strip: V=4");
    check(diag.edge_count == 5, "strip: E=5");
    check(diag.face_count == 2, "strip: F=2");
    check(diag.euler_characteristic == 1, "strip: chi=1");
    // Shared edge (1,2) is referenced by 2 triangles → not boundary
    // Remaining 4 edges are boundary
    check(diag.boundary_edge_count == 4, "strip: 4 boundary edges");
    std::printf("  PASS test_triangle_strip\n");
}

int main() {
    std::printf("test_mesh_topology:\n");
    test_single_triangle();
    test_tetrahedron();
    test_two_disjoint_triangles();
    test_empty_mesh();
    test_from_indices();
    test_triangle_strip();
    std::printf("  %d failures\n", failed);
    return failed;
}
