// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/pipeline/tile_blend.h"

#include <cmath>
#include <chrono>
#include <cstring>
#include <limits>

namespace aether {
namespace pipeline {

void blend_tiles_view(
    const TileView* tiles, std::int32_t n_tiles,
    const TileLayout& layout,
    float edge_floor, float conf_floor, float conf_cap,
    float* out_depth, float* out_weight,
    BlendStats& out_stats) noexcept {

    const std::int32_t W = layout.image_width;
    const std::int32_t H = layout.image_height;
    const std::int32_t tile_size = layout.tile_size;
    const std::int32_t overlap = layout.overlap;
    const float inv_overlap = 1.0f / static_cast<float>(overlap);
    constexpr float kHalfPi = 1.5707963267948966f;

    out_stats = BlendStats{};

    // Guard: degenerate layout / null buffers → leave stats zeroed.
    if (W <= 0 || H <= 0 || tile_size <= 0
        || out_depth == nullptr || out_weight == nullptr
        || tiles == nullptr || n_tiles <= 0) {
        return;
    }

    const std::size_t total_pixels =
        static_cast<std::size_t>(W) * static_cast<std::size_t>(H);
    std::memset(out_depth, 0, total_pixels * sizeof(float));
    std::memset(out_weight, 0, total_pixels * sizeof(float));

    const auto t_start = std::chrono::steady_clock::now();

    for (std::int32_t ti = 0; ti < n_tiles; ++ti) {
        const TileView& v = tiles[ti];
        if (v.depth == nullptr || v.conf == nullptr) continue;

        const TileRect& tile = v.tile;
        const float* depth_tile = v.depth;
        const float* conf_tile = v.conf;
        const std::int32_t tile_x = tile.x;
        const std::int32_t tile_y = tile.y;

        for (std::int32_t ly = 0; ly < tile_size; ++ly) {
            const std::int32_t gy = tile_y + ly;
            if (gy < 0 || gy >= H) continue;
            const std::size_t row_global = static_cast<std::size_t>(gy) * W;
            const std::size_t row_tile = static_cast<std::size_t>(ly) * tile_size;

            // Edge fade in y direction.
            const std::int32_t edge_dist_y =
                (ly < tile_size - 1 - ly) ? ly : (tile_size - 1 - ly);
            float fade_y;
            if (edge_dist_y >= overlap) {
                fade_y = 1.0f;
            } else {
                const float t = static_cast<float>(edge_dist_y) * inv_overlap;
                const float s = std::sin(kHalfPi * t);
                fade_y = s * s;
            }

            for (std::int32_t lx = 0; lx < tile_size; ++lx) {
                const std::int32_t gx = tile_x + lx;
                if (gx < 0 || gx >= W) continue;

                // Edge fade in x direction.
                const std::int32_t edge_dist_x =
                    (lx < tile_size - 1 - lx) ? lx : (tile_size - 1 - lx);
                float fade_x;
                if (edge_dist_x >= overlap) {
                    fade_x = 1.0f;
                } else {
                    const float t = static_cast<float>(edge_dist_x) * inv_overlap;
                    const float s = std::sin(kHalfPi * t);
                    fade_x = s * s;
                }
                // Method A floor + Method B trapezoid.
                const float fade_xy = fade_x * fade_y;
                const float edge_w = (fade_xy > edge_floor) ? fade_xy : edge_floor;

                // Conf weight: clamp(conf - 1, conf_floor, conf_cap).
                const float conf_raw = conf_tile[row_tile + lx] - 1.0f;
                const float conf_low = (conf_raw < conf_floor) ? conf_floor : conf_raw;
                const float conf_w = (conf_low > conf_cap) ? conf_cap : conf_low;

                const float w = conf_w * edge_w;
                const float d = depth_tile[row_tile + lx];

                out_depth[row_global + gx] += d * w;
                out_weight[row_global + gx] += w;
            }
        }
    }

    // Normalize + diagnostic stats in single sweep.
    std::int64_t covered_pixels = 0;
    float min_d = std::numeric_limits<float>::infinity();
    float max_d = -std::numeric_limits<float>::infinity();
    float sum_d = 0.0f;
    for (std::size_t i = 0; i < total_pixels; ++i) {
        const float w = out_weight[i];
        if (w > 0.0f) {
            const float d = out_depth[i] / w;
            out_depth[i] = d;
            ++covered_pixels;
            if (d < min_d) min_d = d;
            if (d > max_d) max_d = d;
            sum_d += d;
        }
    }

    const auto t_end = std::chrono::steady_clock::now();
    const double elapsed_ms =
        std::chrono::duration<double, std::milli>(t_end - t_start).count();

    out_stats.covered_pixel_count = static_cast<std::int32_t>(covered_pixels);
    out_stats.coverage =
        static_cast<float>(covered_pixels) / static_cast<float>(total_pixels);
    out_stats.blend_time_ms = elapsed_ms;
    if (covered_pixels > 0) {
        out_stats.min_depth = min_d;
        out_stats.max_depth = max_d;
        out_stats.mean_depth = sum_d / static_cast<float>(covered_pixels);
    }
}

BlendResult blend_tiles(
    const std::vector<TileInference>& tiles,
    const TileLayout& layout,
    float edge_floor,
    float conf_floor,
    float conf_cap) noexcept {

    BlendResult result;
    result.width = layout.image_width;
    result.height = layout.image_height;

    if (layout.image_width <= 0 || layout.image_height <= 0) {
        return result;
    }

    const std::size_t total_pixels =
        static_cast<std::size_t>(layout.image_width) *
        static_cast<std::size_t>(layout.image_height);
    result.depth.assign(total_pixels, 0.0f);
    result.weight.assign(total_pixels, 0.0f);

    // Wrap each owning TileInference in a non-owning TileView and delegate to
    // blend_tiles_view (the hot path). No per-tile float copy.
    std::vector<TileView> views;
    views.reserve(tiles.size());
    const std::size_t tile_px =
        static_cast<std::size_t>(layout.tile_size) * layout.tile_size;
    for (const TileInference& t : tiles) {
        // Defensive: per-tile vectors must have tile_size² floats.
        if (t.depth.size() != tile_px || t.conf.size() != tile_px) continue;
        TileView v;
        v.tile = t.tile;
        v.depth = t.depth.data();
        v.conf = t.conf.data();
        views.push_back(v);
    }

    BlendStats stats;
    blend_tiles_view(
        views.data(), static_cast<std::int32_t>(views.size()),
        layout, edge_floor, conf_floor, conf_cap,
        result.depth.data(), result.weight.data(), stats);

    result.coverage = stats.coverage;
    result.blend_time_ms = stats.blend_time_ms;
    result.min_depth = stats.min_depth;
    result.max_depth = stats.max_depth;
    result.mean_depth = stats.mean_depth;
    return result;
}

}  // namespace pipeline
}  // namespace aether
