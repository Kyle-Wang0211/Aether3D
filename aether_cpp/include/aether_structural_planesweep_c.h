// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_STRUCTURAL_PLANESWEEP_C_H
#define AETHER_STRUCTURAL_PLANESWEEP_C_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    AETHER_PLANESWEEP_OK = 0,
    AETHER_PLANESWEEP_ERR_BAD_ARGS = 1,
    AETHER_PLANESWEEP_ERR_UNSUPPORTED = 2,
    AETHER_PLANESWEEP_ERR_GPU = 3,
    AETHER_PLANESWEEP_ERR_BUFFER_TOO_SMALL = 4,
    AETHER_PLANESWEEP_ERR_INTERNAL = 5,
} aether_planesweep_rc_t;

typedef struct aether_planesweep_session aether_planesweep_session_t;
typedef struct aether_planesweep_image aether_planesweep_image_t;

// One tile owns a bounded candidate set. A point is XYZ in metric world
// coordinates. Points are laid out candidate-major, hypothesis-minor; index
// candidate*hypotheses_per_candidate is the certified structural plane and
// subsequent hypotheses are parallel-depth competitors.
typedef struct {
    int32_t point_count;
    int32_t candidate_count;
    int32_t hypotheses_per_candidate;
    int32_t patch_n;
    int32_t max_views;
    int32_t scale_count;
    float basis_u_xyz[3];
    float basis_v_xyz[3];
} aether_planesweep_session_options_t;

typedef struct {
    int32_t minimum_views;
    float ncc_min;
    float minimum_parallax_deg;
    float unique_depth_margin;
    float post_min_ncc;
    int32_t post_minimum_views;
    float post_minimum_parallax_deg;
} aether_planesweep_birth_options_t;

typedef struct {
    int32_t accepted;
    int32_t supporting_views;
    float median_ncc;
    float max_parallax_deg;
    float observed_depth_margin;
} aether_planesweep_candidate_result_t;

void aether_planesweep_session_options_default(
    aether_planesweep_session_options_t* out_options);

void aether_planesweep_birth_options_default(
    aether_planesweep_birth_options_t* out_options);

// Creates a Dawn compute session when Dawn is available. Sessions share the
// process-wide device and immutable pipeline while retaining independent tile
// buffers. Dawn maps the same WGSL to Metal on Apple and Vulkan on
// Android/HarmonyOS. Web may use the same contract through WASM and WebGPU;
// the deterministic score function below is also a CPU fallback.
int32_t aether_planesweep_session_create(
    const aether_planesweep_session_options_t* options,
    const float* points_xyz,
    aether_planesweep_session_t** out_session);

// `packed_rgba8` contains width*height little-endian RGBA pixels. Projection
// is row-major 3x4 and maps metric world XYZ1 to image pixels. `camera_center`
// is retained for the later parallax gate. Each (scale_index, view_index) may
// be written exactly once.
int32_t aether_planesweep_session_add_view(
    aether_planesweep_session_t* session,
    int32_t scale_index,
    int32_t view_index,
    const uint32_t* packed_rgba8,
    int32_t width,
    int32_t height,
    const float projection_row_major_3x4[12],
    const float camera_center_xyz[3],
    float patch_radius_m,
    float min_std_u8);

// Adds one decoded view to every scale in a session. The source pixels are
// uploaded/scored once per scale because patch radii can differ, but the caller
// decodes or materializes the RGBA image only once. Array lengths must equal
// the session scale count; validation completes before any scale is written.
int32_t aether_planesweep_session_add_view_scales(
    aether_planesweep_session_t* session,
    int32_t view_index,
    const uint32_t* packed_rgba8,
    int32_t width,
    int32_t height,
    const float projection_row_major_3x4[12],
    const float camera_center_xyz[3],
    const float* patch_radius_m_by_scale,
    const float* min_std_u8_by_scale,
    int32_t scale_count);

// Owns one decoded RGBA image and lazily uploads it to the shared Dawn device.
// A caller may feed the same image to any number of independent tile sessions;
// the full-resolution pixels are uploaded only on first use. This is the
// bounded-memory product route: keep one image alive, feed every tile that
// needs it, then free it before decoding the next image.
int32_t aether_planesweep_image_create_rgba(
    const uint32_t* packed_rgba8,
    int32_t width,
    int32_t height,
    aether_planesweep_image_t** out_image);

int32_t aether_planesweep_image_decode_jpeg(
    const char* jpeg_path,
    aether_planesweep_image_t** out_image,
    int32_t* out_width,
    int32_t* out_height);

int32_t aether_planesweep_session_add_image_view_scales(
    aether_planesweep_session_t* session,
    int32_t view_index,
    aether_planesweep_image_t* image,
    const float projection_row_major_3x4[12],
    const float camera_center_xyz[3],
    const float* patch_radius_m_by_scale,
    const float* min_std_u8_by_scale,
    int32_t scale_count);

void aether_planesweep_image_free(aether_planesweep_image_t* image);

// Cross-platform file-backed variant used by Dart/background workers. JPEG is
// decoded without EXIF rotation, consumed synchronously, then immediately
// released; at most one decoded frame is resident per call. The projection
// must address the stored JPEG pixel grid. This keeps image decode and compute
// outside Swift/Java while preserving the exact add_view math.
int32_t aether_planesweep_session_add_jpeg_view(
    aether_planesweep_session_t* session,
    int32_t scale_index,
    int32_t view_index,
    const char* jpeg_path,
    const float projection_row_major_3x4[12],
    const float camera_center_xyz[3],
    float patch_radius_m,
    float min_std_u8,
    int32_t* out_width,
    int32_t* out_height);

// File-backed multi-scale variant. The JPEG is decoded exactly once, consumed
// synchronously by every scale, and released before returning.
int32_t aether_planesweep_session_add_jpeg_view_scales(
    aether_planesweep_session_t* session,
    int32_t view_index,
    const char* jpeg_path,
    const float projection_row_major_3x4[12],
    const float camera_center_xyz[3],
    const float* patch_radius_m_by_scale,
    const float* min_std_u8_by_scale,
    int32_t scale_count,
    int32_t* out_width,
    int32_t* out_height);

// Quality-verification readback for an initialized session. Outputs are dense
// [scale][view][point][sample] normalized patches and
// [scale][view][point] validity/stddev tensors. Unwritten slots are zero.
// This is never used by the product hot path; it exists so cross-backend
// parity failures can be localized before thresholds or birth policy change.
int32_t aether_planesweep_session_debug_readback(
    aether_planesweep_session_t* session,
    float* out_normalized,
    int32_t normalized_capacity,
    uint8_t* out_valid,
    int32_t valid_capacity,
    float* out_stddev_u8,
    int32_t stddev_capacity);

// Scores the center plane and all parallel-depth hypotheses, then applies the
// exact all-pairs clique, parallax, and unique-depth birth contract. Results
// are candidate-major. The caller supplies one option set per scale. A point
// accepted by any scale is returned once; later scales are rescue-only and
// cannot alter a baseline birth.
int32_t aether_planesweep_session_finish(
    aether_planesweep_session_t* session,
    const uint8_t* candidate_view_masks,
    const aether_planesweep_birth_options_t* scale_options,
    int32_t scale_options_count,
    aether_planesweep_candidate_result_t* out_results,
    int32_t result_capacity);

// Same birth result plus one RGB triplet per candidate. Accepted candidates
// receive the per-channel median of the exact all-pairs-consistent clique that
// justified birth; rejected candidates remain black. This avoids a second
// platform-specific image decode/colorization path.
int32_t aether_planesweep_session_finish_rgb(
    aether_planesweep_session_t* session,
    const uint8_t* candidate_view_masks,
    const aether_planesweep_birth_options_t* scale_options,
    int32_t scale_options_count,
    aether_planesweep_candidate_result_t* out_results,
    int32_t result_capacity,
    uint8_t* out_rgb,
    int32_t rgb_capacity_bytes);

void aether_planesweep_session_free(aether_planesweep_session_t* session);

// Deterministic CPU scorer used for parity tests and non-Dawn fallbacks. The
// patch tensor layout is [view][point][sample], and valid is [view][point].
// Candidate view masks are optional; when non-null, layout is [point][view].
int32_t aether_planesweep_score_scale(
    const float* normalized_patches,
    const uint8_t* valid,
    const uint8_t* candidate_view_mask,
    const float* camera_centers_xyz,
    const float* points_xyz,
    int32_t view_count,
    int32_t point_count,
    int32_t sample_count,
    const aether_planesweep_birth_options_t* options,
    int32_t* out_supporting_views,
    float* out_median_ncc,
    float* out_max_parallax_deg,
    uint8_t* out_valid_score);

// Role-aware CPU/WASM scorer for one or more candidate groups. Points are
// laid out as [candidate][hypothesis], with hypothesis 0 as the proposed
// surface and the remaining hypotheses as parallel depth competitors. This
// preserves the same center-versus-competitor birth semantics used by the
// grouped Dawn session. point_count must be divisible by
// hypotheses_per_candidate.
int32_t aether_planesweep_score_scale_grouped(
    const float* normalized_patches,
    const uint8_t* valid,
    const uint8_t* candidate_view_mask,
    const float* camera_centers_xyz,
    const float* points_xyz,
    int32_t view_count,
    int32_t point_count,
    int32_t sample_count,
    int32_t hypotheses_per_candidate,
    const aether_planesweep_birth_options_t* options,
    int32_t* out_supporting_views,
    float* out_median_ncc,
    float* out_max_parallax_deg,
    uint8_t* out_valid_score);

// Applies the unique-depth ownership rule to already-scored hypotheses. This
// pure function is shared by the GPU session and CPU/WASM verification paths.
int32_t aether_planesweep_apply_unique_depth(
    int32_t candidate_count,
    int32_t hypotheses_per_candidate,
    const int32_t* supporting_views,
    const float* median_ncc,
    const float* max_parallax_deg,
    const uint8_t* valid_score,
    const aether_planesweep_birth_options_t* options,
    aether_planesweep_candidate_result_t* out_results,
    int32_t result_capacity,
    int32_t rescue_only);

const char* aether_planesweep_result_str(int32_t rc);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // AETHER_STRUCTURAL_PLANESWEEP_C_H
