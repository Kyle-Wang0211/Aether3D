// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// Plan G W1 D3 D1: Tile layout for DA3-LARGE-1.1 tile-based depth inference.
//
// DA3-LARGE-1.1 (DinoV2-Large backbone) requires 518×518 input (= 14 patches
// of 37). For 2K capture (1920×1080) we tile-and-blend: 4×3 = 12 tiles of
// 518×518 with 32-px overlap, last tile in each row/col pinned to image edge.
//
// Cross-platform: pure header, no platform deps. Used by Swift (iOS),
// JNI (Android), WASM (Web), Dart FFI (Flutter).
//
// Ported from Tile2KWrapper.swift `makeLayout` — bit-for-bit equivalent
// per W2 D1 parity test harness.

#ifndef AETHER_PIPELINE_TILE_LAYOUT_H
#define AETHER_PIPELINE_TILE_LAYOUT_H

#ifdef __cplusplus

#include <cstdint>
#include <vector>

namespace aether {
namespace pipeline {

/// A single tile's position + size in source image coordinates.
/// 1D index of (row, col) in TileLayout::tiles is `row * nx + col`.
struct TileRect {
    std::int32_t x{0};       ///< Top-left x in image coords (>= 0).
    std::int32_t y{0};       ///< Top-left y in image coords (>= 0).
    std::int32_t width{0};   ///< Tile width in pixels (= TileLayout::tile_size).
    std::int32_t height{0};  ///< Tile height in pixels.
    std::int32_t row{0};     ///< Row index in tile grid (0 = top row).
    std::int32_t col{0};     ///< Column index in tile grid (0 = leftmost).
};

/// Full layout description for tile splitting + blending.
struct TileLayout {
    std::int32_t tile_size{518};
    std::int32_t overlap{32};
    std::int32_t stride{486};         ///< tile_size - overlap (cached).
    std::int32_t image_width{0};
    std::int32_t image_height{0};
    std::int32_t nx{0};               ///< tiles per row.
    std::int32_t ny{0};               ///< rows of tiles.
    std::vector<TileRect> tiles;      ///< Row-major: tile[row*nx + col].
};

/// Compute tile layout for an image of `image_width × image_height`.
///
/// Behavior matches Tile2KWrapper.makeLayout (Swift):
///   - nx = (image_width == tile_size) ? 1 : ceil((image_width - tile_size) / stride) + 1
///   - ny same for height
///   - Last tile in each row/col pinned to image edge (last_x = image_width - tile_size).
///     This may give it slightly more overlap with its neighbor — preferred over
///     leaving an uncovered strip.
///   - tile_size > overlap and image dims >= tile_size are caller's responsibility
///     (caller-side preconditions; this function returns empty layout on violation).
///
/// Plan G defaults: tile_size = 518 (DA3-LARGE-1.1 fixed), overlap = 32 (W1 D3 D3 locked).
TileLayout make_tile_layout(
    std::int32_t image_width,
    std::int32_t image_height,
    std::int32_t tile_size = 518,
    std::int32_t overlap = 32) noexcept;

/// Bilinear edge-fade weight for a single tile pixel (lx, ly) in [0, tile_size).
///
/// Returns the per-pixel weight contribution from the tile's edge fade (not
/// including conf weight). Used by tile_blend.
///
/// Method B (sin² trapezoid): smooth fade-out in the `overlap` border ring,
///   flat 1.0 in tile interior.
/// Method A (floor 0.05): ensures image-perimeter pixels (covered by only one
///   tile, at that tile's outer edge) still get non-zero weight. Without the
///   floor, ~0.29% of pixels (image corners) would have weight 0 and be
///   dropped by the blender.
///
/// Pure inline for hot loop (called tile_size² × n_tiles times per frame).
inline float tile_edge_weight(
    std::int32_t lx, std::int32_t ly,
    std::int32_t tile_size, std::int32_t overlap,
    float floor_value = 0.05f) noexcept {
    // Distance from nearest edge (lx=0, lx=tile_size-1, ly=0, ly=tile_size-1).
    const std::int32_t dx = (lx < (tile_size - 1 - lx)) ? lx : (tile_size - 1 - lx);
    const std::int32_t dy = (ly < (tile_size - 1 - ly)) ? ly : (tile_size - 1 - ly);
    const float inv_overlap = 1.0f / static_cast<float>(overlap);

    float fade_x = 1.0f;
    if (dx < overlap) {
        const float t = static_cast<float>(dx) * inv_overlap;
        // sin(π/2 * t)² — matches Swift `let s = sin(.pi / 2 * t); edgeFade = s * s`.
        const float s = __builtin_sinf(1.5707963267948966f * t);
        fade_x = s * s;
    }
    float fade_y = 1.0f;
    if (dy < overlap) {
        const float t = static_cast<float>(dy) * inv_overlap;
        const float s = __builtin_sinf(1.5707963267948966f * t);
        fade_y = s * s;
    }
    const float w = fade_x * fade_y;
    return (w > floor_value) ? w : floor_value;
}

/// Confidence weight from DA3 conf head value.
///
/// DA3-LARGE-1.1 depth_conf head outputs values typically in [1.0, ~7.5] (W1 D3 D4
/// empirical range; theoretical bound is exp(softplus)+1). We shift to [0, 6.5],
/// floor at 0.01 (so even uncertain pixels contribute SOMEthing), cap at 1.0
/// (so single-tile coverage doesn't over-weight a tile's center).
///
/// Pure inline for hot loop.
inline float tile_conf_weight(float conf_raw,
                              float floor_value = 0.01f,
                              float cap_value = 1.0f) noexcept {
    const float shifted = conf_raw - 1.0f;
    const float clamped_low = (shifted < floor_value) ? floor_value : shifted;
    return (clamped_low > cap_value) ? cap_value : clamped_low;
}

}  // namespace pipeline
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_PIPELINE_TILE_LAYOUT_H
