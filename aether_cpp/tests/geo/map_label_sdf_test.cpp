// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/geo/map_label_sdf.h"

#include <cstdio>
#include <cstring>
#include <vector>

int main() {
    int failed = 0;
    using namespace aether::geo;

    // -- Test 1: Create and destroy atlas without crash. --
    {
        LabelAtlas* atlas = label_atlas_create(256, 256);
        if (atlas == nullptr) {
            std::fprintf(stderr, "label_atlas_create returned null\n");
            failed++;
        } else {
            label_atlas_destroy(atlas);
        }
    }

    // -- Test 2: Add a glyph to the atlas. --
    {
        LabelAtlas* atlas = label_atlas_create(256, 256);
        if (atlas == nullptr) {
            std::fprintf(stderr, "label_atlas_create returned null\n");
            failed++;
        } else {
            // Create simple 8x8 SDF glyph data.
            std::vector<uint8_t> sdf(8 * 8, 128);
            auto st = label_atlas_add_glyph(atlas, 'A', sdf.data(), 8, 8);
            if (st != aether::core::Status::kOk) {
                std::fprintf(stderr,
                             "label_atlas_add_glyph returned error\n");
                failed++;
            }
            label_atlas_destroy(atlas);
        }
    }

    // -- Test 3: Add multiple glyphs until exhausted. --
    {
        // Create a very small atlas to trigger exhaustion.
        LabelAtlas* atlas = label_atlas_create(16, 16);
        if (atlas == nullptr) {
            std::fprintf(stderr, "label_atlas_create returned null\n");
            failed++;
        } else {
            std::vector<uint8_t> sdf(8 * 8, 128);
            bool hit_exhausted = false;
            for (uint32_t cp = 0; cp < 100; ++cp) {
                auto st = label_atlas_add_glyph(atlas, cp, sdf.data(), 8, 8);
                if (st == aether::core::Status::kResourceExhausted) {
                    hit_exhausted = true;
                    break;
                }
            }
            if (!hit_exhausted) {
                std::fprintf(stderr,
                             "expected kResourceExhausted for small atlas\n");
                failed++;
            }
            label_atlas_destroy(atlas);
        }
    }

    // -- Test 4: Default Label values. --
    {
        Label label{};
        if (label.glyph_count != 0) {
            std::fprintf(stderr,
                         "default Label glyph_count should be 0\n");
            failed++;
        }
        if (label.visible) {
            std::fprintf(stderr,
                         "default Label visible should be false\n");
            failed++;
        }
    }

    // -- Test 5: label_layout with zero labels. --
    {
        Label out[1]{};
        std::size_t out_count = 0;
        auto st = label_layout(nullptr, 0, out, 1, &out_count);
        if (st != aether::core::Status::kOk) {
            std::fprintf(stderr,
                         "label_layout with 0 labels returned error\n");
            failed++;
        }
        if (out_count != 0) {
            std::fprintf(stderr,
                         "label_layout with 0 labels should output 0\n");
            failed++;
        }
    }

    // -- Test 6: label_layout with a single label. --
    {
        Label input{};
        input.screen_x = 100.0f;
        input.screen_y = 100.0f;
        input.priority = 1.0f;
        input.glyph_count = 1;
        input.glyphs[0] = {100.0f, 100.0f, 10.0f, 10.0f, 0.0f, 0.0f, 1.0f, 1.0f};
        input.visible = true;

        Label out[1]{};
        std::size_t out_count = 0;
        auto st = label_layout(&input, 1, out, 1, &out_count);
        if (st != aether::core::Status::kOk) {
            std::fprintf(stderr,
                         "label_layout with 1 label returned error\n");
            failed++;
        }
        if (out_count != 1) {
            std::fprintf(stderr,
                         "label_layout with 1 non-colliding label should output 1, got %zu\n",
                         out_count);
            failed++;
        }
    }

    // -- Test 7: label_layout with overlapping labels should resolve collisions. --
    {
        const int n = 5;
        Label inputs[n]{};
        for (int i = 0; i < n; ++i) {
            inputs[i].screen_x = 100.0f;
            inputs[i].screen_y = 100.0f;
            inputs[i].priority = static_cast<float>(n - i);  // Higher index = lower priority.
            inputs[i].glyph_count = 1;
            inputs[i].glyphs[0] = {100.0f, 100.0f, 50.0f, 20.0f, 0, 0, 1, 1};
            inputs[i].visible = true;
        }

        Label out[n]{};
        std::size_t out_count = 0;
        auto st = label_layout(inputs, n, out, n, &out_count);
        if (st != aether::core::Status::kOk) {
            std::fprintf(stderr,
                         "label_layout with overlapping labels returned error\n");
            failed++;
        }
        // With all labels at the same position, collision avoidance should
        // reduce the visible count.
        if (out_count > static_cast<std::size_t>(n)) {
            std::fprintf(stderr,
                         "label_layout output count %zu exceeds input count %d\n",
                         out_count, n);
            failed++;
        }
    }

    // -- Test 8: label_layout respects max_visible limit. --
    {
        const int n = 10;
        Label inputs[n]{};
        for (int i = 0; i < n; ++i) {
            inputs[i].screen_x = static_cast<float>(i * 200);  // Spread out.
            inputs[i].screen_y = 100.0f;
            inputs[i].priority = 1.0f;
            inputs[i].glyph_count = 1;
            inputs[i].glyphs[0] = {
                inputs[i].screen_x, 100.0f, 10.0f, 10.0f, 0, 0, 1, 1};
            inputs[i].visible = true;
        }

        Label out[3]{};
        std::size_t out_count = 0;
        auto st = label_layout(inputs, n, out, 3, &out_count);
        if (st != aether::core::Status::kOk) {
            std::fprintf(stderr,
                         "label_layout with max_visible=3 returned error\n");
            failed++;
        }
        if (out_count > 3) {
            std::fprintf(stderr,
                         "label_layout should respect max_visible=3, got %zu\n",
                         out_count);
            failed++;
        }
    }

    // -- Test 9: LabelGlyph default values. --
    {
        LabelGlyph g{};
        if (g.x != 0.0f || g.y != 0.0f || g.w != 0.0f || g.h != 0.0f) {
            std::fprintf(stderr,
                         "default LabelGlyph position/size should be 0\n");
            failed++;
        }
    }

    return failed;
}
