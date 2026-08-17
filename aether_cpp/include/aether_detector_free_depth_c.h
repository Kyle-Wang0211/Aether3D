// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_DETECTOR_FREE_DEPTH_C_H
#define AETHER_DETECTOR_FREE_DEPTH_C_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    AETHER_DETECTOR_FREE_OK = 0,
    AETHER_DETECTOR_FREE_ERR_BAD_ARGS = 1,
    AETHER_DETECTOR_FREE_ERR_UNSUPPORTED = 2,
    AETHER_DETECTOR_FREE_ERR_GPU = 3,
    AETHER_DETECTOR_FREE_ERR_BUFFER_TOO_SMALL = 4,
    AETHER_DETECTOR_FREE_ERR_INTERNAL = 5,
} aether_detector_free_rc_t;

typedef struct aether_detector_free_session aether_detector_free_session_t;

// Frozen product image contract for the commercial-clean detector-free pass.
// Keeping this resolution in the ABI prevents callers from accidentally
// materializing a full-resolution float image in Dart/Swift/Java. JPEG decode,
// area downsampling, RGB conversion, grayscale conversion, and intrinsic
// scaling all happen synchronously inside the shared C++ core. Call this API
// from a background worker/isolate; it performs no UI-thread dispatch.
enum {
    AETHER_DETECTOR_FREE_IMAGE_WIDTH = 128,
    AETHER_DETECTOR_FREE_IMAGE_HEIGHT = 72,
    AETHER_DETECTOR_FREE_IMAGE_PIXELS =
        AETHER_DETECTOR_FREE_IMAGE_WIDTH *
        AETHER_DETECTOR_FREE_IMAGE_HEIGHT,
    AETHER_DETECTOR_FREE_IMAGE_RGB_BYTES =
        AETHER_DETECTOR_FREE_IMAGE_PIXELS * 3,
};

typedef struct {
    int32_t source_width;
    int32_t source_height;
    int32_t output_width;
    int32_t output_height;
    float scale_x;
    float scale_y;
    // diag(scale_x, scale_y, 1) * source_K, row-major. This deliberately
    // matches the existing research scaled_intrinsics() contract.
    float scaled_k_row_major_3x3[9];
} aether_detector_free_preprocessed_image_t;

// Cross-platform compressed-bytes entry point (including Web/Wasm). The
// decoder does not apply EXIF rotation, matching the research/Pillow input
// grid. Output RGB is interleaved row-major. Gray u8 follows OpenCV's
// RGB2GRAY fixed-point coefficients; gray f32 is the exact u8 value converted
// to float, which is the numerical input expected by the tiled sweep.
int32_t aether_detector_free_preprocess_jpeg_bytes(
    const uint8_t* jpeg_bytes,
    size_t jpeg_byte_count,
    const float source_k_row_major_3x3[9],
    uint8_t* out_rgb_u8,
    size_t rgb_capacity_bytes,
    uint8_t* out_gray_u8,
    size_t gray_u8_capacity,
    float* out_gray_f32,
    size_t gray_f32_capacity,
    aether_detector_free_preprocessed_image_t* out_image);

// Native file-backed entry point. It avoids copying even the compressed JPEG
// into Dart. Web callers use the bytes entry point because browser files do
// not have POSIX paths.
int32_t aether_detector_free_preprocess_jpeg_path(
    const char* jpeg_path,
    const float source_k_row_major_3x3[9],
    uint8_t* out_rgb_u8,
    size_t rgb_capacity_bytes,
    uint8_t* out_gray_u8,
    size_t gray_u8_capacity,
    float* out_gray_f32,
    size_t gray_f32_capacity,
    aether_detector_free_preprocessed_image_t* out_image);

// Controls how already-sampled per-view NCC values are combined at each depth.
// The default preserves the current top-K mean exactly.  The experimental
// robust modes consume no extra image samples and do not add a GPU dispatch.
typedef enum {
    AETHER_DETECTOR_FREE_VIEW_AGGREGATION_TOP_MINIMUM = 0,
    AETHER_DETECTOR_FREE_VIEW_AGGREGATION_TRIMMED_ALL = 1,
    AETHER_DETECTOR_FREE_VIEW_AGGREGATION_MEAN_ALL = 2,
    AETHER_DETECTOR_FREE_VIEW_AGGREGATION_TOP_MINIMUM_WITH_DISSENT = 3,
} aether_detector_free_view_aggregation_t;

// A session owns one reference image plus up to eight known-pose source
// images. Images are grayscale float32 in [0,255], stored frame-major as
// [reference, source0, ...]. The GPU buffers and WGSL pipeline are reused for
// every output tile, so full-image coverage never requires a full-image depth
// volume. Rejected pixels never acquire product-point identity.
typedef struct {
    int32_t image_width;
    int32_t image_height;
    int32_t max_tile_width;
    int32_t max_tile_height;
    int32_t depth_count;
    int32_t source_count;
    int32_t patch_n;
    int32_t minimum_views;
    int32_t exclusion_radius_samples;
    float minimum_std_u8;
    float ncc_min;
    float unique_depth_margin;
    float inverse_depth_first;
    float inverse_depth_step;
    float reference_inverse_k_row_major_3x3[9];
} aether_detector_free_options_t;

typedef struct {
    int32_t minimum_reciprocal_views;
    float absolute_depth_tolerance_m;
    float relative_depth_tolerance;
    float minimum_parallax_deg;
} aether_detector_free_reciprocal_options_t;

// Second-stage metric refinement around a coarse winner.  The fine sweep is
// local to each pixel and cannot create a point unless the coarse pass already
// accepted it.  `coarse_step_span` is the number of coarse inverse-depth steps
// searched on either side of the winner.  Uniqueness is measured in metres,
// not a fixed number of depth indices.
typedef struct {
    int32_t fine_depth_count;
    float coarse_step_span;
    float uniqueness_absolute_m;
    float uniqueness_relative;
} aether_detector_free_refine_options_t;

void aether_detector_free_options_default(
    aether_detector_free_options_t* out_options);

void aether_detector_free_reciprocal_options_default(
    aether_detector_free_reciprocal_options_t* out_options);

void aether_detector_free_refine_options_default(
    aether_detector_free_refine_options_t* out_options);

// `source_projections` contains source_count row-major 3x4 matrices mapping
// a point in the reference-camera coordinate system to source pixels.
int32_t aether_detector_free_session_create(
    const aether_detector_free_options_t* options,
    const float* gray_frames,
    size_t gray_value_count,
    const float* source_projections,
    size_t projection_value_count,
    aether_detector_free_session_t** out_session);

// Selects a per-view aggregation mode for subsequent tiles. Robust modes only
// reuse NCC values already computed by the same sweep. They are exposed for
// cross-scene evaluation; the default remains TOP_MINIMUM until a no-regression
// quality and time verdict is established.
int32_t aether_detector_free_session_set_view_aggregation(
    aether_detector_free_session_t* session,
    int32_t aggregation);

// Runs one bounded tile. Output layout is tile row-major. The best depth index
// is diagnostic for rejected pixels and must be consumed only when `accepted`
// is nonzero. A product depth is:
//   1 / (inverse_depth_first + index * inverse_depth_step).
int32_t aether_detector_free_session_run_tile(
    aether_detector_free_session_t* session,
    int32_t tile_origin_x,
    int32_t tile_origin_y,
    int32_t tile_width,
    int32_t tile_height,
    uint16_t* out_best_index,
    float* out_best_score,
    float* out_second_score,
    uint8_t* out_supporting_views,
    uint8_t* out_accepted,
    int32_t output_capacity);

// Runs the same single 48-layer sweep and returns a continuous depth obtained
// from the already-computed NCC values immediately adjacent to the winning
// layer.  It performs no additional image sampling and preserves the exact
// coarse best index, scores, support count, and accepted mask.  When a stable
// local maximum is unavailable, the returned depth is exactly the discrete
// coarse depth. `out_peak_min_neighbor_drop` is min(best-left, best-right)
// for a valid local maximum and zero otherwise; it allows a birth coordinator
// to require a sharp photometric peak without another GPU pass.
int32_t aether_detector_free_session_run_interpolated_tile(
    aether_detector_free_session_t* session,
    int32_t tile_origin_x,
    int32_t tile_origin_y,
    int32_t tile_width,
    int32_t tile_height,
    uint16_t* out_best_index,
    float* out_interpolated_depth_m,
    float* out_peak_min_neighbor_drop,
    float* out_best_score,
    float* out_second_score,
    uint8_t* out_supporting_views,
    uint8_t* out_accepted,
    int32_t output_capacity);

// Runs the unchanged top-minimum sweep and additionally reports the gap
// between its winning top-K score and the mean score of every geometrically
// valid view at that same depth. This is a same-dispatch diagnostic: it cannot
// move a depth winner or create/reject a product point by itself.
int32_t aether_detector_free_session_run_diagnostic_tile(
    aether_detector_free_session_t* session,
    int32_t tile_origin_x,
    int32_t tile_origin_y,
    int32_t tile_width,
    int32_t tile_height,
    uint16_t* out_best_index,
    float* out_all_view_dissent,
    float* out_best_score,
    float* out_second_score,
    uint8_t* out_supporting_views,
    uint8_t* out_accepted,
    int32_t output_capacity);

// Refine a previously accepted coarse tile without changing any pre-existing
// sparse point.  The coarse arrays use the same tile-row-major layout as
// `aether_detector_free_session_run_tile`.  `out_refined_depth_m` is the
// continuous product depth consumed by reciprocal verification.
int32_t aether_detector_free_session_run_refined_tile(
    aether_detector_free_session_t* session,
    int32_t tile_origin_x,
    int32_t tile_origin_y,
    int32_t tile_width,
    int32_t tile_height,
    const uint16_t* coarse_best_index,
    const uint8_t* coarse_accepted,
    const aether_detector_free_refine_options_t* refine_options,
    float* out_refined_depth_m,
    float* out_best_score,
    float* out_second_score,
    uint8_t* out_supporting_views,
    uint8_t* out_accepted,
    int32_t output_capacity);

// Cross-reference birth gate. A reference winner is born only when the same
// 3D location is independently accepted by enough reciprocal sweeps and the
// camera rays clear the parallax threshold. Reciprocal arrays are view-major,
// each containing image_width*image_height entries. This is a generation
// gate: rejected pixels never enter a point cloud and are not deleted later.
int32_t aether_detector_free_filter_reciprocal_births(
    int32_t image_width,
    int32_t image_height,
    int32_t depth_count,
    float inverse_depth_first,
    float inverse_depth_step,
    const float reference_inverse_k_row_major_3x3[9],
    const uint16_t* reference_best_index,
    const uint8_t* reference_accepted,
    int32_t reciprocal_view_count,
    const uint16_t* reciprocal_best_indices,
    const uint8_t* reciprocal_accepted,
    const float* reference_to_reciprocal_projections_row_major_3x4,
    const float* reciprocal_camera_centers_in_reference_xyz,
    const aether_detector_free_reciprocal_options_t* options,
    uint8_t* out_consistent_views,
    uint8_t* out_birth,
    int32_t output_capacity);

// Metric-depth counterpart used after coarse-to-fine refinement.  This avoids
// re-quantizing a refined winner back to the coarse depth grid before
// reciprocal verification.
int32_t aether_detector_free_filter_reciprocal_depth_births(
    int32_t image_width,
    int32_t image_height,
    const float reference_inverse_k_row_major_3x3[9],
    const float* reference_depth_m,
    const uint8_t* reference_accepted,
    int32_t reciprocal_view_count,
    const float* reciprocal_depths_m,
    const uint8_t* reciprocal_accepted,
    const float* reference_to_reciprocal_projections_row_major_3x4,
    const float* reciprocal_camera_centers_in_reference_xyz,
    const aether_detector_free_reciprocal_options_t* options,
    uint8_t* out_consistent_views,
    uint8_t* out_birth,
    int32_t output_capacity);

void aether_detector_free_session_free(
    aether_detector_free_session_t* session);

const char* aether_detector_free_result_str(int32_t rc);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // AETHER_DETECTOR_FREE_DEPTH_C_H
