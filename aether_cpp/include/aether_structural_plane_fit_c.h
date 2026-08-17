// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_STRUCTURAL_PLANE_FIT_C_H
#define AETHER_STRUCTURAL_PLANE_FIT_C_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    int32_t max_walls;
    int32_t theta_step_deg;
    double minimum_height_m;
    double wall_fit_band_m;
    double rho_step_m;
    double minimum_tangent_span_m;
    double minimum_height_span_m;
    int32_t preliminary_minimum_support;
    int32_t certified_minimum_support;
    int32_t certified_minimum_cells;
} aether_structural_plane_fit_options_t;

// Deterministic gravity-guided floor estimate used by the product-side wall
// generator.  The returned equation is `normal_xyz dot X = value_n_dot_x`.
// `certified` is true only when a spatially broad inlier set supports the
// fitted plane; callers must not let an uncertified result own point birth.
typedef struct {
    int32_t certified;
    int32_t support_points;
    int32_t coverage_cells_10cm;
    double normal_xyz[3];
    double value_n_dot_x;
    double rms_error_m;
} aether_structural_floor_t;

// Sparse floor proposals are deliberately proposal-only. Parallel layers are
// preserved as independent candidates until the known-plane multi-view sweep
// selects one decisive owner; no proposal may create a product point by
// itself. Coordinates use `normal_xyz dot X = value_n_dot_x`.
typedef struct {
    int32_t proposal_index;
    int32_t support_points_20mm;
    int32_t coverage_cells_10cm;
    double normal_xyz[3];
    double value_n_dot_x;
    double basis_u_xyz[3];
    double basis_v_xyz[3];
    double bounds_u_m[2];
    double bounds_v_m[2];
    double rms_error_m;
    double tilt_deg;
    double prior_score;
} aether_structural_floor_proposal_t;

typedef struct {
    int32_t maximum_candidates;
    double histogram_step_m;
    int32_t minimum_peak_support;
    double refinement_band_m;
    double support_band_m;
    int32_t minimum_support_points;
    int32_t minimum_coverage_cells_10cm;
    double maximum_tilt_deg;
    double minimum_camera_clearance_m;
    double distinct_plane_value_m;
} aether_structural_floor_proposal_options_t;

// A wall is returned even when certification fails so callers can persist a
// complete diagnostic record. Only `certified != 0` walls may own plane-sweep
// point birth. `basis_v_xyz` is the normalized known floor normal.
typedef struct {
    int32_t wall_index;
    int32_t theta_deg;
    int32_t certified;
    int32_t support_points_35mm;
    int32_t coverage_cells_10cm;
    int32_t domain_points;
    int32_t support_points_20mm[5];  // offsets -10,-5,0,+5,+10 cm
    int32_t support_cells_10cm[5];
    double normal_xyz[3];
    double basis_u_xyz[3];
    double basis_v_xyz[3];
    double plane_value_n_dot_x;
    double bounds_u_m[2];
    double bounds_height_m[2];
    double score;
    double support_prominence_vs_5cm;
    double coverage_prominence_vs_5cm;
} aether_structural_wall_t;

// Proposal-only camera-envelope wall. Camera trajectory one-sidedness rejects
// object/internal layers that cut through the capture path, but image-only B
// adjudication is still mandatory before point birth.
typedef struct {
    int32_t proposal_index;
    int32_t support_points_35mm;
    int32_t coverage_cells_10cm;
    double theta_deg;
    double normal_xyz[3];
    double basis_u_xyz[3];
    double basis_v_xyz[3];
    double plane_value_n_dot_x;
    double bounds_u_m[2];
    double bounds_height_m[2];
    double score;
    double camera_distance_min_m;
    double camera_distance_max_m;
    double camera_clearance_min_abs_m;
} aether_structural_envelope_wall_t;

typedef struct {
    int32_t maximum_candidates;
    int32_t theta_step_deg;
    double minimum_height_m;
    double maximum_height_percentile;
    double rho_step_m;
    double fit_band_m;
    int32_t minimum_support;
    double minimum_tangent_span_m;
    double minimum_height_span_m;
    double camera_crossing_tolerance_m;
    int32_t duplicate_angle_deg;
    double duplicate_plane_value_m;
} aether_structural_envelope_wall_options_t;

void aether_structural_plane_fit_options_default(
    aether_structural_plane_fit_options_t* out_options);

void aether_structural_floor_proposal_options_default(
    aether_structural_floor_proposal_options_t* out_options);

// Enumerates every supported gravity-low histogram peak below the complete
// camera trajectory. The output is sorted by plane value and intentionally
// retains parallel competitors separated by at least
// `distinct_plane_value_m`. The camera bound is the minimum camera coordinate
// projected onto `up_hint_xyz`. No image/model/LiDAR/scene-depth input is
// consumed. Return values: 0 OK, 1 bad arguments, 4 output buffer too small.
int32_t aether_structural_propose_floors(
    const float* points_xyz,
    int32_t point_count,
    const double up_hint_xyz[3],
    double minimum_camera_height,
    const aether_structural_floor_proposal_options_t* options,
    aether_structural_floor_proposal_t* out_proposals,
    int32_t proposal_capacity,
    int32_t* out_proposal_count);

void aether_structural_envelope_wall_options_default(
    aether_structural_envelope_wall_options_t* out_options);

// Enumerates supported vertical Hough peaks, requires the complete camera
// trajectory to stay on one side, then performs one finite-domain horizontal
// TLS refinement. Inputs are first-party sparse XYZ, selected floor, and
// camera centers only. Outputs never carry birth authority.
int32_t aether_structural_propose_envelope_walls(
    const float* points_xyz,
    int32_t point_count,
    const double* camera_centers_xyz,
    int32_t camera_count,
    const double floor_normal_xyz[3],
    double floor_value_n_dot_x,
    const aether_structural_envelope_wall_options_t* options,
    aether_structural_envelope_wall_t* out_walls,
    int32_t wall_capacity,
    int32_t* out_wall_count);

// Fits a floor from first-party sparse XYZ plus a gravity/up hint.  The mode
// search is one-dimensional along gravity, followed by a bounded three-pass
// least-squares plane refinement.  No image matcher, learned model, LiDAR, or
// scene depth is consumed.  Return values reuse aether_planesweep_rc_t.
int32_t aether_structural_fit_floor(
    const float* points_xyz,
    int32_t point_count,
    const double up_hint_xyz[3],
    aether_structural_floor_t* out_floor);

// Fits vertical wall candidates from the first-party sparse reconstruction and
// a known floor plane. No image matcher, learned model, LiDAR, or scene depth is
// consumed. The routine is deterministic, allocates no caller-owned memory,
// and never removes sparse points. `floor_value_n_dot_x` must use the supplied
// normal's sign. The output count includes certified and diagnostic walls.
//
// Return values intentionally reuse aether_planesweep_rc_t numeric values:
// 0 OK, 1 bad arguments, 4 output buffer too small, 5 internal failure.
int32_t aether_structural_fit_walls(
    const float* points_xyz,
    int32_t point_count,
    const double floor_normal_xyz[3],
    double floor_value_n_dot_x,
    const aether_structural_plane_fit_options_t* options,
    aether_structural_wall_t* out_walls,
    int32_t wall_capacity,
    int32_t* out_wall_count);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // AETHER_STRUCTURAL_PLANE_FIT_C_H
