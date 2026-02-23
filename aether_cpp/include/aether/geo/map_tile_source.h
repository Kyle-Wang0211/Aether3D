// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_GEO_MAP_TILE_SOURCE_H
#define AETHER_GEO_MAP_TILE_SOURCE_H

#include "aether/core/status.h"

#include <cstddef>
#include <cstdint>

namespace aether {
namespace geo {

/// Tile coordinate (z/x/y slippy map scheme).
struct TileCoord {
    std::uint32_t z{0};
    std::uint32_t x{0};
    std::uint32_t y{0};
};

/// Tile data blob.
struct TileData {
    const std::uint8_t* data{nullptr};
    std::size_t size{0};
    std::uint32_t format{0};   // 0=MVT, 1=PNG, 2=JPEG, 3=WebP
};

/// Opaque PMTiles reader handle.
struct MapTileSource;

/// Create a tile source from an mmap'd PMTiles v3 file.
/// path: filesystem path.  For offline-first, the file must exist locally.
MapTileSource* map_tile_source_create(const char* path);
void map_tile_source_destroy(MapTileSource* source);

/// Get a tile.  Returns kOk on success, kOutOfRange if tile not found.
/// The returned TileData pointers are valid until the next call or destruction.
core::Status map_tile_source_get(MapTileSource* source,
                                 const TileCoord& coord,
                                 TileData* out_tile);

/// Check if a specific tile exists without loading it.
bool map_tile_source_has(const MapTileSource* source, const TileCoord& coord);

/// Get metadata (min/max zoom).
core::Status map_tile_source_meta(const MapTileSource* source,
                                  std::uint32_t* out_min_zoom,
                                  std::uint32_t* out_max_zoom);

/// Cache statistics.
struct TileCacheStats {
    std::uint64_t hits{0};
    std::uint64_t misses{0};
    std::uint64_t evictions{0};
    std::size_t memory_bytes{0};
};

TileCacheStats map_tile_source_cache_stats(const MapTileSource* source);

}  // namespace geo
}  // namespace aether

#endif  // AETHER_GEO_MAP_TILE_SOURCE_H
