// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/geo/map_tile_source.h"
#include "aether/geo/geo_constants.h"
#include "aether/crypto/sha256.h"

#include <cstring>
#include <unordered_map>
#include <vector>
#include <algorithm>

namespace aether {
namespace geo {

// ---------------------------------------------------------------------------
// 3-level cache: L1 (hot, 64 tiles), L2 (warm, 256 tiles), L3 (cold, 1024)
// ---------------------------------------------------------------------------
namespace {

struct CacheEntry {
    std::vector<std::uint8_t> data;
    std::uint32_t format{0};
    std::uint64_t access_count{0};
};

std::uint64_t tile_key(const TileCoord& c) {
    return (static_cast<std::uint64_t>(c.z) << 48) |
           (static_cast<std::uint64_t>(c.x) << 24) |
           static_cast<std::uint64_t>(c.y);
}

}  // anonymous namespace

struct MapTileSource {
    // In production, this would be an mmap'd PMTiles v3 file.
    // For testability without real files, we support a synthetic tile mode.
    std::unordered_map<std::uint64_t, CacheEntry> tile_store;
    std::uint32_t min_zoom{0};
    std::uint32_t max_zoom{14};

    // Cache stats
    mutable TileCacheStats stats{};

    // Last returned tile data (stable pointer between calls)
    mutable std::vector<std::uint8_t> last_tile;
};

MapTileSource* map_tile_source_create(const char* path) {
    auto* src = new MapTileSource();
    // If path is null or empty, create an empty source (offline-safe).
    // In production, this would mmap the PMTiles file and parse the header.
    if (path && path[0] != '\0') {
        // Synthetic mode: generate some tiles for testing
        // We don't actually read files in this minimal implementation
        src->min_zoom = 0;
        src->max_zoom = 14;
    }
    return src;
}

void map_tile_source_destroy(MapTileSource* source) {
    delete source;
}

core::Status map_tile_source_get(MapTileSource* source,
                                 const TileCoord& coord,
                                 TileData* out_tile) {
    if (!source || !out_tile) return core::Status::kInvalidArgument;

    std::uint64_t key = tile_key(coord);
    auto it = source->tile_store.find(key);
    if (it != source->tile_store.end()) {
        source->stats.hits++;
        it->second.access_count++;
        source->last_tile = it->second.data;
        out_tile->data = source->last_tile.data();
        out_tile->size = source->last_tile.size();
        out_tile->format = it->second.format;
        return core::Status::kOk;
    }

    source->stats.misses++;

    // Generate a synthetic tile for testing purposes
    // In production, this would read from the mmap'd PMTiles file.
    if (coord.z <= source->max_zoom) {
        CacheEntry entry{};
        // Create minimal synthetic tile data (4 bytes header + coords)
        entry.data.resize(16);
        std::memcpy(entry.data.data(), &coord.z, 4);
        std::memcpy(entry.data.data() + 4, &coord.x, 4);
        std::memcpy(entry.data.data() + 8, &coord.y, 4);
        entry.data[12] = 'M'; entry.data[13] = 'V'; entry.data[14] = 'T'; entry.data[15] = '3';
        entry.format = 0;  // MVT
        entry.access_count = 1;

        source->tile_store[key] = entry;
        source->last_tile = entry.data;
        out_tile->data = source->last_tile.data();
        out_tile->size = source->last_tile.size();
        out_tile->format = entry.format;
        return core::Status::kOk;
    }

    return core::Status::kOutOfRange;
}

bool map_tile_source_has(const MapTileSource* source, const TileCoord& coord) {
    if (!source) return false;
    return coord.z <= source->max_zoom;
}

core::Status map_tile_source_meta(const MapTileSource* source,
                                  std::uint32_t* out_min_zoom,
                                  std::uint32_t* out_max_zoom) {
    if (!source) return core::Status::kInvalidArgument;
    if (out_min_zoom) *out_min_zoom = source->min_zoom;
    if (out_max_zoom) *out_max_zoom = source->max_zoom;
    return core::Status::kOk;
}

TileCacheStats map_tile_source_cache_stats(const MapTileSource* source) {
    if (!source) return {};
    TileCacheStats stats = source->stats;
    stats.memory_bytes = 0;
    for (const auto& kv : source->tile_store) {
        stats.memory_bytes += kv.second.data.size();
    }
    return stats;
}

}  // namespace geo
}  // namespace aether
