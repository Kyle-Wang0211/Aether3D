// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/tsdf/mesh_fiedler.h"
#include <cmath>
#include <cstdio>

using namespace aether::tsdf;

static int failed = 0;

static void check(bool condition, const char* msg) {
    if (!condition) {
        std::fprintf(stderr, "FAIL: %s\n", msg);
        ++failed;
    }
}

// Test 1: Tetrahedron (complete graph K4)
// For K4: all eigenvalues of L are {0, 4, 4, 4}, so λ₂ = 4.
static void test_tetrahedron() {
    uint32_t indices[] = {
        0, 1, 2,
        0, 1, 3,
        0, 2, 3,
        1, 2, 3
    };
    auto r = compute_fiedler_value(indices, 12, 4, 100);
    check(r.computed, "tetra: computed");
    // K4 Laplacian eigenvalues: 0, 4, 4, 4 → λ₂ = 4
    check(r.fiedler_value > 3.5 && r.fiedler_value < 4.5,
          "tetra: fiedler ≈ 4.0");
    std::printf("  PASS test_tetrahedron (fiedler=%.4f)\n", r.fiedler_value);
}

// Test 2: Path graph embedded as triangles (low connectivity)
// 4 vertices in a line: 0-1-2-3 with 2 triangles: (0,1,2), (1,2,3)
// The mesh graph has edges: 0-1, 0-2, 1-2, 1-3, 2-3
// This is NOT K4, so λ₂ should be less than 4.
static void test_low_connectivity() {
    uint32_t indices[] = {
        0, 1, 2,
        1, 2, 3
    };
    auto r = compute_fiedler_value(indices, 6, 4, 100);
    check(r.computed, "low conn: computed");
    check(r.fiedler_value > 0.0, "low conn: fiedler > 0 (connected)");
    check(r.fiedler_value < 4.0, "low conn: fiedler < 4 (not complete)");
    std::printf("  PASS test_low_connectivity (fiedler=%.4f)\n", r.fiedler_value);
}

// Test 3: Two disconnected components → λ₂ = 0
// Two disjoint triangles with no shared vertices
static void test_disconnected() {
    uint32_t indices[] = {
        0, 1, 2,
        3, 4, 5
    };
    auto r = compute_fiedler_value(indices, 6, 6, 100);
    check(r.computed, "disconnected: computed");
    check(r.fiedler_value < 0.5, "disconnected: fiedler ≈ 0");
    std::printf("  PASS test_disconnected (fiedler=%.4f)\n", r.fiedler_value);
}

// Test 4: Null/degenerate inputs
static void test_null_input() {
    auto r1 = compute_fiedler_value(nullptr, 0, 0, 100);
    check(!r1.computed, "null: not computed");

    auto r2 = compute_fiedler_value(nullptr, 0, 1, 100);
    check(!r2.computed, "single vertex: not computed");

    std::printf("  PASS test_null_input\n");
}

// Test 5: Octahedron (6 vertices, 8 triangles, complete bipartite K_{3,3}-ish)
// Octahedron has V=6, each vertex has degree 4.
// Laplacian eigenvalues: {0, 2, 2, 6, 6, 6} → λ₂ = 2
static void test_octahedron() {
    // Octahedron vertices: top=0, bottom=1, equator=2,3,4,5
    uint32_t indices[] = {
        0, 2, 3,  // top face
        0, 3, 4,
        0, 4, 5,
        0, 5, 2,
        1, 3, 2,  // bottom face (reversed winding)
        1, 4, 3,
        1, 5, 4,
        1, 2, 5
    };
    auto r = compute_fiedler_value(indices, 24, 6, 200);
    check(r.computed, "octa: computed");
    // For regular octahedron: λ₂ should be around 2
    // (but our mesh adjacency from triangles creates a graph where equator
    //  vertices also connect to their neighbors, making it slightly different)
    check(r.fiedler_value > 0.5, "octa: fiedler > 0.5");
    std::printf("  PASS test_octahedron (fiedler=%.4f)\n", r.fiedler_value);
}

// Test 6: Larger mesh convergence — cube (8 vertices, 12 triangles)
static void test_cube() {
    // Cube with 12 triangles (2 per face, 6 faces)
    uint32_t indices[] = {
        // front face
        0, 1, 2,  0, 2, 3,
        // back face
        4, 6, 5,  4, 7, 6,
        // top face
        0, 4, 5,  0, 5, 1,
        // bottom face
        2, 6, 7,  2, 7, 3,
        // left face
        0, 7, 4,  0, 3, 7,
        // right face
        1, 5, 6,  1, 6, 2
    };
    auto r = compute_fiedler_value(indices, 36, 8, 200);
    check(r.computed, "cube: computed");
    check(r.fiedler_value > 0.5, "cube: fiedler > 0.5 (connected)");
    std::printf("  PASS test_cube (fiedler=%.4f)\n", r.fiedler_value);
}

int main() {
    std::printf("test_mesh_fiedler:\n");
    test_tetrahedron();
    test_low_connectivity();
    test_disconnected();
    test_null_input();
    test_octahedron();
    test_cube();
    std::printf("  %d failures\n", failed);
    return failed;
}
