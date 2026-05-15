// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/pipeline/tile_blend.h"

#include <cmath>
#include <chrono>
#include <limits>

namespace aether {
namespace pipeline {

BlendResult blend_tiles(
    const std::vector<TileInference>& tiles,
    const TileLayout& layout,
    float edge_floor,
    float conf_floor,
    float conf_cap) noexcept {

    const std::int32_t W = layout.image_width;
    const std::int32_t H = layout.image_height;
    const std::int32_t tile_size = layout.tile_size;
    const std::int32_t overlap = layout.overlap;
    const float inv_overlap = 1.0f / static_cast<float>(overlap);
    constexpr float kHalfPi = 1.5707963267948966f;

    BlendResult result;
    result.width = W;
    result.height = H;

    // Guard: degenerate layout → empty result, not crash.
    if (W <= 0 || H <= 0 || tile_size <= 0) {
        return result;
    }

    const std::size_t total_pixels =
        static_cast<std::size_t>(W) * static_cast<std::size_t>(H);
    result.depth.assign(total_pixels, 0.0f);
    result.weight.assign(total_pixels, 0.0f);

    const auto t_start = std::chrono::steady_clock::now();

    for (const TileInference& inf : tiles) {
        const TileRect& tile = inf.tile;
        const float* depth_tile = inf.depth.data();
        const float* conf_tile = inf.conf.data();
        const std::int32_t tile_x = tile.x;
        const std::int32_t tile_y = tile.y;

        // Defensive: per-tile depth/conf must be tile_size² floats.
        if (inf.depth.size() != static_cast<std::size_t>(tile_size) * tile_size
            || inf.conf.size() != static_cast<std::size_t>(tile_size) * tile_size) {
            continue;  // Skip malformed tile.
        }

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

                result.depth[row_global + gx] += d * w;
                result.weight[row_global + gx] += w;
            }
        }
    }

    // Normalize + diagnostic stats in single sweep.
    std::int64_t covered_pixels = 0;
    float min_d = std::numeric_limits<float>::infinity();
    float max_d = -std::numeric_limits<float>::infinity();
    float sum_d = 0.0f;
    for (std::size_t i = 0; i < total_pixels; ++i) {
        const float w = result.weight[i];
        if (w > 0.0f) {
            const float d = result.depth[i] / w;
            result.depth[i] = d;
            ++covered_pixels;
            if (d < min_d) min_d = d;
            if (d > max_d) max_d = d;
            sum_d += d;
        }
    }

    const auto t_end = std::chrono::steady_clock::now();
    const double elapsed_ms =
        std::chrono::duration<double, std::milli>(t_end - t_start).count();

    result.coverage = static_cast<float>(covered_pixels) / static_cast<float>(total_pixels);
    result.blend_time_ms = elapsed_ms;
    if (covered_pixels > 0) {
        result.min_depth = min_d;
        result.max_depth = max_d;
        result.mean_depth = sum_d / static_cast<float>(covered_pixels);
    }
    return result;
}

}  // namespace pipeline
}  // namespace aether
