// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/geo/map_tile_source.h"
#include "aether/core/status.h"

#include <cstdio>

int main() {
    int failed = 0;

    // Test 1: Create/destroy with null path (offline safe)
    {
        auto* src = aether::geo::map_tile_source_create(nullptr);
        if (!src) { std::fprintf(stderr, "create null path failed\n"); ++failed; }
        else { aether::geo::map_tile_source_destroy(src); }
    }

    // Test 2: Create with empty path
    {
        auto* src = aether::geo::map_tile_source_create("");
        if (!src) { std::fprintf(stderr, "create empty path failed\n"); ++failed; }
        else { aether::geo::map_tile_source_destroy(src); }
    }

    // Test 3: Get tile from synthetic source
    {
        auto* src = aether::geo::map_tile_source_create("synthetic");
        aether::geo::TileCoord coord{10, 512, 340};
        aether::geo::TileData tile{};
        auto s = aether::geo::map_tile_source_get(src, coord, &tile);
        if (s != aether::core::Status::kOk) {
            std::fprintf(stderr, "get tile failed\n"); ++failed;
        }
        if (tile.data == nullptr || tile.size == 0) {
            std::fprintf(stderr, "tile data empty\n"); ++failed;
        }
        // Second get should be a cache hit
        aether::geo::TileData tile2{};
        aether::geo::map_tile_source_get(src, coord, &tile2);
        auto stats = aether::geo::map_tile_source_cache_stats(src);
        if (stats.hits < 1) {
            std::fprintf(stderr, "expected cache hit, got %llu hits\n",
                         (unsigned long long)stats.hits);
            ++failed;
        }
        aether::geo::map_tile_source_destroy(src);
    }

    // Test 4: Has tile
    {
        auto* src = aether::geo::map_tile_source_create("synthetic");
        if (!aether::geo::map_tile_source_has(src, {10, 0, 0})) {
            std::fprintf(stderr, "has tile z=10 returned false\n"); ++failed;
        }
        if (aether::geo::map_tile_source_has(src, {20, 0, 0})) {
            std::fprintf(stderr, "has tile z=20 returned true (max=14)\n"); ++failed;
        }
        aether::geo::map_tile_source_destroy(src);
    }

    // Test 5: Metadata
    {
        auto* src = aether::geo::map_tile_source_create("synthetic");
        std::uint32_t min_z = 99, max_z = 99;
        auto s = aether::geo::map_tile_source_meta(src, &min_z, &max_z);
        if (s != aether::core::Status::kOk) {
            std::fprintf(stderr, "meta failed\n"); ++failed;
        }
        if (min_z != 0 || max_z != 14) {
            std::fprintf(stderr, "meta: min=%u max=%u expected 0/14\n", min_z, max_z);
            ++failed;
        }
        aether::geo::map_tile_source_destroy(src);
    }

    // Test 6: Out of range tile
    {
        auto* src = aether::geo::map_tile_source_create("synthetic");
        aether::geo::TileCoord coord{15, 0, 0};  // Beyond max zoom
        aether::geo::TileData tile{};
        auto s = aether::geo::map_tile_source_get(src, coord, &tile);
        if (s != aether::core::Status::kOutOfRange) {
            std::fprintf(stderr, "z=15: expected kOutOfRange\n"); ++failed;
        }
        aether::geo::map_tile_source_destroy(src);
    }

    return failed;
}
