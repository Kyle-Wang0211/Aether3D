// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/geo/map_terrain.h"

#include <cmath>
#include <cstdio>

int main() {
    int failed = 0;

    // --- Test 1: terrain_morph_factor ---
    {
        // At morph_start, factor should be 0
        float f0 = aether::geo::terrain_morph_factor(70.0f, 100.0f, 0.3f);
        if (f0 > 0.01f) {
            std::fprintf(stderr, "morph_factor at start: got %.3f, expected ~0\n",
                         static_cast<double>(f0));
            ++failed;
        }

        // At morph_end (lod_switch_distance), factor should be 1
        float f1 = aether::geo::terrain_morph_factor(100.0f, 100.0f, 0.3f);
        if (std::fabs(f1 - 1.0f) > 0.01f) {
            std::fprintf(stderr, "morph_factor at end: got %.3f, expected ~1\n",
                         static_cast<double>(f1));
            ++failed;
        }

        // Midpoint should be ~0.5 (smoothstep at t=0.5)
        float f_mid = aether::geo::terrain_morph_factor(85.0f, 100.0f, 0.3f);
        if (std::fabs(f_mid - 0.5f) > 0.15f) {
            std::fprintf(stderr, "morph_factor midpoint: got %.3f, expected ~0.5\n",
                         static_cast<double>(f_mid));
            ++failed;
        }
    }

    // --- Test 2: terrain_select_lod null output ---
    {
        aether::geo::TerrainConfig cfg;
        auto st = aether::geo::terrain_select_lod(50.0f, cfg, nullptr);
        if (st == aether::core::Status::kOk) {
            std::fprintf(stderr, "terrain_select_lod should fail with null output\n");
            ++failed;
        }
    }

    // --- Test 3: terrain_select_lod basic ---
    {
        aether::geo::TerrainConfig cfg;
        cfg.lod_levels = 8;
        uint32_t lod = 99;
        auto st = aether::geo::terrain_select_lod(50.0f, cfg, &lod);
        if (st != aether::core::Status::kOk) {
            std::fprintf(stderr, "terrain_select_lod failed\n");
            ++failed;
        }
        if (lod >= cfg.lod_levels) {
            std::fprintf(stderr, "terrain_select_lod out of range: %u\n", lod);
            ++failed;
        }
    }

    // --- Test 4: terrain_decode_rgb basic ---
    {
        // Single pixel: R=1, G=134, B=160 => h = -10000 + (1*65536 + 134*256 + 160)*0.1
        // = -10000 + (65536+34304+160)*0.1 = -10000 + 10000.0 = 0.0
        uint8_t rgb[3] = {1, 134, 160};
        float h = -999.0f;
        auto st = aether::geo::terrain_decode_rgb(rgb, 1, &h);
        if (st != aether::core::Status::kOk) {
            std::fprintf(stderr, "terrain_decode_rgb failed\n");
            ++failed;
        }
        if (std::fabs(h) > 0.5f) {
            std::fprintf(stderr, "terrain_decode_rgb: got %.3f, expected ~0\n", static_cast<double>(h));
            ++failed;
        }
    }

    return failed;
}
