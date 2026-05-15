// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// Plan G W1 D3 D3: Tile blend for DA3-LARGE-1.1 multi-tile depth output.
//
// Blends N per-tile depth + conf maps (518×518 each) back into a full-frame
// depth + weight map (e.g. 1920×1080 for 2K capture). Weight formula:
//   w = conf_weight × edge_weight
//   conf_weight = clamp(conf - 1.0, 0.01, 1.0)   (Plan G W1 D3 D3 lock)
//   edge_weight = max(0.05, sin²(π/2·tx) · sin²(π/2·ty))  (Method A floor + B trapezoid)
//
// Method A floor 0.05 — fixes coverage 99.71% → 100% (W1 D3 D4 finding).
// Image-perimeter pixels are covered by only one tile at that tile's outer
// edge, where Method B alone gives weight 0 → blender skips them. The floor
// ensures every covered pixel contributes.
//
// Cross-platform: pure header API, .cpp impl. Ported from
// Tile2KWrapper.blendTiles — bit-for-bit equivalent.

#ifndef AETHER_PIPELINE_TILE_BLEND_H
#define AETHER_PIPELINE_TILE_BLEND_H

#ifdef __cplusplus

#include <cstdint>
#include <vector>

#include "aether/pipeline/tile_layout.h"

namespace aether {
namespace pipeline {

/// One tile's inference output. depth and conf are tile_size² floats each.
/// Owning vectors — convenience for synthesized tiles and tests. The hot path
/// uses TileView (non-owning) to avoid memcpy on the FFI boundary.
struct TileInference {
    TileRect tile;                       ///< Tile position (from TileLayout).
    std::vector<float> depth;            ///< tile_size × tile_size, row-major.
    std::vector<float> conf;             ///< tile_size × tile_size, row-major.
    double inference_time_ms{0.0};       ///< For diagnostics.
};

/// Non-owning per-tile view. The hot-path API (blend_tiles_view + C ABI)
/// takes these so the caller's depth/conf buffers are read directly with no
/// memcpy across the FFI boundary. Caller guarantees the buffers stay live
/// for the duration of the blend call.
struct TileView {
    TileRect tile;                       ///< Tile position (from TileLayout).
    const float* depth{nullptr};         ///< tile_size² floats, row-major.
    const float* conf{nullptr};          ///< tile_size² floats, row-major.
};

/// Per-frame blend stats (no full-image buffers — caller owns those).
struct BlendStats {
    std::int32_t covered_pixel_count{0}; ///< Pixels with weight > 0 (should = W*H).
    float coverage{0.0f};                ///< covered / (W*H).
    float min_depth{0.0f};
    float max_depth{0.0f};
    float mean_depth{0.0f};
    double blend_time_ms{0.0};
};

/// Full-frame blended depth output (owning convenience wrapper around
/// blend_tiles_view).
struct BlendResult {
    std::vector<float> depth;            ///< image_width × image_height, row-major.
    std::vector<float> weight;           ///< Per-pixel accumulated weight (pre-normalize).
    std::int32_t width{0};
    std::int32_t height{0};
    float coverage{0.0f};                ///< Fraction with weight > 0. Should be 1.0.
    double blend_time_ms{0.0};
    float min_depth{0.0f};
    float max_depth{0.0f};
    float mean_depth{0.0f};
};

/// Blend tiles into full-frame depth map.
///
/// Caller invariants:
///   - tiles.size() should == layout.tiles.size() (skip-missing semantics if not).
///   - Each tile's depth + conf has tile_size² floats.
///   - layout was computed by make_tile_layout (same image dims).
///
/// Algorithm:
///   for each pixel (gx, gy) in image:
///     accumulate from each covering tile t:
///       conf_w = clamp(conf_t[lx,ly] - 1.0, 0.01, 1.0)
///       edge_w = max(0.05, sin²(π/2·min(dx,overlap)/overlap) · same_y)
///       w = conf_w × edge_w
///       depth_out[gx,gy] += depth_t[lx,ly] × w
///       weight_out[gx,gy] += w
///     depth_out[gx,gy] /= weight_out[gx,gy]   (if weight > 0)
///
/// Method A floor (edge_w >= 0.05) ensures image corners with weight > 0.
/// Method B trapezoid (sin² ramp) gives smooth seams in overlap regions.
///
/// Performance: hot loop, ~12 tiles × 518² pixels × 1080×1920 image bounds ≈ 3M
/// operations per frame. Measured ~16ms on iPhone 14 Pro (W1 D3 D4).
BlendResult blend_tiles(
    const std::vector<TileInference>& tiles,
    const TileLayout& layout,
    float edge_floor = 0.05f,
    float conf_floor = 0.01f,
    float conf_cap = 1.0f) noexcept;

/// Hot-path: blend non-owning tile views into caller-allocated depth + weight
/// maps. No vector allocation, no per-tile memcpy. Used by the C ABI
/// (aether_blend_tiles) to skip FFI marshaling overhead.
///
/// @param tiles            N tile views. Caller guarantees views are live.
/// @param n_tiles          Number of tiles.
/// @param layout           Tile layout (image_width/height, tile_size, overlap).
/// @param edge_floor       Method A floor (Plan G locked 0.05).
/// @param conf_floor       Conf weight floor (Plan G locked 0.01).
/// @param conf_cap         Conf weight cap (Plan G locked 1.0).
/// @param out_depth        OUT: image_width × image_height floats. Caller alloc.
/// @param out_weight       OUT: image_width × image_height floats. Caller alloc.
/// @param out_stats        OUT: blend stats (coverage, min/max/mean, timing).
void blend_tiles_view(
    const TileView* tiles, std::int32_t n_tiles,
    const TileLayout& layout,
    float edge_floor, float conf_floor, float conf_cap,
    float* out_depth, float* out_weight,
    BlendStats& out_stats) noexcept;

}  // namespace pipeline
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_PIPELINE_TILE_BLEND_H
