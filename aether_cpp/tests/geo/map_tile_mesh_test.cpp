// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/geo/map_tile_mesh.h"

#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

int main() {
    int failed = 0;
    using namespace aether::geo;

    // -- Test 1: Default MapVertex values. --
    {
        MapVertex v{};
        if (v.x != 0.0f || v.y != 0.0f || v.z != 0.0f) {
            std::fprintf(stderr,
                         "default MapVertex position should be (0,0,0)\n");
            failed++;
        }
        if (v.nz != 1.0f) {
            std::fprintf(stderr,
                         "default MapVertex nz should be 1.0, got %f\n", v.nz);
            failed++;
        }
    }

    // -- Test 2: Default MVTLayer values. --
    {
        MVTLayer layer{};
        if (layer.extent != 4096) {
            std::fprintf(stderr,
                         "default MVTLayer extent should be 4096, got %u\n",
                         layer.extent);
            failed++;
        }
        if (layer.feature_count != 0) {
            std::fprintf(stderr,
                         "default MVTLayer feature_count should be 0\n");
            failed++;
        }
    }

    // -- Test 3: triangulate_polygon with a simple triangle (3 vertices). --
    {
        // Triangle: (0,0), (1,0), (0,1)
        float ring_xy[] = {0.0f, 0.0f, 1.0f, 0.0f, 0.0f, 1.0f};
        std::uint32_t out_indices[3] = {0};
        std::size_t out_count = 0;

        auto st = triangulate_polygon(ring_xy, 3, out_indices, 3, &out_count);
        if (st != aether::core::Status::kOk) {
            std::fprintf(stderr,
                         "triangulate_polygon returned error for triangle\n");
            failed++;
        }
        if (out_count != 3) {
            std::fprintf(stderr,
                         "triangle should produce 3 indices, got %zu\n",
                         out_count);
            failed++;
        }
    }

    // -- Test 4: triangulate_polygon with a square (4 vertices -> 2 triangles). --
    {
        // Square: (0,0), (1,0), (1,1), (0,1)
        float ring_xy[] = {0.0f, 0.0f, 1.0f, 0.0f, 1.0f, 1.0f, 0.0f, 1.0f};
        std::uint32_t out_indices[6] = {0};
        std::size_t out_count = 0;

        auto st = triangulate_polygon(ring_xy, 4, out_indices, 6, &out_count);
        if (st != aether::core::Status::kOk) {
            std::fprintf(stderr,
                         "triangulate_polygon returned error for square\n");
            failed++;
        }
        // 4-vertex polygon -> 2 triangles -> 6 indices.
        if (out_count != 6) {
            std::fprintf(stderr,
                         "square should produce 6 indices, got %zu\n",
                         out_count);
            failed++;
        }
    }

    // -- Test 5: triangulate_polygon with degenerate input (< 3 vertices). --
    {
        float ring_xy[] = {0.0f, 0.0f, 1.0f, 0.0f};
        std::uint32_t out_indices[3] = {0};
        std::size_t out_count = 0;

        auto st = triangulate_polygon(ring_xy, 2, out_indices, 3, &out_count);
        if (st == aether::core::Status::kOk && out_count > 0) {
            std::fprintf(stderr,
                         "triangulate_polygon with 2 vertices should not produce triangles\n");
            failed++;
        }
    }

    // -- Test 6: expand_polyline with a simple 2-point line. --
    {
        float line_xy[] = {0.0f, 0.0f, 10.0f, 0.0f};
        MapVertex out_vertices[16]{};
        std::size_t out_count = 0;

        auto st = expand_polyline(line_xy, 2, 1.0f, out_vertices, 16, &out_count);
        if (st != aether::core::Status::kOk) {
            std::fprintf(stderr,
                         "expand_polyline returned error for 2-point line\n");
            failed++;
        }
        if (out_count == 0) {
            std::fprintf(stderr,
                         "expand_polyline should produce vertices for 2-point line\n");
            failed++;
        }
    }

    // -- Test 7: expand_polyline with a 3-point L-shaped line. --
    {
        float line_xy[] = {0.0f, 0.0f, 5.0f, 0.0f, 5.0f, 5.0f};
        MapVertex out_vertices[32]{};
        std::size_t out_count = 0;

        auto st = expand_polyline(line_xy, 3, 0.5f, out_vertices, 32, &out_count);
        if (st != aether::core::Status::kOk) {
            std::fprintf(stderr,
                         "expand_polyline returned error for L-shaped line\n");
            failed++;
        }
        if (out_count == 0) {
            std::fprintf(stderr,
                         "expand_polyline should produce vertices for L-shaped line\n");
            failed++;
        }
    }

    // -- Test 8: expand_polyline with single point should handle gracefully. --
    {
        float line_xy[] = {3.0f, 4.0f};
        MapVertex out_vertices[4]{};
        std::size_t out_count = 0;

        auto st = expand_polyline(line_xy, 1, 1.0f, out_vertices, 4, &out_count);
        // Single point cannot form a line strip -- either error or zero output.
        if (st == aether::core::Status::kOk && out_count > 0) {
            // Acceptable: some implementations produce a degenerate strip.
        }
        // No crash is the main check.
    }

    // -- Test 9: mvt_decode_tile with null/empty data should not crash. --
    {
        MVTLayer layers[4]{};
        std::size_t count = 0;
        auto st = mvt_decode_tile(nullptr, 0, layers, 4, &count);
        // Should return an error or produce zero layers.
        if (st == aether::core::Status::kOk && count > 0) {
            std::fprintf(stderr,
                         "mvt_decode_tile with null data should not produce layers\n");
            failed++;
        }
    }

    return failed;
}
