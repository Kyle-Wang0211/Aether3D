// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_STRUCTURAL_CANDIDATE_C_H
#define AETHER_STRUCTURAL_CANDIDATE_C_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// A generic finite structural rectangle. For floors, basis_v_origin_value is
// zero and [v_min, v_max] are world coordinates along basis_v. For walls,
// basis_v is the floor normal, basis_v_origin_value is the floor plane value,
// and [v_min, v_max] are heights above that floor. The center plane always
// occupies hypothesis zero; later hypotheses are parallel competitors.
typedef struct {
    double normal_xyz[3];
    double basis_u_xyz[3];
    double basis_v_xyz[3];
    double plane_value_n_dot_x;
    double basis_v_origin_value;
    double u_min;
    double u_max;
    double v_min;
    double v_max;
    double grid_m;
} aether_structural_grid_spec_t;

typedef struct {
    double projection_row_major_3x4[12];
    double camera_center_xyz[3];
    int32_t width;
    int32_t height;
} aether_structural_frame_t;

typedef enum {
    AETHER_STRUCTURAL_VIEWS_PER_POINT = 0,
    AETHER_STRUCTURAL_VIEWS_PER_TILE = 1,
} aether_structural_view_mode_t;

typedef struct {
    int32_t maximum_views;
    double image_margin_px;
    double maximum_graze_deg;
    int32_t mode;
} aether_structural_view_options_t;

void aether_structural_view_options_default(
    aether_structural_view_options_t* out_options);

// Computes the deterministic u-major/v-minor grid size used by the research
// oracle. Return values reuse aether_planesweep_rc_t numeric values.
int32_t aether_structural_grid_count(
    const aether_structural_grid_spec_t* spec,
    int32_t* out_candidate_count);

// Builds double-precision centers plus candidate-major, hypothesis-minor
// points. depth_offsets_m[0] must be zero so no alternative can accidentally
// become the structural center published by the product.
int32_t aether_structural_grid_build(
    const aether_structural_grid_spec_t* spec,
    const double* depth_offsets_m,
    int32_t hypotheses_per_candidate,
    double* out_centers_xyz,
    int32_t center_capacity_doubles,
    double* out_points_xyz,
    int32_t point_capacity_doubles);

// Computes hypothesis visibility against all frames and selects deterministic
// views from center points. Layouts:
//   out_hypothesis_visible[point][frame]
//   out_selected_indices[candidate][maximum_views], -1 padded
//   out_selected_counts[candidate]
// PER_POINT mirrors the floor oracle. PER_TILE mirrors wall tile selection and
// repeats the shared result for every candidate so callers can use one grouping
// path. This function never reads images, LiDAR, or scene depth.
int32_t aether_structural_prepare_views(
    const double* centers_xyz,
    int32_t candidate_count,
    const double* points_xyz,
    int32_t point_count,
    const aether_structural_frame_t* frames,
    int32_t frame_count,
    const double normal_xyz[3],
    const aether_structural_view_options_t* options,
    uint8_t* out_hypothesis_visible,
    int32_t visible_capacity_bytes,
    int32_t* out_selected_indices,
    int32_t selected_capacity_ints,
    int32_t* out_selected_counts,
    int32_t selected_count_capacity);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // AETHER_STRUCTURAL_CANDIDATE_C_H
