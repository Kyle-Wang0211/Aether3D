// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/render/fracture_display_mesh.h"
#include "aether/innovation/core_types.h"

#include <cmath>
#include <cstdio>
#include <vector>

int main() {
    int failed = 0;
    using namespace aether::render;
    using namespace aether::innovation;

    // -- Test 1: compute_visual_params returns valid parameters. --
    {
        FragmentVisualParams params = compute_visual_params(
            0.5f,   // display
            1.0f,   // depth
            0.01f,  // triangle_area
            0.01f   // median_area
        );

        if (params.fill_opacity < 0.0f || params.fill_opacity > 1.0f) {
            std::fprintf(stderr,
                         "fill_opacity out of [0,1]: %f\n", params.fill_opacity);
            failed++;
        }
        if (params.border_alpha < 0.0f || params.border_alpha > 1.0f) {
            std::fprintf(stderr,
                         "border_alpha out of [0,1]: %f\n", params.border_alpha);
            failed++;
        }
        if (params.metallic < 0.0f || params.metallic > 1.0f) {
            std::fprintf(stderr,
                         "metallic out of [0,1]: %f\n", params.metallic);
            failed++;
        }
        if (params.roughness < 0.0f || params.roughness > 1.0f) {
            std::fprintf(stderr,
                         "roughness out of [0,1]: %f\n", params.roughness);
            failed++;
        }
    }

    // -- Test 2: compute_visual_params with zero display. --
    {
        FragmentVisualParams params = compute_visual_params(
            0.0f,   // display = 0 (S0: black fill should be strongly visible)
            2.0f,
            0.005f,
            0.01f
        );
        // At zero display, opacity should be high.
        if (params.fill_opacity < 0.5f) {
            std::fprintf(stderr,
                         "fill_opacity should be high for display=0, got %f\n",
                         params.fill_opacity);
            failed++;
        }
    }

    // -- Test 3: compute_visual_params with full display. --
    {
        FragmentVisualParams params = compute_visual_params(
            1.0f,   // display = 1 (high-quality, fill should fade out)
            0.5f,
            0.02f,
            0.01f
        );
        // At full display, opacity should be low.
        if (params.fill_opacity > 0.5f) {
            std::fprintf(stderr,
                         "fill_opacity should be low for display=1, got %f\n",
                         params.fill_opacity);
            failed++;
        }
    }

    // -- Test 4: voronoi_subdivide_triangle produces at least one fragment. --
    {
        Float3 a = make_float3(0.0f, 0.0f, 0.0f);
        Float3 b = make_float3(1.0f, 0.0f, 0.0f);
        Float3 c = make_float3(0.0f, 1.0f, 0.0f);

        DisplayFragment fragments[8]{};
        std::uint8_t count = 0;
        voronoi_subdivide_triangle(a, b, c, 12345ULL, 0.05f,
                                   3, 8, 0.1f,  // min/max fragments, inner jitter
                                   fragments, &count);

        if (count == 0) {
            std::fprintf(stderr,
                         "voronoi_subdivide_triangle should produce at least 1 fragment\n");
            failed++;
        }
    }

    // -- Test 5: voronoi_subdivide_triangle with zero gap. --
    {
        Float3 a = make_float3(0.0f, 0.0f, 0.0f);
        Float3 b = make_float3(2.0f, 0.0f, 0.0f);
        Float3 c = make_float3(1.0f, 2.0f, 0.0f);

        DisplayFragment fragments[8]{};
        std::uint8_t count = 0;
        voronoi_subdivide_triangle(a, b, c, 99ULL, 0.0f,
                                   3, 8, 0.1f,  // min/max fragments, inner jitter
                                   fragments, &count);

        if (count == 0) {
            std::fprintf(stderr,
                         "voronoi_subdivide_triangle with gap=0 should still produce fragments\n");
            failed++;
        }
    }

    // -- Test 6: generate_fracture_fragments with a single triangle. --
    {
        ScaffoldVertex vertices[3]{};
        vertices[0].id = 0;
        vertices[0].position = make_float3(0.0f, 0.0f, 0.0f);
        vertices[1].id = 1;
        vertices[1].position = make_float3(1.0f, 0.0f, 0.0f);
        vertices[2].id = 2;
        vertices[2].position = make_float3(0.0f, 1.0f, 0.0f);

        ScaffoldUnit unit{};
        unit.unit_id = 1;
        unit.v0 = 0;
        unit.v1 = 1;
        unit.v2 = 2;
        unit.area = 0.5f;

        float per_unit_display = 0.8f;
        float per_unit_depth = 1.0f;

        std::vector<DisplayFragment> out_fragments;
        auto st = generate_fracture_fragments(
            &unit, 1,
            vertices, 3,
            &per_unit_display,
            &per_unit_depth,
            &out_fragments);

        if (st != aether::core::Status::kOk) {
            std::fprintf(stderr,
                         "generate_fracture_fragments returned error\n");
            failed++;
        }
        if (out_fragments.empty()) {
            std::fprintf(stderr,
                         "generate_fracture_fragments should produce at least one fragment\n");
            failed++;
        }
    }

    // -- Test 7: generate_fracture_fragments with zero units is ok. --
    {
        std::vector<DisplayFragment> out_fragments;
        auto st = generate_fracture_fragments(
            nullptr, 0,
            nullptr, 0,
            nullptr,
            nullptr,
            &out_fragments);

        if (st != aether::core::Status::kOk) {
            std::fprintf(stderr,
                         "generate_fracture_fragments with 0 units should be ok\n");
            failed++;
        }
        if (!out_fragments.empty()) {
            std::fprintf(stderr,
                         "generate_fracture_fragments with 0 units should produce no fragments\n");
            failed++;
        }
    }

    // -- Test 8: piecewise gray mapping regression at key display values. --
    {
        // S0 (d=0.0): gray should be 0
        FragmentVisualParams p0 = compute_visual_params(0.0f, 1.0f, 0.01f, 0.01f);
        if (p0.fill_gray > 0.01f) {
            std::fprintf(stderr,
                         "fill_gray at display=0 should be ~0, got %f\n", p0.fill_gray);
            failed++;
        }

        // S1 (d=0.10): gray_pre should be ~0.20 → RGB ~51
        FragmentVisualParams p1 = compute_visual_params(0.10f, 1.0f, 0.01f, 0.01f);
        if (p1.fill_gray < 0.15f || p1.fill_gray > 0.30f) {
            std::fprintf(stderr,
                         "fill_gray at display=0.10 should be ~0.20, got %f\n", p1.fill_gray);
            failed++;
        }

        // S2 (d=0.25): gray_pre should be ~0.50 → RGB ~128
        FragmentVisualParams p2 = compute_visual_params(0.25f, 1.0f, 0.01f, 0.01f);
        if (p2.fill_gray < 0.40f || p2.fill_gray > 0.60f) {
            std::fprintf(stderr,
                         "fill_gray at display=0.25 should be ~0.50, got %f\n", p2.fill_gray);
            failed++;
        }

        // S3 (d=0.50): gray_pre should be ~0.65 → RGB ~166
        FragmentVisualParams p3 = compute_visual_params(0.50f, 1.0f, 0.01f, 0.01f);
        if (p3.fill_gray < 0.55f || p3.fill_gray > 0.75f) {
            std::fprintf(stderr,
                         "fill_gray at display=0.50 should be ~0.65, got %f\n", p3.fill_gray);
            failed++;
        }

        // S4 (d=0.75): gray_pre should be ~0.784 → RGB ~200
        // (s4 smoothstep starts at 0.75 so fill_gray ≈ gray_pre here)
        FragmentVisualParams p4 = compute_visual_params(0.75f, 1.0f, 0.01f, 0.01f);
        if (p4.fill_gray < 0.70f || p4.fill_gray > 0.90f) {
            std::fprintf(stderr,
                         "fill_gray at display=0.75 should be ~0.78, got %f\n", p4.fill_gray);
            failed++;
        }

        // S5 (d=1.0): fill_gray should be ~1.0 (s4 blends to white)
        FragmentVisualParams p5 = compute_visual_params(1.0f, 1.0f, 0.01f, 0.01f);
        if (p5.fill_gray < 0.90f) {
            std::fprintf(stderr,
                         "fill_gray at display=1.0 should be ~1.0, got %f\n", p5.fill_gray);
            failed++;
        }

        // Monotonicity: gray should increase with display
        if (!(p0.fill_gray <= p1.fill_gray &&
              p1.fill_gray <= p2.fill_gray &&
              p2.fill_gray <= p3.fill_gray &&
              p3.fill_gray <= p4.fill_gray &&
              p4.fill_gray <= p5.fill_gray)) {
            std::fprintf(stderr,
                         "fill_gray is not monotonically increasing: "
                         "%f %f %f %f %f %f\n",
                         p0.fill_gray, p1.fill_gray, p2.fill_gray,
                         p3.fill_gray, p4.fill_gray, p5.fill_gray);
            failed++;
        }
    }

    return failed;
}
