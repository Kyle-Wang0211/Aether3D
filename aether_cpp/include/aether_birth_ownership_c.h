// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_BIRTH_OWNERSHIP_C_H
#define AETHER_BIRTH_OWNERSHIP_C_H

#include <stdint.h>

#include "aether_structural_plane_fit_c.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    AETHER_BIRTH_OWNERSHIP_OK = 0,
    AETHER_BIRTH_OWNERSHIP_ERR_BAD_ARGS = 1,
    AETHER_BIRTH_OWNERSHIP_ERR_UNSUPPORTED = 2,
    AETHER_BIRTH_OWNERSHIP_ERR_INTERNAL = 5,
} aether_birth_ownership_rc_t;

// A D candidate must be supported by both deterministic sparse partitions.
// The remaining partition stays blind during quality validation. Partitioning
// is lexicographic XYZ followed by rank modulo partition_count, matching the
// fixed research protocol exactly.
typedef struct {
    int32_t neighbors;
    int32_t partition_count;
    int32_t first_partition;
    int32_t second_partition;
    double maximum_nearest_m;
    double maximum_neighbor_radius_m;
    double maximum_neighbor_rms_m;
    double maximum_perpendicular_m;
} aether_local_manifold_options_t;

typedef struct aether_local_manifold_session aether_local_manifold_session_t;

// Result of the per-reference three-fold birth certificate.  `failed_fold_mask`
// uses bit N for the fold whose blind truth is deterministic sparse partition N.
// A zero-birth reference is valid and may be certified.  Counts describe the
// selected production fold before and after the certificate is applied.
typedef struct {
    uint32_t failed_fold_mask;
    int32_t pre_certificate_birth_count;
    int32_t blocked_birth_count;
    int32_t final_birth_count;
} aether_reference_birth_certificate_result_t;

// Finite floor selected by B's image-only candidate adjudication. The floor
// normal points upward and the two basis vectors bound the selected physical
// domain. `certified` means the selection, not merely the sparse proposal,
// passed B's decisive multi-view quality gate.
typedef struct {
    int32_t certified;
    double normal_xyz[3];
    double basis_u_xyz[3];
    double basis_v_xyz[3];
    double plane_value_n_dot_x;
    double bounds_u_m[2];
    double bounds_v_m[2];
} aether_finite_floor_domain_t;

void aether_local_manifold_options_default(
    aether_local_manifold_options_t* out_options);

// Builds the two immutable sparse-support indices once per capture. Original
// sparse points are copied for evidence lookup only and are never altered.
int32_t aether_local_manifold_session_create(
    const float* sparse_xyz,
    int32_t sparse_point_count,
    const aether_local_manifold_options_t* options,
    aether_local_manifold_session_t** out_session);

// Applies the two independent local tangent-plane gates. candidate_eligible is
// optional; when supplied, zero entries (for example B-owned finite wall
// domains) cannot acquire D point identity. Outputs are candidate-major.
int32_t aether_local_manifold_session_filter(
    const aether_local_manifold_session_t* session,
    const float* candidate_xyz,
    int32_t candidate_count,
    const uint8_t* candidate_eligible,
    uint8_t* out_first_support,
    uint8_t* out_second_support,
    uint8_t* out_birth,
    int32_t output_capacity);

// Applies the complete per-reference production certificate before any D
// candidate receives point identity.  The session must have been created with
// exactly three deterministic partitions.  For each fold, the other two
// partitions independently gate candidates and the blind partition measures
// exact nearest-3D error.  Median, p90, p95, maximum error and the fractions
// within 5/10/20 cm must all be non-regressing.  If any fold fails, every
// production-fold birth is cleared and reported as blocked.  `out_birth` is
// always initialized before validation and is candidate-major.
int32_t aether_local_manifold_session_filter_reference_certified(
    const aether_local_manifold_session_t* session,
    const float* candidate_xyz,
    int32_t candidate_count,
    const uint8_t* candidate_eligible,
    int32_t production_fold,
    uint8_t* out_birth,
    int32_t output_capacity,
    aether_reference_birth_certificate_result_t* out_result);

void aether_local_manifold_session_free(
    aether_local_manifold_session_t* session);

// Marks the finite domain owned by B's selected floor. Candidates within the
// positive-side slab, and every candidate below the floor inside that finite
// domain, are withheld from D before publication. This prevents both a nearby
// duplicate floor and an under-floor ghost layer from receiving D identity.
int32_t aether_filter_finite_floor_ownership(
    const float* candidate_xyz,
    int32_t candidate_count,
    const aether_finite_floor_domain_t* floor,
    double floor_slab_m,
    double domain_margin_m,
    uint8_t* out_owned,
    int32_t output_capacity);

// Marks the finite domains owned by certified B walls. This is a generation
// ownership gate: marked candidates are withheld from D before publication,
// not deleted from an already-generated point cloud.
int32_t aether_filter_finite_wall_ownership(
    const float* candidate_xyz,
    int32_t candidate_count,
    double floor_value_n_dot_x,
    const aether_structural_wall_t* walls,
    int32_t wall_count,
    double wall_slab_m,
    double domain_margin_m,
    uint8_t* out_owned,
    int32_t output_capacity);

const char* aether_birth_ownership_result_str(int32_t rc);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // AETHER_BIRTH_OWNERSHIP_C_H
