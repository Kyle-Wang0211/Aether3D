// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether_depth_tile_c.h"

#include "aether/pipeline/tile_layout.h"
#include "aether/pipeline/tile_blend.h"
#include "aether/pipeline/mask_post.h"
#include "aether/pipeline/scale_align.h"

#include <cstdint>
#include <cstring>

using aether::pipeline::TileRect;
using aether::pipeline::TileLayout;
using aether::pipeline::TileInference;
using aether::pipeline::BlendResult;

extern "C" {

int32_t aether_compute_tile_layout(
    int32_t image_w, int32_t image_h,
    int32_t tile_size, int32_t overlap,
    aether_tile_layout_info_t* out_info,
    aether_tile_rect_t* out_tiles, int32_t tile_array_capacity) {

    if (out_info == nullptr) {
        return AETHER_DEPTH_TILE_ERR_BAD_ARGS;
    }
    if (tile_size <= overlap || image_w < tile_size || image_h < tile_size) {
        return AETHER_DEPTH_TILE_ERR_TILE_SIZE;
    }
    const TileLayout layout = aether::pipeline::make_tile_layout(
        image_w, image_h, tile_size, overlap);

    out_info->tile_size = layout.tile_size;
    out_info->overlap = layout.overlap;
    out_info->stride = layout.stride;
    out_info->image_width = layout.image_width;
    out_info->image_height = layout.image_height;
    out_info->nx = layout.nx;
    out_info->ny = layout.ny;
    out_info->tile_count = static_cast<int32_t>(layout.tiles.size());

    if (out_tiles != nullptr && tile_array_capacity > 0) {
        const int32_t n_copy = (out_info->tile_count < tile_array_capacity)
            ? out_info->tile_count : tile_array_capacity;
        for (int32_t i = 0; i < n_copy; ++i) {
            const TileRect& src = layout.tiles[static_cast<std::size_t>(i)];
            out_tiles[i].x = src.x;
            out_tiles[i].y = src.y;
            out_tiles[i].width = src.width;
            out_tiles[i].height = src.height;
            out_tiles[i].row = src.row;
            out_tiles[i].col = src.col;
        }
        if (out_info->tile_count > tile_array_capacity) {
            return AETHER_DEPTH_TILE_ERR_BUFFER_TOO_SMALL;
        }
    }
    return AETHER_DEPTH_TILE_OK;
}

int32_t aether_blend_tiles(
    const aether_tile_inference_t* tiles, int32_t n_tiles,
    int32_t image_w, int32_t image_h,
    int32_t tile_size, int32_t overlap,
    float edge_floor, float conf_floor, float conf_cap,
    float* out_depth, float* out_weight,
    aether_blend_stats_t* out_stats) {

    if (tiles == nullptr || n_tiles <= 0
        || out_depth == nullptr || out_weight == nullptr
        || image_w <= 0 || image_h <= 0
        || tile_size <= overlap || image_w < tile_size || image_h < tile_size) {
        return AETHER_DEPTH_TILE_ERR_BAD_ARGS;
    }

    // Reconstruct C++ layout from dims.
    const TileLayout layout = aether::pipeline::make_tile_layout(
        image_w, image_h, tile_size, overlap);

    // Build non-owning TileView array. NO float copy across FFI boundary —
    // the C ABI's `const float* depth` / `*conf` are passed straight through
    // to blend_tiles_view as read-only views. Earlier impl copied each tile
    // into a std::vector<TileInference>, which added ~170ms FFI marshaling
    // for 12 tiles × 2 × 268K floats on iPhone 14 Pro.
    std::vector<aether::pipeline::TileView> views;
    views.reserve(static_cast<std::size_t>(n_tiles));
    for (int32_t i = 0; i < n_tiles; ++i) {
        if (tiles[i].depth == nullptr || tiles[i].conf == nullptr) {
            return AETHER_DEPTH_TILE_ERR_BAD_ARGS;
        }
        aether::pipeline::TileView v;
        v.tile.x = tiles[i].tile.x;
        v.tile.y = tiles[i].tile.y;
        v.tile.width = tiles[i].tile.width;
        v.tile.height = tiles[i].tile.height;
        v.tile.row = tiles[i].tile.row;
        v.tile.col = tiles[i].tile.col;
        v.depth = tiles[i].depth;
        v.conf = tiles[i].conf;
        views.push_back(v);
    }

    aether::pipeline::BlendStats stats;
    aether::pipeline::blend_tiles_view(
        views.data(), static_cast<int32_t>(views.size()),
        layout, edge_floor, conf_floor, conf_cap,
        out_depth, out_weight, stats);

    if (out_stats != nullptr) {
        out_stats->covered_pixel_count = stats.covered_pixel_count;
        out_stats->coverage = stats.coverage;
        out_stats->min_depth = stats.min_depth;
        out_stats->max_depth = stats.max_depth;
        out_stats->mean_depth = stats.mean_depth;
        out_stats->blend_time_ms = stats.blend_time_ms;
    }
    return AETHER_DEPTH_TILE_OK;
}

void aether_sigmoid_inplace(float* data, int32_t count) {
    if (count <= 0) return;
    aether::pipeline::sigmoid_inplace(data, static_cast<std::size_t>(count));
}

int32_t aether_pick_best_iou(const float* iou_pred, int32_t count) {
    return aether::pipeline::pick_best_mask_hypothesis(iou_pred, count);
}

void aether_bilinear_resize(
    const float* src, int32_t src_w, int32_t src_h,
    float* dst, int32_t dst_w, int32_t dst_h) {
    aether::pipeline::bilinear_resize(src, src_w, src_h, dst, dst_w, dst_h);
}

int32_t aether_edgetam_post_process(
    const float* masks_logits, const float* iou_pred,
    int32_t n_hypotheses, int32_t mask_h, int32_t mask_w,
    float* out_mask, int32_t* out_best_idx) {
    if (masks_logits == nullptr || iou_pred == nullptr || out_mask == nullptr
        || n_hypotheses <= 0 || mask_h <= 0 || mask_w <= 0) {
        return AETHER_DEPTH_TILE_ERR_BAD_ARGS;
    }
    const int32_t best_idx = aether::pipeline::edgetam_post_process(
        masks_logits, iou_pred, n_hypotheses, mask_h, mask_w, out_mask);
    if (out_best_idx != nullptr) {
        *out_best_idx = best_idx;
    }
    return AETHER_DEPTH_TILE_OK;
}

int32_t aether_scale_align_lsq(
    const float* z_ai, const float* z_metric,
    int32_t n, float outlier_thresh,
    aether_scale_align_result_t* out_result) {
    if (out_result == nullptr) {
        return AETHER_DEPTH_TILE_ERR_BAD_ARGS;
    }
    const aether::pipeline::ScaleAlignResult r =
        aether::pipeline::scale_align_lsq(z_ai, z_metric, n, outlier_thresh);
    out_result->scale = r.scale;
    out_result->translation = r.translation;
    out_result->rmse = r.rmse;
    out_result->n_used = r.n_used;
    out_result->n_input = r.n_input;
    out_result->ok = r.ok ? 1 : 0;
    return AETHER_DEPTH_TILE_OK;
}

}  // extern "C"
