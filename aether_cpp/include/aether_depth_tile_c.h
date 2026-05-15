// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// aether_depth_tile — C ABI for Plan G W1 + W2 D1 depth/mask math.
//
// Exposes the cross-platform algorithms from aether/pipeline/{tile_layout,
// tile_blend, mask_post}.h to Swift (iOS, via bridging header) / Kotlin
// (Android, via JNI thin shim) / Dart FFI (Flutter direct) / JS (Web, via
// WASM).
//
// CoreML / TFLite / NNAPI / ONNX Runtime inference itself stays in per-
// platform thin shims — these C functions only run the deterministic math
// (tile layout / blend / mask post-process) that should be bit-equal
// across all platforms.
//
// Memory: ALL buffers are caller-allocated. No malloc/free crosses the FFI
// boundary. Sizes are passed alongside pointers; functions return rc code.

#ifndef AETHER_DEPTH_TILE_C_H
#define AETHER_DEPTH_TILE_C_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ─── Result codes ───────────────────────────────────────────────────
// Stable across versions — keep adding new codes at the end, never renumber.
typedef enum {
    AETHER_DEPTH_TILE_OK = 0,
    AETHER_DEPTH_TILE_ERR_BAD_ARGS = 1,          ///< Null pointer / nonsensical dims.
    AETHER_DEPTH_TILE_ERR_BUFFER_TOO_SMALL = 2,  ///< Caller buffer < required capacity.
    AETHER_DEPTH_TILE_ERR_TILE_SIZE = 3,         ///< tile_size <= overlap or image < tile.
} aether_depth_tile_rc_t;

// ─── Tile layout ────────────────────────────────────────────────────

/// One tile's position in source image coords.
typedef struct {
    int32_t x;       ///< Top-left x (>= 0).
    int32_t y;       ///< Top-left y (>= 0).
    int32_t width;   ///< Tile width (= tile_size).
    int32_t height;  ///< Tile height (= tile_size).
    int32_t row;     ///< Row index in tile grid.
    int32_t col;     ///< Column index in tile grid.
} aether_tile_rect_t;

/// Layout dims (size of the implicit tile array = nx * ny).
typedef struct {
    int32_t tile_size;
    int32_t overlap;
    int32_t stride;        ///< tile_size - overlap.
    int32_t image_width;
    int32_t image_height;
    int32_t nx;            ///< tiles per row.
    int32_t ny;            ///< rows.
    int32_t tile_count;    ///< = nx * ny (convenience).
} aether_tile_layout_info_t;

/// Compute tile layout for an image of `image_w × image_h`.
///
/// Plan G defaults: tile_size=518 (DA3-LARGE-1.1 fixed), overlap=32.
///
/// @param image_w/h          Source image dimensions.
/// @param tile_size          DA3 model input dim (typically 518).
/// @param overlap            Pixels of overlap between adjacent tiles.
/// @param out_info           OUT: layout dims (always filled if rc == OK).
/// @param out_tiles          OUT: tile rects, row-major. Filled up to
///                            min(out_info->tile_count, tile_array_capacity).
/// @param tile_array_capacity Max tiles caller has allocated in out_tiles.
///                            Pass 0 to query only (out_info still filled).
/// @return AETHER_DEPTH_TILE_OK on success.
int32_t aether_compute_tile_layout(
    int32_t image_w, int32_t image_h,
    int32_t tile_size, int32_t overlap,
    aether_tile_layout_info_t* out_info,
    aether_tile_rect_t* out_tiles, int32_t tile_array_capacity);

// ─── Tile blend ─────────────────────────────────────────────────────

/// One tile's inference output (caller owns the float arrays).
typedef struct {
    aether_tile_rect_t tile;
    const float* depth;  ///< tile_size² floats, row-major.
    const float* conf;   ///< tile_size² floats, row-major.
} aether_tile_inference_t;

/// Stats from blend pass.
typedef struct {
    int32_t covered_pixel_count;   ///< Pixels with weight > 0 (should = W*H).
    float coverage;                ///< covered / (W*H).
    float min_depth, max_depth, mean_depth;
    double blend_time_ms;
} aether_blend_stats_t;

/// Blend N tiles into a full-frame depth + weight map.
///
/// Weight formula per pixel:
///   w = conf_w × edge_w
///   conf_w = clamp(conf - 1.0, conf_floor, conf_cap)
///   edge_w = max(edge_floor, sin²(π/2 · min(dx, overlap)/overlap) · same_y)
///
/// Plan G W1 D3 locked values: edge_floor=0.05, conf_floor=0.01, conf_cap=1.0.
///
/// @param tiles              N tile inferences. Each tile.depth/conf must point to
///                            tile_size² floats.
/// @param n_tiles            Number of tiles.
/// @param image_w/h          Output image dims.
/// @param tile_size, overlap Same as used in aether_compute_tile_layout.
/// @param edge_floor         Method A floor (Plan G locked 0.05).
/// @param conf_floor         Conf weight floor (Plan G locked 0.01).
/// @param conf_cap           Conf weight cap (Plan G locked 1.0).
/// @param out_depth          OUT: image_w × image_h floats, row-major. Caller alloc.
/// @param out_weight         OUT: image_w × image_h floats, row-major. Caller alloc.
/// @param out_stats          OUT: blend stats. Optional (may be NULL).
/// @return AETHER_DEPTH_TILE_OK on success.
int32_t aether_blend_tiles(
    const aether_tile_inference_t* tiles, int32_t n_tiles,
    int32_t image_w, int32_t image_h,
    int32_t tile_size, int32_t overlap,
    float edge_floor, float conf_floor, float conf_cap,
    float* out_depth, float* out_weight,
    aether_blend_stats_t* out_stats);

// ─── Mask post-process ──────────────────────────────────────────────

/// Apply sigmoid in-place: x ← 1 / (1 + exp(-x)). Stable for large negative x.
void aether_sigmoid_inplace(float* data, int32_t count);

/// Pick the hypothesis index with the highest IoU prediction.
/// Returns 0 if iou_pred is NULL or count <= 0.
int32_t aether_pick_best_iou(const float* iou_pred, int32_t count);

/// Bilinear resize (half-pixel-center convention, matches PIL/OpenCV INTER_LINEAR).
void aether_bilinear_resize(
    const float* src, int32_t src_w, int32_t src_h,
    float* dst, int32_t dst_w, int32_t dst_h);

/// EdgeTAM post-process: pick best of N hypotheses, sigmoid → [0, 1] mask.
///
/// @param masks_logits   n_hypotheses × mask_h × mask_w fp32 logits (input).
/// @param iou_pred       n_hypotheses fp32 IoU predictions.
/// @param n_hypotheses   Number of mask hypotheses (typically 3 for SAM 2 family).
/// @param mask_h/w       Mask dims (typically 256×256 for EdgeTAM).
/// @param out_mask       OUT: mask_h × mask_w fp32 probability map.
/// @param out_best_idx   OUT: picked hypothesis index. Optional (may be NULL).
/// @return AETHER_DEPTH_TILE_OK on success.
int32_t aether_edgetam_post_process(
    const float* masks_logits, const float* iou_pred,
    int32_t n_hypotheses, int32_t mask_h, int32_t mask_w,
    float* out_mask, int32_t* out_best_idx);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // AETHER_DEPTH_TILE_C_H
