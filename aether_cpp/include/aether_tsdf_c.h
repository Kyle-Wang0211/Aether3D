// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
// Unified C API: TSDF + innovation modules + scheduler.

#ifndef AETHER_TSDF_C_H
#define AETHER_TSDF_C_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct aether_tsdf_volume aether_tsdf_volume_t;
typedef struct aether_coverage_estimator aether_coverage_estimator_t;
typedef struct aether_spam_protection aether_spam_protection_t;
typedef struct aether_token_bucket aether_token_bucket_t;
typedef struct aether_view_diversity_tracker aether_view_diversity_tracker_t;
typedef struct aether_admission_controller aether_admission_controller_t;
typedef struct aether_merkle_tree aether_merkle_tree_t;
typedef struct aether_f5_chain aether_f5_chain_t;
typedef struct aether_f6_rejector aether_f6_rejector_t;
typedef struct aether_gpu_scheduler aether_gpu_scheduler_t;
typedef struct aether_motion_analyzer aether_motion_analyzer_t;
typedef struct aether_photometric_checker aether_photometric_checker_t;
typedef struct aether_depth_filter aether_depth_filter_t;
typedef struct aether_thermal_engine aether_thermal_engine_t;
typedef struct aether_pose_stabilizer aether_pose_stabilizer_t;
typedef struct aether_capture_style_runtime aether_capture_style_runtime_t;
typedef struct aether_smart_smoother aether_smart_smoother_t;
typedef struct aether_flip_runtime aether_flip_runtime_t;
typedef struct aether_ripple_runtime aether_ripple_runtime_t;
typedef struct aether_f7_decoder aether_f7_decoder_t;
typedef struct aether_evidence_state_machine aether_evidence_state_machine_t;
typedef struct aether_f8_field aether_f8_field_t;
typedef struct aether_scaffold_patch_map aether_scaffold_patch_map_t;
typedef struct aether_mesh_extraction_scheduler aether_mesh_extraction_scheduler_t;
typedef struct aether_dgrut_selector aether_dgrut_selector_t;
typedef struct aether_frustum_culler aether_frustum_culler_t;
typedef struct aether_meshlet_builder aether_meshlet_builder_t;
typedef struct aether_two_pass_culler aether_two_pass_culler_t;
typedef struct aether_noise_aware_trainer aether_noise_aware_trainer_t;

typedef struct aether_float3 {
    float x;
    float y;
    float z;
} aether_float3_t;

typedef struct aether_scaffold_vertex {
    uint32_t id;
    aether_float3_t position;
} aether_scaffold_vertex_t;

typedef struct aether_scaffold_unit {
    uint64_t unit_id;
    uint32_t generation;
    uint32_t v0;
    uint32_t v1;
    uint32_t v2;
    float area;
    aether_float3_t normal;
    float confidence;
    uint32_t view_count;
    uint8_t lod_level;
    const char* patch_id;  // Optional input. Not owned by API.
} aether_scaffold_unit_t;

typedef struct aether_gaussian {
    uint32_t id;
    aether_float3_t position;
    aether_float3_t scale;
    float opacity;
    float sh_coeffs[16];
    uint64_t host_unit_id;
    uint32_t bind_generation;
    uint16_t observation_count;
    uint16_t patch_priority;
    uint32_t capture_sequence;
    uint64_t first_observed_frame_id;
    int64_t first_observed_ms;
    uint8_t flags;
    uint8_t lod_level;
    uint8_t binding_state;
    float uncertainty;
    const char* patch_id;  // Optional input. Not owned by API.
} aether_gaussian_t;

typedef struct aether_integration_input {
    const float* depth_data;
    int depth_width;
    int depth_height;
    const unsigned char* confidence_data;
    float voxel_size;
    float fx, fy, cx, cy;
    const float* view_matrix;
    double timestamp;
    int tracking_state;  // 2=normal, 1=limited, 0=not available
} aether_integration_input_t;

typedef struct aether_integration_result {
    int voxels_integrated;
    int blocks_updated;
    int success;  // 1=ok, 0=fail
    int skipped;  // 1=gate skipped
    int skip_reason;
} aether_integration_result_t;

typedef struct aether_external_voxel {
    uint16_t sdf_bits;
    uint8_t weight;
    uint8_t confidence;
} aether_external_voxel_t;

typedef struct aether_external_block {
    int32_t x;
    int32_t y;
    int32_t z;
    float voxel_size;
    uint32_t integration_generation;
    uint32_t mesh_generation;
    double last_observed_timestamp;
    aether_external_voxel_t* voxels;
    uint32_t voxel_count;
} aether_external_block_t;

enum {
    AETHER_TSDF_SKIP_NONE = 0,
    AETHER_TSDF_SKIP_TRACKING_LOST = 1,
    AETHER_TSDF_SKIP_POSE_TELEPORT = 2,
    AETHER_TSDF_SKIP_POSE_JITTER = 3,
    AETHER_TSDF_SKIP_THERMAL_THROTTLE = 4,
    AETHER_TSDF_SKIP_FRAME_TIMEOUT = 5,
    AETHER_TSDF_SKIP_LOW_VALID_PIXELS = 6,
    AETHER_TSDF_SKIP_MEMORY_PRESSURE = 7,
};

// Dempster-Shafer mass fusion.
typedef struct aether_ds_mass {
    double occupied;
    double free_mass;
    double unknown;
} aether_ds_mass_t;

typedef struct aether_ds_combine_result {
    aether_ds_mass_t mass;
    double conflict;
    int used_yager;  // 0/1
} aether_ds_combine_result_t;

int aether_ds_mass_sealed(
    const aether_ds_mass_t* input,
    aether_ds_mass_t* out_mass);
int aether_ds_combine_dempster(
    const aether_ds_mass_t* first,
    const aether_ds_mass_t* second,
    aether_ds_combine_result_t* out_result);
int aether_ds_combine_yager(
    const aether_ds_mass_t* first,
    const aether_ds_mass_t* second,
    aether_ds_mass_t* out_mass);
int aether_ds_combine_auto(
    const aether_ds_mass_t* first,
    const aether_ds_mass_t* second,
    aether_ds_mass_t* out_mass);
int aether_ds_discount(
    const aether_ds_mass_t* input,
    double reliability,
    aether_ds_mass_t* out_mass);
int aether_ds_from_delta_multiplier(
    double delta_multiplier,
    aether_ds_mass_t* out_mass);

// Coverage estimator.
typedef struct aether_coverage_cell_observation {
    uint8_t level;  // L0..L6
    double occupied;
    double free_mass;
    double unknown;
    double area_weight;
    int excluded;  // 0/1
    uint32_t view_count;
} aether_coverage_cell_observation_t;

typedef struct aether_coverage_estimator_config {
    double level_weights[7];
    double ema_alpha;
    double max_coverage_delta_per_sec;
    double view_diversity_boost;
    int use_custom_level_weights;  // 0 = keep built-in defaults
    int monotonic_mode;  // 1 = coverage can only increase (capture mode)
    int use_fisher_weights;       // 1 = Fisher I=n/(p(1-p)) weights (default)
    double fisher_normalization;  // Fisher I normalization ceiling
    double fisher_floor;          // Minimum Fisher weight
} aether_coverage_estimator_config_t;

typedef struct aether_coverage_result {
    double raw_coverage;
    double smoothed_coverage;
    double coverage;
    uint32_t breakdown_counts[7];
    double weighted_sum_components[7];
    uint64_t active_cell_count;
    double excluded_area_weight;
    int non_monotonic_time_count;
    double lyapunov_convergence;
    /* Information-theoretic extensions */
    double high_observation_ratio;    /* L5+ ratio (CRLB proxy) */
    double belief_coverage;           /* DS Belief lower bound */
    double plausibility_coverage;     /* DS Plausibility upper bound */
    double uncertainty_width;         /* Pl - Bel */
    double mean_fisher_info;          /* Mean Fisher information */
    double lyapunov_rate;             /* |dV/dt|/V convergence rate */
    /* PAC probability certificates */
    double pac_failure_bound;         /* Union bound: sum exp(-n*KL) */
    double pac_max_cell_risk;         /* Worst-case single cell risk */
    uint64_t pac_certified_cell_count; /* Cells with risk < 0.01 */
} aether_coverage_result_t;

int aether_coverage_estimator_default_config(
    aether_coverage_estimator_config_t* out_config);
int aether_coverage_estimator_create(
    const aether_coverage_estimator_config_t* config,
    aether_coverage_estimator_t** out_estimator);
int aether_coverage_estimator_destroy(aether_coverage_estimator_t* estimator);
int aether_coverage_estimator_reset(aether_coverage_estimator_t* estimator);
int aether_coverage_estimator_update(
    aether_coverage_estimator_t* estimator,
    const aether_coverage_cell_observation_t* cells,
    int cell_count,
    int64_t monotonic_timestamp_ms,
    aether_coverage_result_t* out_result);
int aether_coverage_estimator_last_coverage(
    const aether_coverage_estimator_t* estimator,
    double* out_coverage);
int aether_coverage_estimator_non_monotonic_count(
    const aether_coverage_estimator_t* estimator,
    int* out_count);

// Evidence admission primitives.
enum {
    AETHER_ADMISSION_REASON_ALLOWED = 0,
    AETHER_ADMISSION_REASON_TIME_DENSITY_SAME_PATCH = 1,
    AETHER_ADMISSION_REASON_TOKEN_BUCKET_LOW = 2,
    AETHER_ADMISSION_REASON_NOVELTY_LOW = 3,
    AETHER_ADMISSION_REASON_FREQUENCY_CAP = 4,
    AETHER_ADMISSION_REASON_CONFIRMED_SPAM = 5,
};

typedef struct aether_admission_decision {
    int allowed;  // 0/1
    double quality_scale;
    uint32_t reason_mask;
    int hard_blocked;  // 0/1
} aether_admission_decision_t;

int aether_spam_protection_create(aether_spam_protection_t** out_spam);
int aether_spam_protection_destroy(aether_spam_protection_t* spam);
int aether_spam_protection_reset(aether_spam_protection_t* spam);
int aether_spam_protection_should_allow_update(
    const aether_spam_protection_t* spam,
    const char* patch_id,
    int64_t timestamp_ms,
    int* out_allowed);
int aether_spam_protection_novelty_scale(
    const aether_spam_protection_t* spam,
    double raw_novelty,
    double* out_scale);
int aether_spam_protection_frequency_scale(
    aether_spam_protection_t* spam,
    const char* patch_id,
    int64_t timestamp_ms,
    double* out_scale);

int aether_token_bucket_create(aether_token_bucket_t** out_limiter);
int aether_token_bucket_destroy(aether_token_bucket_t* limiter);
int aether_token_bucket_reset(aether_token_bucket_t* limiter);
int aether_token_bucket_try_consume(
    aether_token_bucket_t* limiter,
    const char* patch_id,
    int64_t timestamp_ms,
    int* out_consumed);
int aether_token_bucket_available_tokens(
    aether_token_bucket_t* limiter,
    const char* patch_id,
    int64_t timestamp_ms,
    double* out_tokens);

int aether_view_diversity_create(aether_view_diversity_tracker_t** out_tracker);
int aether_view_diversity_destroy(aether_view_diversity_tracker_t* tracker);
int aether_view_diversity_reset(aether_view_diversity_tracker_t* tracker);
int aether_view_diversity_add_observation(
    aether_view_diversity_tracker_t* tracker,
    const char* patch_id,
    double view_angle_deg,
    int64_t timestamp_ms,
    double* out_diversity);
int aether_view_diversity_score(
    const aether_view_diversity_tracker_t* tracker,
    const char* patch_id,
    double* out_diversity);

int aether_admission_controller_create(aether_admission_controller_t** out_controller);
int aether_admission_controller_destroy(aether_admission_controller_t* controller);
int aether_admission_controller_reset(aether_admission_controller_t* controller);
int aether_admission_controller_check(
    aether_admission_controller_t* controller,
    const char* patch_id,
    double view_angle_deg,
    int64_t timestamp_ms,
    aether_admission_decision_t* out_decision);
int aether_admission_controller_check_confirmed_spam(
    const aether_admission_controller_t* controller,
    const char* patch_id,
    double spam_score,
    double threshold,
    aether_admission_decision_t* out_decision);

// PR1 admission strategy kernel (core policy path).
enum {
    AETHER_PR1_BUILD_MODE_NORMAL = 0,
    AETHER_PR1_BUILD_MODE_DAMPING = 1,
    AETHER_PR1_BUILD_MODE_SATURATED = 2,
};

enum {
    AETHER_PR1_CLASSIFICATION_ACCEPTED = 0,
    AETHER_PR1_CLASSIFICATION_REJECTED = 1,
    AETHER_PR1_CLASSIFICATION_DUPLICATE_REJECTED = 2,
};

enum {
    AETHER_PR1_REJECT_REASON_NONE = 0,
    AETHER_PR1_REJECT_REASON_LOW_GAIN_SOFT = 1,
    AETHER_PR1_REJECT_REASON_REDUNDANT_COVERAGE = 2,
    AETHER_PR1_REJECT_REASON_DUPLICATE = 3,
    AETHER_PR1_REJECT_REASON_HARD_CAP = 4,
};

enum {
    AETHER_PR1_GUIDANCE_NONE = 0,
    AETHER_PR1_GUIDANCE_HEAT_COOL_COVERAGE = 1,
    AETHER_PR1_GUIDANCE_DIRECTIONAL_AFFORDANCE = 2,
    AETHER_PR1_GUIDANCE_STATIC_OVERLAY = 3,
};

enum {
    AETHER_PR1_HARD_FUSE_NONE = 0,
    AETHER_PR1_HARD_FUSE_PATCHCOUNT_HARD = 1,
    AETHER_PR1_HARD_FUSE_EEB_HARD = 2,
};

typedef struct aether_pr1_admission_input {
    int is_duplicate;  // 0/1
    int current_mode;  // AETHER_PR1_BUILD_MODE_*
    int should_trigger_soft_limit;  // 0/1
    int hard_trigger;  // AETHER_PR1_HARD_FUSE_*
    double info_gain;
    double novelty;
    double ig_min_soft;
    double novelty_min_soft;
    double eeb_min_quantum;
} aether_pr1_admission_input_t;

typedef struct aether_pr1_admission_decision {
    int classification;  // AETHER_PR1_CLASSIFICATION_*
    int reason;  // AETHER_PR1_REJECT_REASON_*
    double eeb_delta;
    int build_mode;  // AETHER_PR1_BUILD_MODE_*
    int guidance_signal;  // AETHER_PR1_GUIDANCE_*
    int hard_fuse_trigger;  // AETHER_PR1_HARD_FUSE_*
} aether_pr1_admission_decision_t;

int aether_pr1_admission_evaluate(
    const aether_pr1_admission_input_t* input,
    aether_pr1_admission_decision_t* out_decision);

typedef struct aether_pr1_capacity_state_input {
    int patch_count_shadow;
    double eeb_remaining;
    int current_mode;  // AETHER_PR1_BUILD_MODE_*
    int saturated_latched;  // 0/1
    int soft_limit_patch_count;
    double soft_budget_threshold;
    int hard_limit_patch_count;
    double hard_budget_threshold;
} aether_pr1_capacity_state_input_t;

typedef struct aether_pr1_capacity_state_output {
    int should_trigger_soft_limit;  // 0/1
    int hard_trigger;  // AETHER_PR1_HARD_FUSE_*
    int next_mode;  // AETHER_PR1_BUILD_MODE_*
    int should_latch_saturated;  // 0/1
} aether_pr1_capacity_state_output_t;

int aether_pr1_capacity_state_step(
    const aether_pr1_capacity_state_input_t* input,
    aether_pr1_capacity_state_output_t* out_state);

typedef struct aether_pr1_patch_descriptor {
    float pose_x;
    float pose_y;
    float pose_z;
    int coverage_x;
    int coverage_y;
    float radiance_x;
    float radiance_y;
    float radiance_z;
} aether_pr1_patch_descriptor_t;

enum {
    AETHER_PR1_INFO_GAIN_STRATEGY_LEGACY = 0,
    AETHER_PR1_INFO_GAIN_STRATEGY_ENTROPY_FRONTIER = 1,
    AETHER_PR1_INFO_GAIN_STRATEGY_HYBRID_CROSSCHECK = 2,
};

enum {
    AETHER_PR1_NOVELTY_STRATEGY_LEGACY = 0,
    AETHER_PR1_NOVELTY_STRATEGY_KERNEL_ROBUST = 1,
    AETHER_PR1_NOVELTY_STRATEGY_HYBRID_CROSSCHECK = 2,
};

typedef struct aether_pr1_info_gain_config {
    int info_gain_strategy;  // AETHER_PR1_INFO_GAIN_STRATEGY_*
    int novelty_strategy;  // AETHER_PR1_NOVELTY_STRATEGY_*
    double state_gain_uncovered;
    double state_gain_gray;
    double state_gain_white;
    double state_weight;
    double frontier_weight;
    double entropy_weight;
    double rarity_weight;
    double pose_eps;
    double robust_quantile;
    double robustness_scale;
    double hybrid_agreement_tolerance;
    double hybrid_high_weight;
} aether_pr1_info_gain_config_t;

int aether_pr1_info_gain_default_config(aether_pr1_info_gain_config_t* out_config);

int aether_pr1_compute_info_gain(
    const aether_pr1_patch_descriptor_t* patch,
    const uint8_t* coverage_grid_states,
    int grid_size,
    double* out_info_gain);

int aether_pr1_compute_info_gain_with_config(
    const aether_pr1_patch_descriptor_t* patch,
    const uint8_t* coverage_grid_states,
    int grid_size,
    const aether_pr1_info_gain_config_t* config,
    double* out_info_gain);

int aether_pr1_compute_novelty(
    const aether_pr1_patch_descriptor_t* patch,
    const aether_pr1_patch_descriptor_t* existing_patches,
    int existing_count,
    double pose_eps,
    double* out_novelty);

int aether_pr1_compute_novelty_with_config(
    const aether_pr1_patch_descriptor_t* patch,
    const aether_pr1_patch_descriptor_t* existing_patches,
    int existing_count,
    const aether_pr1_info_gain_config_t* config,
    double* out_novelty);

// SHA256 primitives.
enum {
    AETHER_SHA256_DIGEST_BYTES = 32,
    AETHER_SHA256_HEX_BYTES = 65,
};

int aether_sha256(
    const uint8_t* data,
    int data_len,
    uint8_t out_digest[AETHER_SHA256_DIGEST_BYTES]);
int aether_sha256_hex(
    const uint8_t* data,
    int data_len,
    char out_hex[AETHER_SHA256_HEX_BYTES]);

// Deterministic EvidenceState canonical JSON bridge.
typedef struct aether_evidence_patch_snapshot {
    const char* patch_id;  // Required.
    double evidence;
    int64_t last_update_ms;
    int observation_count;
    const char* best_frame_id;  // Optional.
    int error_count;
    int error_streak;
    int has_last_good_update_ms;  // 0/1
    int64_t last_good_update_ms;
} aether_evidence_patch_snapshot_t;

typedef struct aether_evidence_state_input {
    const aether_evidence_patch_snapshot_t* patches;
    int patch_count;
    double gate_display;
    double soft_display;
    double last_total_display;
    const char* schema_version;  // Required.
    int64_t exported_at_ms;
} aether_evidence_state_input_t;

int aether_evidence_state_encode_canonical_json(
    const aether_evidence_state_input_t* input,
    char* out_json,
    int* inout_json_capacity);  // bytes including null terminator
int aether_evidence_state_canonical_sha256_hex(
    const aether_evidence_state_input_t* input,
    char out_hex[AETHER_SHA256_HEX_BYTES]);

// RFC9162 Merkle tree bridge.
enum {
    AETHER_MERKLE_HASH_BYTES = 32,
    AETHER_MERKLE_MAX_INCLUSION_HASHES = 20,
    AETHER_MERKLE_MAX_CONSISTENCY_HASHES = 40,
};

typedef struct aether_merkle_inclusion_proof {
    uint64_t tree_size;
    uint64_t leaf_index;
    uint32_t path_length;
    uint8_t leaf_hash[AETHER_MERKLE_HASH_BYTES];
    uint8_t path_hashes[AETHER_MERKLE_MAX_INCLUSION_HASHES * AETHER_MERKLE_HASH_BYTES];
} aether_merkle_inclusion_proof_t;

typedef struct aether_merkle_consistency_proof {
    uint64_t first_tree_size;
    uint64_t second_tree_size;
    uint32_t path_length;
    uint8_t path_hashes[AETHER_MERKLE_MAX_CONSISTENCY_HASHES * AETHER_MERKLE_HASH_BYTES];
} aether_merkle_consistency_proof_t;

int aether_merkle_hash_leaf(
    const uint8_t* data,
    int data_len,
    uint8_t out_hash[AETHER_MERKLE_HASH_BYTES]);
int aether_merkle_hash_nodes(
    const uint8_t left_hash[AETHER_MERKLE_HASH_BYTES],
    const uint8_t right_hash[AETHER_MERKLE_HASH_BYTES],
    uint8_t out_hash[AETHER_MERKLE_HASH_BYTES]);
int aether_merkle_empty_root(uint8_t out_hash[AETHER_MERKLE_HASH_BYTES]);

int aether_merkle_tree_create(aether_merkle_tree_t** out_tree);
int aether_merkle_tree_destroy(aether_merkle_tree_t* tree);
int aether_merkle_tree_reset(aether_merkle_tree_t* tree);
int aether_merkle_tree_size(const aether_merkle_tree_t* tree, uint64_t* out_size);
int aether_merkle_tree_root_hash(
    const aether_merkle_tree_t* tree,
    uint8_t out_hash[AETHER_MERKLE_HASH_BYTES]);
int aether_merkle_tree_append(
    aether_merkle_tree_t* tree,
    const uint8_t* leaf_data,
    int leaf_data_len);
int aether_merkle_tree_append_hash(
    aether_merkle_tree_t* tree,
    const uint8_t leaf_hash[AETHER_MERKLE_HASH_BYTES]);
int aether_merkle_tree_root_at_size(
    const aether_merkle_tree_t* tree,
    uint64_t tree_size,
    uint8_t out_hash[AETHER_MERKLE_HASH_BYTES]);
int aether_merkle_tree_inclusion_proof(
    const aether_merkle_tree_t* tree,
    uint64_t leaf_index,
    aether_merkle_inclusion_proof_t* out_proof);
int aether_merkle_tree_consistency_proof(
    const aether_merkle_tree_t* tree,
    uint64_t first_size,
    uint64_t second_size,
    aether_merkle_consistency_proof_t* out_proof);
int aether_merkle_verify_inclusion(
    const aether_merkle_inclusion_proof_t* proof,
    const uint8_t expected_root[AETHER_MERKLE_HASH_BYTES],
    int* out_valid);
int aether_merkle_verify_inclusion_with_leaf_data(
    const aether_merkle_inclusion_proof_t* proof,
    const uint8_t* leaf_data,
    int leaf_data_len,
    const uint8_t expected_root[AETHER_MERKLE_HASH_BYTES],
    int* out_valid);
int aether_merkle_verify_consistency(
    const aether_merkle_consistency_proof_t* proof,
    const uint8_t first_root[AETHER_MERKLE_HASH_BYTES],
    const uint8_t second_root[AETHER_MERKLE_HASH_BYTES],
    int* out_valid);

// Tri/Tet consistency.
enum {
    AETHER_TRI_TET_CLASS_MEASURED = 0,
    AETHER_TRI_TET_CLASS_ESTIMATED = 1,
    AETHER_TRI_TET_CLASS_UNKNOWN = 2,
};

typedef struct aether_tri_tet_triangle {
    aether_float3_t a;
    aether_float3_t b;
    aether_float3_t c;
} aether_tri_tet_triangle_t;

typedef struct aether_tri_tet_vertex {
    int32_t index;
    aether_float3_t position;
    int32_t view_count;
} aether_tri_tet_vertex_t;

typedef struct aether_tri_tet_tetrahedron {
    int32_t id;
    int32_t v0;
    int32_t v1;
    int32_t v2;
    int32_t v3;
} aether_tri_tet_tetrahedron_t;

typedef struct aether_tri_tet_config {
    int32_t measured_min_view_count;
    int32_t estimated_min_view_count;
    float max_triangle_to_tet_distance;
} aether_tri_tet_config_t;

typedef struct aether_tri_tet_binding {
    int32_t triangle_index;
    int32_t tetrahedron_id;
    uint8_t classification;  // AETHER_TRI_TET_CLASS_*
    float tri_to_tet_distance;
    int32_t min_tet_view_count;
} aether_tri_tet_binding_t;

typedef struct aether_tri_tet_report {
    float combined_score;
    int32_t measured_count;
    int32_t estimated_count;
    int32_t unknown_count;
} aether_tri_tet_report_t;

// Writes Kuhn 5-tet table as 20 ints:
// [tet0_v0,tet0_v1,tet0_v2,tet0_v3,...].
int aether_tri_tet_kuhn5_table(int parity, int out_vertices[20]);
int aether_tri_tet_evaluate(
    const aether_tri_tet_triangle_t* triangles,
    int triangle_count,
    const aether_tri_tet_vertex_t* vertices,
    int vertex_count,
    const aether_tri_tet_tetrahedron_t* tetrahedra,
    int tetrahedron_count,
    const aether_tri_tet_config_t* config,
    aether_tri_tet_binding_t* out_bindings,
    int binding_capacity,
    aether_tri_tet_report_t* out_report);
int aether_tritet_score(
    const aether_tri_tet_triangle_t* triangles,
    int triangle_count,
    const aether_tri_tet_vertex_t* vertices,
    int vertex_count,
    const aether_tri_tet_tetrahedron_t* tetrahedra,
    int tetrahedron_count,
    const aether_tri_tet_config_t* config,
    aether_tri_tet_binding_t* out_bindings,
    int binding_capacity,
    aether_tri_tet_report_t* out_report);

// Spatial quantizer / Morton.
typedef struct aether_quantized_position {
    int32_t x;
    int32_t y;
    int32_t z;
} aether_quantized_position_t;

int aether_spatial_quantize_world_position(
    double world_x,
    double world_y,
    double world_z,
    double origin_x,
    double origin_y,
    double origin_z,
    double cell_size_meters,
    aether_quantized_position_t* out_position);
int aether_spatial_morton_encode_21bit(
    int32_t x,
    int32_t y,
    int32_t z,
    uint64_t* out_code);
int aether_spatial_morton_decode_21bit(
    uint64_t code,
    aether_quantized_position_t* out_position);
int aether_spatial_dequantize_world_position(
    const aether_quantized_position_t* position,
    double origin_x,
    double origin_y,
    double origin_z,
    double cell_size_meters,
    double* out_world_x,
    double* out_world_y,
    double* out_world_z);

// M03 spatial hash adjacency.
typedef struct aether_scan_triangle {
    aether_float3_t a;
    aether_float3_t b;
    aether_float3_t c;
} aether_scan_triangle_t;

int aether_spatial_adjacency_build(
    const aether_scan_triangle_t* triangles,
    int triangle_count,
    float cell_size,
    float epsilon,
    uint32_t* out_offsets,
    uint32_t* out_neighbors,
    int* inout_neighbor_count);
int aether_spatial_adjacency_bfs(
    const uint32_t* offsets,
    const uint32_t* neighbors,
    int triangle_count,
    const uint32_t* sources,
    int source_count,
    int max_hops,
    int32_t* out_distances);

// M05 frame-quality kernels.
typedef struct aether_motion_result {
    double score;
    int is_fast_pan;
    int is_hand_shake;
} aether_motion_result_t;

int aether_motion_analyzer_create(aether_motion_analyzer_t** out_analyzer);
int aether_motion_analyzer_destroy(aether_motion_analyzer_t* analyzer);
int aether_motion_analyzer_reset(aether_motion_analyzer_t* analyzer);
int aether_motion_analyzer_analyze(
    aether_motion_analyzer_t* analyzer,
    const uint8_t* image,
    int width,
    int height,
    aether_motion_result_t* out_result);
int aether_motion_analyzer_quality_metric(
    const aether_motion_analyzer_t* analyzer,
    int quality_level,
    double* out_value,
    double* out_confidence);
int aether_laplacian_variance_compute(
    const uint8_t* image,
    int width,
    int height,
    int row_bytes,
    double* out_variance);
int aether_tenengrad_detect(
    int quality_level,
    double tenengrad_threshold,
    double* out_value,
    double* out_confidence,
    double* out_roi_coverage,
    int* out_skipped);
int aether_tenengrad_compute(
    const uint8_t* image,
    int width,
    int height,
    int row_bytes,
    int quality_level,
    double tenengrad_threshold,
    double* out_value,
    double* out_confidence,
    double* out_roi_coverage,
    int* out_skipped);

typedef struct aether_frame_quality_result {
    double laplacian_variance;
    double tenengrad_score;
    double motion_score;
    int is_fast_pan;
    int is_hand_shake;
    int should_reject;
} aether_frame_quality_result_t;

int aether_frame_quality_eval(
    aether_motion_analyzer_t* analyzer,
    const uint8_t* image,
    int width,
    int height,
    int row_bytes,
    int quality_level,
    double tenengrad_threshold,
    aether_frame_quality_result_t* out_result);

// M05.1 pure-vision cross-validation and gate kernels.
enum {
    AETHER_CROSS_VALIDATION_KEEP = 0,
    AETHER_CROSS_VALIDATION_DOWNGRADE = 1,
    AETHER_CROSS_VALIDATION_REJECT = 2,
};

enum {
    AETHER_CROSS_VALIDATION_REASON_OUTLIER_BOTH_INLIER = 0,
    AETHER_CROSS_VALIDATION_REASON_OUTLIER_BOTH_REJECT = 1,
    AETHER_CROSS_VALIDATION_REASON_OUTLIER_DISAGREEMENT_DOWNGRADE = 2,
    AETHER_CROSS_VALIDATION_REASON_CALIBRATION_BOTH_PASS = 3,
    AETHER_CROSS_VALIDATION_REASON_CALIBRATION_BOTH_FAIL = 4,
    AETHER_CROSS_VALIDATION_REASON_CALIBRATION_DISAGREEMENT_OR_DIVERGENCE = 5,
};

typedef struct aether_outlier_cross_validation_input {
    int rule_inlier;
    double ml_inlier_score;
    double ml_inlier_threshold;
} aether_outlier_cross_validation_input_t;

typedef struct aether_calibration_cross_validation_input {
    double baseline_error_cm;
    double ml_error_cm;
    double max_allowed_error_cm;
    double max_divergence_cm;
} aether_calibration_cross_validation_input_t;

typedef struct aether_cross_validation_outcome {
    int decision;
    int reason_code;
} aether_cross_validation_outcome_t;

int aether_cross_validation_evaluate_outlier(
    const aether_outlier_cross_validation_input_t* input,
    aether_cross_validation_outcome_t* out_outcome);
int aether_cross_validation_evaluate_calibration(
    const aether_calibration_cross_validation_input_t* input,
    aether_cross_validation_outcome_t* out_outcome);

enum {
    AETHER_PURE_VISION_GATE_BASELINE_PIXELS = 0,
    AETHER_PURE_VISION_GATE_BLUR_LAPLACIAN = 1,
    AETHER_PURE_VISION_GATE_ORB_FEATURE_COUNT = 2,
    AETHER_PURE_VISION_GATE_PARALLAX_RATIO = 3,
    AETHER_PURE_VISION_GATE_DEPTH_SIGMA = 4,
    AETHER_PURE_VISION_GATE_CLOSURE_RATIO = 5,
    AETHER_PURE_VISION_GATE_UNKNOWN_VOXEL_RATIO = 6,
    AETHER_PURE_VISION_GATE_THERMAL_CELSIUS = 7,
    AETHER_PURE_VISION_GATE_COUNT = 8,
};

typedef struct aether_pure_vision_runtime_metrics {
    double baseline_pixels;
    double blur_laplacian;
    int32_t orb_features;
    double parallax_ratio;
    double depth_sigma_meters;
    double closure_ratio;
    double unknown_voxel_ratio;
    double thermal_celsius;
} aether_pure_vision_runtime_metrics_t;

typedef struct aether_pure_vision_gate_thresholds {
    double min_baseline_pixels;
    double min_blur_laplacian;
    int32_t min_orb_features;
    double min_parallax_ratio;
    double max_depth_sigma_meters;
    double min_closure_ratio;
    double max_unknown_voxel_ratio;
    double max_thermal_celsius;
} aether_pure_vision_gate_thresholds_t;

typedef struct aether_pure_vision_gate_result {
    int gate_id;
    int passed;
    double observed;
    double threshold;
    int comparator;  // 0 => >=, 1 => <=
} aether_pure_vision_gate_result_t;

int aether_pure_vision_default_gate_thresholds(aether_pure_vision_gate_thresholds_t* out_thresholds);
int aether_pure_vision_evaluate_gates(
    const aether_pure_vision_runtime_metrics_t* metrics,
    const aether_pure_vision_gate_thresholds_t* thresholds_or_null,
    aether_pure_vision_gate_result_t* out_results,
    int* out_result_count);
int aether_pure_vision_failed_gate_ids(
    const aether_pure_vision_runtime_metrics_t* metrics,
    const aether_pure_vision_gate_thresholds_t* thresholds_or_null,
    int* out_gate_ids,
    int* inout_gate_count);

// M05.2 zero-fabrication policy and geometry ML fusion.
enum {
    AETHER_ZERO_FAB_MODE_FORENSIC_STRICT = 0,
    AETHER_ZERO_FAB_MODE_RESEARCH_RELAXED = 1,
};

enum {
    AETHER_ZERO_FAB_ACTION_CALIBRATION_CORRECTION = 0,
    AETHER_ZERO_FAB_ACTION_MULTI_VIEW_DENOISE = 1,
    AETHER_ZERO_FAB_ACTION_OUTLIER_REJECTION = 2,
    AETHER_ZERO_FAB_ACTION_CONFIDENCE_ESTIMATION = 3,
    AETHER_ZERO_FAB_ACTION_UNCERTAINTY_ESTIMATION = 4,
    AETHER_ZERO_FAB_ACTION_TEXTURE_INPAINT = 5,
    AETHER_ZERO_FAB_ACTION_HOLE_FILLING = 6,
    AETHER_ZERO_FAB_ACTION_GEOMETRY_COMPLETION = 7,
    AETHER_ZERO_FAB_ACTION_UNKNOWN_REGION_GROWTH = 8,
};

enum {
    AETHER_ZERO_FAB_CONFIDENCE_MEASURED = 0,
    AETHER_ZERO_FAB_CONFIDENCE_ESTIMATED = 1,
    AETHER_ZERO_FAB_CONFIDENCE_UNKNOWN = 2,
};

enum {
    AETHER_ZERO_FAB_SEVERITY_INFO = 0,
    AETHER_ZERO_FAB_SEVERITY_WARN = 1,
    AETHER_ZERO_FAB_SEVERITY_BLOCK = 2,
};

enum {
    AETHER_ZERO_FAB_REASON_BLOCK_GENERATIVE_ACTION = 0,
    AETHER_ZERO_FAB_REASON_BLOCK_UNKNOWN_GROWTH = 1,
    AETHER_ZERO_FAB_REASON_ALLOW_OBSERVED_GROWTH = 2,
    AETHER_ZERO_FAB_REASON_BLOCK_COORDINATE_REWRITE = 3,
    AETHER_ZERO_FAB_REASON_DENOISE_DISPLACEMENT_EXCEEDS_POLICY = 4,
    AETHER_ZERO_FAB_REASON_ALLOW_DENOISE = 5,
    AETHER_ZERO_FAB_REASON_ALLOW_OUTLIER_REJECTION = 6,
    AETHER_ZERO_FAB_REASON_ALLOW_NON_GENERATIVE_CALIBRATION = 7,
};

typedef struct aether_zero_fabrication_context {
    int confidence_class;
    int has_direct_observation;
    float requested_point_displacement_meters;
    int requested_new_geometry_count;
} aether_zero_fabrication_context_t;

typedef struct aether_zero_fabrication_decision {
    int allowed;
    int reason_code;
    int severity;
} aether_zero_fabrication_decision_t;

int aether_zero_fabrication_evaluate(
    int mode,
    float max_denoise_displacement_meters,
    int action,
    const aether_zero_fabrication_context_t* context,
    aether_zero_fabrication_decision_t* out_decision);

enum {
    AETHER_GEOMETRY_ML_REASON_TRI_TET_MEASURED_RATIO_LOW = 0,
    AETHER_GEOMETRY_ML_REASON_CROSS_VALIDATION_KEEP_RATIO_LOW = 1,
    AETHER_GEOMETRY_ML_REASON_CROSS_VALIDATION_REJECT_PRESENT = 2,
    AETHER_GEOMETRY_ML_REASON_CAPTURE_MOTION_EXCEEDED = 3,
    AETHER_GEOMETRY_ML_REASON_CAPTURE_EXPOSURE_PENALTY_EXCEEDED = 4,
    AETHER_GEOMETRY_ML_REASON_EVIDENCE_COVERAGE_LOW = 5,
    AETHER_GEOMETRY_ML_REASON_EVIDENCE_INVARIANT_VIOLATION_EXCEEDED = 6,
    AETHER_GEOMETRY_ML_REASON_EVIDENCE_REPLAY_STABILITY_LOW = 7,
    AETHER_GEOMETRY_ML_REASON_EVIDENCE_TRI_TET_BINDING_COVERAGE_LOW = 8,
    AETHER_GEOMETRY_ML_REASON_EVIDENCE_MERKLE_COVERAGE_LOW = 9,
    AETHER_GEOMETRY_ML_REASON_EVIDENCE_OCCLUSION_EXCLUDED_RATIO_HIGH = 10,
    AETHER_GEOMETRY_ML_REASON_EVIDENCE_PROVENANCE_GAP_EXCEEDED = 11,
    AETHER_GEOMETRY_ML_REASON_TRANSPORT_LOSS_EXCEEDED = 12,
    AETHER_GEOMETRY_ML_REASON_TRANSPORT_RTT_EXCEEDED = 13,
    AETHER_GEOMETRY_ML_REASON_UPLOAD_BYZANTINE_COVERAGE_LOW = 14,
    AETHER_GEOMETRY_ML_REASON_UPLOAD_MERKLE_PROOF_SUCCESS_LOW = 15,
    AETHER_GEOMETRY_ML_REASON_UPLOAD_POP_SUCCESS_LOW = 16,
    AETHER_GEOMETRY_ML_REASON_UPLOAD_HMAC_MISMATCH_HIGH = 17,
    AETHER_GEOMETRY_ML_REASON_UPLOAD_CIRCUIT_BREAKER_OPEN_HIGH = 18,
    AETHER_GEOMETRY_ML_REASON_UPLOAD_RETRY_EXHAUSTION_HIGH = 19,
    AETHER_GEOMETRY_ML_REASON_UPLOAD_RESUME_CORRUPTION_HIGH = 20,
    AETHER_GEOMETRY_ML_REASON_SECURITY_CERT_PIN_MISMATCH_EXCEEDED = 21,
    AETHER_GEOMETRY_ML_REASON_SECURITY_REQUEST_SIGNER_VALID_RATE_LOW = 22,
    AETHER_GEOMETRY_ML_REASON_SECURITY_PENALTY_EXCEEDED = 23,
    AETHER_GEOMETRY_ML_REASON_FUSION_SCORE_LOW = 24,
    AETHER_GEOMETRY_ML_REASON_RISK_SCORE_HIGH = 25,
    AETHER_GEOMETRY_ML_REASON_CROSS_VALIDATION_SUPPORT_LOW = 26,
    AETHER_GEOMETRY_ML_REASON_EVIDENCE_PIZ_PERSISTENCE_EXCEEDED = 27,
    AETHER_GEOMETRY_ML_REASON_EVIDENCE_TRI_TET_BINDING_INCONSISTENT = 28,
    AETHER_GEOMETRY_ML_REASON_EVIDENCE_REPLAY_CV_INCONSISTENT = 29,
    AETHER_GEOMETRY_ML_REASON_UPLOAD_STRESS_COMPOUND_HIGH = 30,
    AETHER_GEOMETRY_ML_REASON_INTERDOMAIN_DIVERGENCE_HIGH = 31,
    AETHER_GEOMETRY_ML_REASON_SECURITY_TRANSPORT_TAMPER_CHAIN = 32,
    AETHER_GEOMETRY_ML_REASON_SECURITY_BOOT_CHAIN_FAILED = 33,
    AETHER_GEOMETRY_ML_REASON_MATURITY_LOW = 34,
    AETHER_GEOMETRY_ML_REASON_SCORE_LOW = 35,
    AETHER_GEOMETRY_ML_REASON_RISK_HIGH = 36,
    AETHER_GEOMETRY_ML_REASON_COUNT = 37,
};

typedef struct aether_geometry_ml_tri_tet_report {
    int has_report;
    float combined_score;
    int32_t measured_count;
    int32_t estimated_count;
    int32_t unknown_count;
} aether_geometry_ml_tri_tet_report_t;

typedef struct aether_geometry_ml_cross_validation_stats {
    int32_t keep_count;
    int32_t downgrade_count;
    int32_t reject_count;
} aether_geometry_ml_cross_validation_stats_t;

typedef struct aether_geometry_ml_capture_signals {
    double motion_score;
    double overexposure_ratio;
    double underexposure_ratio;
    int has_large_blown_region;
} aether_geometry_ml_capture_signals_t;

typedef struct aether_geometry_ml_evidence_signals {
    double coverage_score;
    double soft_evidence_score;
    int32_t persistent_piz_region_count;
    int32_t invariant_violation_count;
    double replay_stable_rate;
    double tri_tet_binding_coverage;
    double merkle_proof_coverage;
    double occlusion_excluded_area_ratio;
    int32_t provenance_gap_count;
} aether_geometry_ml_evidence_signals_t;

typedef struct aether_geometry_ml_transport_signals {
    double bandwidth_mbps;
    double rtt_ms;
    double loss_rate;
    int64_t chunk_size_bytes;
    double dedup_savings_ratio;
    double compression_savings_ratio;
    double byzantine_coverage;
    double merkle_proof_success_rate;
    double proof_of_possession_success_rate;
    double chunk_hmac_mismatch_rate;
    double circuit_breaker_open_ratio;
    double retry_exhaustion_rate;
    double resume_corruption_rate;
} aether_geometry_ml_transport_signals_t;

typedef struct aether_geometry_ml_security_signals {
    int code_signature_valid;
    int runtime_integrity_valid;
    int telemetry_hmac_valid;
    int debugger_detected;
    int environment_tampered;
    int32_t certificate_pin_mismatch_count;
    int boot_chain_validated;
    double request_signer_valid_rate;
    int secure_enclave_available;
} aether_geometry_ml_security_signals_t;

typedef struct aether_geometry_ml_thresholds {
    double min_fusion_score;
    double max_risk_score;
    double min_tri_tet_measured_ratio;
    double min_cross_validation_keep_ratio;
    double max_motion_score;
    double max_exposure_penalty;
    double min_coverage_score;
    int32_t max_persistent_piz_regions;
    int32_t max_evidence_invariant_violations;
    double min_evidence_replay_stable_rate;
    double min_tri_tet_binding_coverage;
    double min_evidence_merkle_proof_coverage;
    double max_evidence_occlusion_excluded_ratio;
    int32_t max_evidence_provenance_gap_count;
    double max_upload_loss_rate;
    double max_upload_rtt_ms;
    double min_upload_byzantine_coverage;
    double min_upload_merkle_proof_success_rate;
    double min_upload_pop_success_rate;
    double max_upload_hmac_mismatch_rate;
    double max_upload_circuit_breaker_open_ratio;
    double max_upload_retry_exhaustion_rate;
    double max_upload_resume_corruption_rate;
    int32_t max_certificate_pin_mismatch_count;
    double min_request_signer_valid_rate;
    double max_security_penalty;
} aether_geometry_ml_thresholds_t;

typedef struct aether_geometry_ml_weights {
    double geometry;
    double cross_validation;
    double capture;
    double evidence;
    double transport;
    double security;
} aether_geometry_ml_weights_t;

typedef struct aether_upload_cdc_thresholds {
    int32_t min_chunk_size;
    int32_t avg_chunk_size;
    int32_t max_chunk_size;
    double dedup_min_savings_ratio;
    double compression_min_savings_ratio;
} aether_upload_cdc_thresholds_t;

typedef struct aether_geometry_ml_component_scores {
    double geometry;
    double cross_validation;
    double capture;
    double evidence;
    double transport;
    double security;
} aether_geometry_ml_component_scores_t;

typedef struct aether_geometry_ml_result {
    int passes;
    double fusion_score;
    double risk_score;
    double security_penalty;
    double tri_tet_measured_ratio;
    double tri_tet_unknown_ratio;
    double cross_validation_keep_ratio;
    double capture_exposure_penalty;
    aether_geometry_ml_component_scores_t component_scores;
    aether_geometry_ml_cross_validation_stats_t cross_validation_stats;
    uint64_t reason_mask;
} aether_geometry_ml_result_t;

int aether_geometry_ml_evaluate(
    const aether_pure_vision_runtime_metrics_t* runtime_metrics,
    const aether_geometry_ml_tri_tet_report_t* tri_tet_report_or_null,
    const aether_geometry_ml_cross_validation_stats_t* cross_validation_stats,
    const aether_geometry_ml_capture_signals_t* capture_signals,
    const aether_geometry_ml_evidence_signals_t* evidence_signals,
    const aether_geometry_ml_transport_signals_t* transport_signals,
    const aether_geometry_ml_security_signals_t* security_signals,
    const aether_geometry_ml_thresholds_t* thresholds,
    const aether_geometry_ml_weights_t* weights,
    const aether_upload_cdc_thresholds_t* upload_thresholds,
    aether_geometry_ml_result_t* out_result);

// M05.3 patch display and smart smoother kernels.
typedef struct aether_patch_display_kernel_config {
    double patch_display_alpha;
    double patch_display_locked_acceleration;
    double color_evidence_local_weight;
    double color_evidence_global_weight;
    double ghost_recovery_acceleration;
} aether_patch_display_kernel_config_t;

typedef struct aether_patch_display_step_result {
    double display;
    double ema;
    double color_evidence;
    int used_ghost_warmstart;
} aether_patch_display_step_result_t;

int aether_patch_display_step(
    double previous_display,
    double previous_ema,
    int observation_count,
    double target,
    int is_locked,
    const aether_patch_display_kernel_config_t* config_or_null,
    aether_patch_display_step_result_t* out_result);
int aether_patch_color_evidence(
    double local_display,
    double global_display,
    const aether_patch_display_kernel_config_t* config_or_null,
    double* out_color_evidence);

typedef struct aether_smart_smoother_config {
    int32_t window_size;
    double jitter_band;
    double anti_boost_factor;
    double normal_improve_factor;
    double degrade_factor;
    int32_t max_consecutive_invalid;
    double worst_case_fallback;
    int capture_mode;
} aether_smart_smoother_config_t;

int aether_smart_smoother_create(
    const aether_smart_smoother_config_t* config_or_null,
    aether_smart_smoother_t** out_smoother);
int aether_smart_smoother_destroy(aether_smart_smoother_t* smoother);
int aether_smart_smoother_reset(aether_smart_smoother_t* smoother);
int aether_smart_smoother_add(
    aether_smart_smoother_t* smoother,
    double value,
    double* out_smoothed);

// M05.4 persistent visual style (non-rollback).
typedef struct aether_visual_style_state_input {
    int has_previous;
    int is_frozen;
    float previous_display;
    float previous_metallic;
    float previous_roughness;
    float previous_thickness;
    float current_display;
    float current_metallic;
    float current_roughness;
    float current_thickness;
    float smoothing_alpha;
    float freeze_threshold;
    float min_thickness;
    float max_thickness;
} aether_visual_style_state_input_t;

typedef struct aether_visual_style_state_output {
    float metallic;
    float roughness;
    float thickness;
    int should_freeze;
} aether_visual_style_state_output_t;

typedef struct aether_border_style_state_input {
    int has_previous;
    int is_frozen;
    float previous_display;
    float previous_width;
    float current_display;
    float current_width;
    float freeze_threshold;
    float min_width;
    float max_width;
} aether_border_style_state_input_t;

typedef struct aether_border_style_state_output {
    float width;
    int should_freeze;
} aether_border_style_state_output_t;

int aether_resolve_visual_style_state(
    const aether_visual_style_state_input_t* input,
    aether_visual_style_state_output_t* out_state);
int aether_resolve_border_style_state(
    const aether_border_style_state_input_t* input,
    aether_border_style_state_output_t* out_state);
int aether_resolve_visual_style_state_batch(
    const aether_visual_style_state_input_t* inputs,
    int input_count,
    aether_visual_style_state_output_t* out_states);
int aether_resolve_border_style_state_batch(
    const aether_border_style_state_input_t* inputs,
    int input_count,
    aether_border_style_state_output_t* out_states);

typedef struct aether_capture_style_runtime_config {
    float smoothing_alpha;
    float freeze_threshold;
    float min_thickness;
    float max_thickness;
    float min_border_width;
    float max_border_width;
    float min_area_sq_m;
    float min_median_area_sq_m;
} aether_capture_style_runtime_config_t;

typedef struct aether_capture_style_input {
    uint64_t patch_key;
    float display;
    float area_sq_m;
} aether_capture_style_input_t;

typedef struct aether_capture_style_output {
    float resolved_display;
    float metallic;
    float roughness;
    float thickness;
    float border_width;
    float grayscale;
    int visual_frozen;
    int border_frozen;
    int visual_should_freeze;
    int border_should_freeze;
} aether_capture_style_output_t;

int aether_capture_style_runtime_default_config(
    aether_capture_style_runtime_config_t* out_config);
int aether_capture_style_runtime_create(
    const aether_capture_style_runtime_config_t* config_or_null,
    aether_capture_style_runtime_t** out_runtime);
int aether_capture_style_runtime_destroy(aether_capture_style_runtime_t* runtime);
int aether_capture_style_runtime_reset(aether_capture_style_runtime_t* runtime);
int aether_capture_style_runtime_resolve(
    aether_capture_style_runtime_t* runtime,
    const aether_capture_style_input_t* inputs,
    int input_count,
    aether_capture_style_output_t* out_states);

// M05.5 hashes and scan geometry helpers.
int aether_hash_fnv1a32(
    const uint8_t* bytes,
    int byte_count,
    uint32_t* out_hash);
int aether_hash_fnv1a64(
    const uint8_t* bytes,
    int byte_count,
    uint64_t* out_hash);

// M05.6 wedge geometry + flip/ripple interaction kernels.
typedef struct aether_wedge_input_triangle {
    aether_float3_t v0;
    aether_float3_t v1;
    aether_float3_t v2;
    aether_float3_t normal;
    float metallic;
    float roughness;
    float display;
    float thickness;
    uint32_t triangle_id;
} aether_wedge_input_triangle_t;

typedef struct aether_wedge_vertex {
    aether_float3_t position;
    aether_float3_t normal;
    float metallic;
    float roughness;
    float display;
    float thickness;
    uint32_t triangle_id;
} aether_wedge_vertex_t;

typedef struct aether_fragment_visual_params {
    float edge_length;
    float gap_width;
    float fill_opacity;
    float fill_gray;
    float border_width_px;
    float border_alpha;
    float metallic;
    float roughness;
    float wedge_thickness;
} aether_fragment_visual_params_t;

int aether_generate_wedge_geometry(
    const aether_wedge_input_triangle_t* triangles,
    int triangle_count,
    int lod_level,
    aether_wedge_vertex_t* out_vertices,
    int* inout_vertex_count,
    uint32_t* out_indices,
    int* inout_index_count);
int aether_compute_fragment_visual_params(
    float display,
    float depth,
    float triangle_area,
    float median_area,
    aether_fragment_visual_params_t* out_params);
int aether_compute_bevel_normals(
    aether_float3_t top_face_normal,
    aether_float3_t side_face_normal,
    int segments,
    aether_float3_t* out_normals,
    int* inout_normal_count);
int aether_scan_triangle_longest_edge(
    const aether_scan_triangle_t* triangle,
    aether_float3_t* out_start,
    aether_float3_t* out_end,
    float* out_length_sq);

typedef struct aether_quaternion {
    float x;
    float y;
    float z;
    float w;
} aether_quaternion_t;

typedef struct aether_flip_easing_config {
    float duration_s;
    float cp1x;
    float cp1y;
    float cp2x;
    float cp2y;
    float stagger_delay_s;
    int max_concurrent;
} aether_flip_easing_config_t;

typedef struct aether_flip_animation_state {
    float start_time_s;
    float flip_angle;
    aether_float3_t flip_axis_origin;
    aether_float3_t flip_axis_direction;
    float ripple_amplitude;
    aether_quaternion_t rotation;
    aether_float3_t rotated_normal;
} aether_flip_animation_state_t;

typedef struct aether_flip_runtime_config {
    aether_flip_easing_config_t easing;
    float min_display_delta;
    float threshold_s0_to_s1;
    float threshold_s1_to_s2;
    float threshold_s2_to_s3;
    float threshold_s3_to_s4;
    float threshold_s4_to_s5;
} aether_flip_runtime_config_t;

typedef struct aether_flip_runtime_observation {
    uint64_t patch_key;
    float previous_display;
    float current_display;
    int32_t triangle_id;
    aether_float3_t axis_start;
    aether_float3_t axis_end;
} aether_flip_runtime_observation_t;

float aether_flip_easing(float t, const aether_flip_easing_config_t* config_or_null);
int aether_compute_flip_states(
    const aether_flip_animation_state_t* active_flips,
    int flip_count,
    float current_time,
    const aether_flip_easing_config_t* config_or_null,
    const aether_float3_t* rest_normals_or_null,
    aether_flip_animation_state_t* out_states);
int aether_flip_runtime_default_config(aether_flip_runtime_config_t* out_config);
int aether_flip_runtime_create(
    const aether_flip_runtime_config_t* config_or_null,
    aether_flip_runtime_t** out_runtime);
int aether_flip_runtime_destroy(aether_flip_runtime_t* runtime);
int aether_flip_runtime_reset(aether_flip_runtime_t* runtime);
int aether_flip_runtime_ingest(
    aether_flip_runtime_t* runtime,
    const aether_flip_runtime_observation_t* observations,
    int observation_count,
    double now_s,
    int32_t* out_crossed_triangle_ids,
    int* inout_crossed_count);
int aether_flip_runtime_sample(
    const aether_flip_runtime_t* runtime,
    const int32_t* triangle_ids,
    int triangle_count,
    double now_s,
    float* out_angles,
    aether_float3_t* out_axis_origins,
    aether_float3_t* out_axis_directions);
int aether_flip_runtime_tick(
    aether_flip_runtime_t* runtime,
    double now_s,
    float* out_active_angles,
    int* inout_active_count);

typedef struct aether_ripple_config {
    float damping;
    int max_hops;
    float delay_per_hop_s;
} aether_ripple_config_t;

typedef struct aether_ripple_runtime_config {
    aether_ripple_config_t ripple;
    int max_concurrent_waves;
    double min_spawn_interval_s;
} aether_ripple_runtime_config_t;

int aether_ripple_build_adjacency(
    const uint32_t* triangle_indices,
    int triangle_count,
    uint32_t* out_offsets,
    uint32_t* out_neighbors,
    int neighbor_capacity,
    int* out_neighbor_count);
int aether_compute_ripple_amplitudes(
    const uint32_t* adjacency_offsets,
    const uint32_t* adjacency_neighbors,
    int triangle_count,
    const uint32_t* trigger_triangle_ids,
    int trigger_count,
    const float* trigger_start_times,
    float current_time,
    const aether_ripple_config_t* config_or_null,
    float* out_amplitudes);
int aether_ripple_runtime_default_config(aether_ripple_runtime_config_t* out_config);
int aether_ripple_runtime_create(
    const aether_ripple_runtime_config_t* config_or_null,
    aether_ripple_runtime_t** out_runtime);
int aether_ripple_runtime_destroy(aether_ripple_runtime_t* runtime);
int aether_ripple_runtime_reset(aether_ripple_runtime_t* runtime);
int aether_ripple_runtime_set_adjacency(
    aether_ripple_runtime_t* runtime,
    const uint32_t* offsets,
    const uint32_t* neighbors,
    int triangle_count);
int aether_ripple_runtime_spawn(
    aether_ripple_runtime_t* runtime,
    int32_t source_triangle,
    double spawn_time_s,
    int* out_spawned);
int aether_ripple_runtime_sample(
    const aether_ripple_runtime_t* runtime,
    const int32_t* triangle_ids,
    int triangle_count,
    double current_time_s,
    float* out_amplitudes);
int aether_ripple_runtime_tick(
    aether_ripple_runtime_t* runtime,
    double current_time_s,
    float* out_amplitudes,
    int* inout_amplitude_count);

// M06 deterministic triangulation.
typedef struct aether_point2d {
    double x;
    double y;
} aether_point2d_t;

int aether_deterministic_triangulate_quad(
    const aether_point2d_t* quad_vertices,
    double epsilon,
    aether_point2d_t* out_triangle_vertices,
    int* inout_vertex_count);
int aether_deterministic_sort_triangles(
    const aether_point2d_t* triangle_vertices,
    int triangle_count,
    double epsilon,
    aether_point2d_t* out_triangle_vertices);

// M09 photometric checker.
typedef struct aether_photometric_result {
    double luminance_variance;
    double lab_variance;
    double exposure_consistency;
    int is_consistent;
    double confidence;
} aether_photometric_result_t;

int aether_photometric_checker_create(
    int window_size,
    aether_photometric_checker_t** out_checker);
int aether_photometric_checker_destroy(aether_photometric_checker_t* checker);
int aether_photometric_checker_reset(aether_photometric_checker_t* checker);
int aether_photometric_checker_update(
    aether_photometric_checker_t* checker,
    double luminance,
    double exposure,
    double lab_l,
    double lab_a,
    double lab_b);
int aether_photometric_checker_check(
    const aether_photometric_checker_t* checker,
    double max_luminance_variance,
    double max_lab_variance,
    double min_exposure_consistency,
    aether_photometric_result_t* out_result);
int aether_photometric_check(
    const aether_photometric_checker_t* checker,
    double max_luminance_variance,
    double max_lab_variance,
    double min_exposure_consistency,
    aether_photometric_result_t* out_result);

// M01 marching cubes bridge.
typedef struct aether_mc_vertex {
    float x;
    float y;
    float z;
} aether_mc_vertex_t;

int aether_marching_cubes_run(
    const float* sdf_grid,
    int dim,
    float origin_x,
    float origin_y,
    float origin_z,
    float voxel_size,
    aether_mc_vertex_t* out_vertices,
    int* inout_vertex_count,
    uint32_t* out_indices,
    int* inout_index_count);

// M02 alias for frame integration.
int aether_tsdf_integrate_frame(
    const aether_integration_input_t* input,
    aether_integration_result_t* result);

// M04 volume controller.
typedef struct aether_thermal_state {
    int level;              // 0..9
    float headroom;         // 0..1
    float time_to_next_s;   // seconds
    float slope;            // d(headroom)/dt
    float slope_2nd;        // second derivative
    float confidence;       // 0..1
} aether_thermal_state_t;

typedef struct aether_thermal_observation {
    int os_level;           // 0..9
    float os_headroom;      // 0..1
    float battery_temp_c;   // celsius
    float soc_temp_c;       // celsius
    float skin_temp_c;      // celsius
    float gpu_busy_ratio;   // 0..1
    float cpu_probe_ms;     // optional, <=0 use internal probe
    double timestamp_s;     // monotonic seconds
} aether_thermal_observation_t;

int aether_thermal_engine_create(aether_thermal_engine_t** out_engine);
int aether_thermal_engine_destroy(aether_thermal_engine_t* engine);
int aether_thermal_engine_reset(aether_thermal_engine_t* engine);
int aether_thermal_engine_update(
    aether_thermal_engine_t* engine,
    const aether_thermal_observation_t* observation,
    aether_thermal_state_t* out_state);
float aether_thermal_engine_cpu_probe_ms(void);

typedef struct aether_volume_controller_signals {
    int thermal_level;  // 0..9
    float thermal_headroom;
    int memory_water_level;  // 0..4
    aether_thermal_state_t thermal;
    int memory_pressure;      // canonical 0..4
    int tracking_state;      // 0 unavailable, 1 limited, 2 normal
    float camera_pose[16];
    float angular_velocity;
    float frame_actual_duration_ms;
    int valid_pixel_count;
    int total_pixel_count;
    double timestamp_s;
} aether_volume_controller_signals_t;

typedef struct aether_volume_controller_state {
    uint64_t frame_counter;
    int integration_skip_rate;
    int consecutive_good_frames;
    int consecutive_bad_frames;
    double consecutive_good_time_s;
    double consecutive_bad_time_s;
    int system_thermal_ceiling;
    int memory_skip_floor;
    double last_update_s;
} aether_volume_controller_state_t;

typedef struct aether_volume_controller_decision {
    int should_skip_frame;
    int integration_skip_rate;
    int should_evict;
    int blocks_to_evict;
    int is_keyframe;
    int blocks_to_preallocate;
    float quality_weight;
} aether_volume_controller_decision_t;

int aether_volume_controller_decide(
    const aether_volume_controller_signals_t* signals,
    aether_volume_controller_state_t* state,
    aether_volume_controller_decision_t* out_decision);

// M10 depth filtering.
typedef struct aether_depth_filter_config {
    float sigma_spatial;
    float sigma_range;
    int kernel_radius;
    int max_fill_radius;
    float min_valid_depth;
    float max_valid_depth;
} aether_depth_filter_config_t;

typedef struct aether_depth_filter_quality {
    float noise_residual;
    float valid_ratio;
    float edge_risk_score;
} aether_depth_filter_quality_t;

typedef struct aether_fusion_feedback {
    float voxel_weight_median;
    float sdf_variance_p95;
    float ghosting_score;
} aether_fusion_feedback_t;

int aether_depth_filter_create(
    int width,
    int height,
    const aether_depth_filter_config_t* config,
    aether_depth_filter_t** out_filter);
int aether_depth_filter_destroy(aether_depth_filter_t* filter);
int aether_depth_filter_reset(aether_depth_filter_t* filter);
int aether_depth_filter_run(
    aether_depth_filter_t* filter,
    const float* depth_in,
    const uint8_t* confidence_in,
    float angular_velocity,
    float* depth_out,
    aether_depth_filter_quality_t* out_quality);
int aether_depth_filter_apply_fusion_feedback(
    aether_depth_filter_t* filter,
    const aether_fusion_feedback_t* feedback);

// M11 ICP refinement.
typedef struct aether_icp_point {
    float x;
    float y;
    float z;
} aether_icp_point_t;

typedef struct aether_icp_config {
    int max_iterations;
    float distance_threshold;
    float normal_threshold_deg;
    float huber_delta;
    float convergence_translation;
    float convergence_rotation;
    float watchdog_max_diag_ratio;
    int watchdog_max_residual_rise;
} aether_icp_config_t;

typedef struct aether_icp_result {
    float pose_out[16];
    int iterations;
    int correspondence_count;
    float rmse;
    float watchdog_diag_ratio;
    int watchdog_tripped;
    int converged;
} aether_icp_result_t;

int aether_icp_refine(
    const aether_icp_point_t* source_points,
    int source_count,
    const aether_icp_point_t* target_points,
    int target_count,
    const aether_icp_point_t* target_normals,
    const float initial_pose[16],
    float angular_velocity,
    const aether_icp_config_t* config,
    aether_icp_result_t* out_result);

// M12 color correction.
typedef struct aether_color_correction_config {
    int mode;  // 0 gray-world, 1 gray-world + exposure
    float min_gain;
    float max_gain;
    float min_exposure_ratio;
    float max_exposure_ratio;
} aether_color_correction_config_t;

typedef struct aether_color_correction_state {
    int has_reference;
    float reference_luminance;
} aether_color_correction_state_t;

typedef struct aether_color_correction_stats {
    float gain_r;
    float gain_g;
    float gain_b;
    float exposure_ratio;
} aether_color_correction_stats_t;

int aether_color_correct(
    const uint8_t* image_in,
    int width,
    int height,
    int row_bytes,
    const aether_color_correction_config_t* config,
    aether_color_correction_state_t* state,
    uint8_t* image_out,
    aether_color_correction_stats_t* out_stats);

// M12.1 DA3 depth fusion and monocular depth metricization.
// `tri_tet_class` uses AETHER_TRI_TET_CLASS_* declared above.

typedef struct aether_da3_depth_sample {
    float depth_from_vision;
    float depth_from_tsdf;
    float sigma2_vision;
    float sigma2_tsdf;
    uint8_t tri_tet_class;
} aether_da3_depth_sample_t;

int aether_da3_fuse_depth(
    const aether_da3_depth_sample_t* sample,
    float* out_fused_depth,
    float* out_confidence);
int aether_monocular_depth_to_metric(
    const float* relative_depth,
    int width,
    int height,
    const float* camera_pose_16,
    const float* history_poses_16,
    int history_pose_count,
    float* out_metric_depth,
    float* out_scale_factor);

// M13 bandwidth Kalman.
typedef struct aether_kalman_bandwidth_state {
    double x[4];
    double p[16];
    double q_base;
    double r;
    double recent_bps[10];
    int recent_count;
    int recent_head;
    int total_samples;
} aether_kalman_bandwidth_state_t;

typedef struct aether_kalman_bandwidth_output {
    double predicted_bps;
    double ci_low;
    double ci_high;
    int trend;      // 0 rising, 1 stable, 2 falling
    int reliable;   // 0/1
} aether_kalman_bandwidth_output_t;

int aether_bandwidth_kalman_reset(aether_kalman_bandwidth_state_t* state);
int aether_bandwidth_kalman_step(
    aether_kalman_bandwidth_state_t* state,
    int64_t bytes_transferred,
    double duration_seconds,
    aether_kalman_bandwidth_output_t* out);
int aether_bandwidth_kalman_predict(
    const aether_kalman_bandwidth_state_t* state,
    aether_kalman_bandwidth_output_t* out);

// M14 erasure coding.
typedef struct aether_erasure_selection {
    int mode;   // 0 RS, 1 RaptorQ
    int field;  // 0 GF256, 1 GF65536
} aether_erasure_selection_t;

int aether_erasure_select_mode(
    int chunk_count,
    double loss_rate,
    aether_erasure_selection_t* out_selection);
int aether_erasure_encode(
    const uint8_t* input_data,
    const uint32_t* input_offsets,
    int block_count,
    double redundancy,
    uint8_t* out_data,
    uint32_t out_data_capacity,
    uint32_t* out_offsets,
    int out_block_capacity,
    int* out_block_count,
    uint32_t* out_data_size);
int aether_erasure_encode_with_mode(
    const uint8_t* input_data,
    const uint32_t* input_offsets,
    int block_count,
    double redundancy,
    int mode,   // 0 RS, 1 RaptorQ
    int field,  // 0 GF256, 1 GF65536
    uint8_t* out_data,
    uint32_t out_data_capacity,
    uint32_t* out_offsets,
    int out_block_capacity,
    int* out_block_count,
    uint32_t* out_data_size);
int aether_erasure_decode_systematic(
    const uint8_t* blocks_data,
    const uint32_t* block_offsets,
    const uint8_t* block_present,
    int block_count,
    int original_count,
    uint8_t* out_data,
    uint32_t out_data_capacity,
    uint32_t* out_offsets,
    int out_block_capacity,
    int* out_block_count,
    uint32_t* out_data_size);
int aether_erasure_decode_systematic_with_mode(
    const uint8_t* blocks_data,
    const uint32_t* block_offsets,
    const uint8_t* block_present,
    int block_count,
    int original_count,
    int mode,   // 0 RS, 1 RaptorQ
    int field,  // 0 GF256, 1 GF65536
    uint8_t* out_data,
    uint32_t out_data_capacity,
    uint32_t* out_offsets,
    int out_block_capacity,
    int* out_block_count,
    uint32_t* out_data_size);

// M15 loop detector.
typedef struct aether_loop_candidate {
    int frame_index;
    float overlap_ratio;
    float score;
} aether_loop_candidate_t;

int aether_loop_detect(
    const uint64_t* current_blocks,
    int current_count,
    const uint64_t* history_blocks,
    const uint32_t* history_offsets,
    int history_frame_count,
    int skip_recent,
    float overlap_threshold,
    float yaw_sigma,
    float time_tau,
    const float* yaw_deltas,
    const float* time_deltas,
    aether_loop_candidate_t* out_candidate);

// M16 pose graph optimization.
typedef struct aether_pose_graph_node {
    uint32_t id;
    float pose[16];
    int fixed;
} aether_pose_graph_node_t;

typedef struct aether_pose_graph_edge {
    uint32_t from_id;
    uint32_t to_id;
    float transform[16];
    float information[36];
    int is_loop;
} aether_pose_graph_edge_t;

typedef struct aether_pose_graph_config {
    int max_iterations;
    float step_size;
    float huber_delta;
    float stop_translation;
    float stop_rotation;
    float watchdog_max_diag_ratio;
    int watchdog_max_residual_rise;
} aether_pose_graph_config_t;

typedef struct aether_pose_graph_result {
    int iterations;
    float initial_error;
    float final_error;
    float watchdog_diag_ratio;
    int watchdog_tripped;
    int converged;
} aether_pose_graph_result_t;

int aether_pose_graph_optimize(
    aether_pose_graph_node_t* nodes,
    int node_count,
    const aether_pose_graph_edge_t* edges,
    int edge_count,
    const aether_pose_graph_config_t* config,
    aether_pose_graph_result_t* out_result);

// M16.1 pose stabilizer.
typedef struct aether_pose_stabilizer_config {
    float translation_alpha;
    float rotation_alpha;
    float max_prediction_horizon_s;
    float bias_alpha;
    uint32_t init_frames;
    int fast_init;
    int use_ieskf;
} aether_pose_stabilizer_config_t;

int aether_pose_stabilizer_create(
    const aether_pose_stabilizer_config_t* config_or_null,
    aether_pose_stabilizer_t** out_stabilizer);
int aether_pose_stabilizer_destroy(aether_pose_stabilizer_t* stabilizer);
int aether_pose_stabilizer_reset(aether_pose_stabilizer_t* stabilizer);
int aether_pose_stabilizer_update(
    aether_pose_stabilizer_t* stabilizer,
    const float* raw_pose_16,
    const float* gyro_xyz,
    const float* accel_xyz,
    uint64_t timestamp_ns,
    float* out_stabilized_pose_16,
    float* out_pose_quality);
int aether_pose_stabilizer_predict(
    const aether_pose_stabilizer_t* stabilizer,
    uint64_t target_timestamp_ns,
    float* out_predicted_pose_16);

// TSDF.
int aether_tsdf_volume_create(aether_tsdf_volume_t** out);
int aether_tsdf_volume_destroy(aether_tsdf_volume_t* vol);
int aether_tsdf_volume_reset(aether_tsdf_volume_t* vol);
int aether_tsdf_volume_integrate(
    aether_tsdf_volume_t* vol,
    const aether_integration_input_t* input,
    aether_integration_result_t* result);
int aether_tsdf_volume_handle_thermal_state(aether_tsdf_volume_t* vol, int state);
int aether_tsdf_volume_handle_memory_pressure(aether_tsdf_volume_t* vol, int level);
int aether_tsdf_volume_handle_memory_pressure_ratio(aether_tsdf_volume_t* vol, float pressure_ratio);
int aether_tsdf_volume_apply_frame_feedback(aether_tsdf_volume_t* vol, double gpu_time_ms);
typedef struct aether_tsdf_runtime_state {
    uint64_t frame_count;
    int has_last_pose;  // 0/1
    float last_pose[16];
    double last_timestamp;
    int system_thermal_ceiling;
    int current_integration_skip;
    int consecutive_good_frames;
    int consecutive_rejections;
    double last_thermal_change_time_s;
    int hash_table_size;
    int hash_table_capacity;
    int current_max_blocks_per_extraction;
    int consecutive_good_meshing_cycles;
    int forgiveness_window_remaining;
    int consecutive_teleport_count;
    float last_angular_velocity;
    int recent_pose_count;
    double last_idle_check_time_s;
    int memory_water_level;  // 0=green,1=yellow,2=orange,3=red,4=critical
    float memory_pressure_ratio;
    double last_memory_pressure_change_time_s;
    int free_block_slot_count;
    int last_evicted_blocks;
} aether_tsdf_runtime_state_t;
int aether_tsdf_volume_get_runtime_state(
    const aether_tsdf_volume_t* vol,
    aether_tsdf_runtime_state_t* out_state);
int aether_tsdf_volume_set_runtime_state(
    aether_tsdf_volume_t* vol,
    const aether_tsdf_runtime_state_t* state);
int aether_tsdf_integrate(
    const aether_integration_input_t* input,
    aether_integration_result_t* result);
int aether_tsdf_integrate_external_blocks(
    const aether_integration_input_t* input,
    aether_external_block_t* blocks,
    int block_count,
    aether_integration_result_t* result);
float aether_tsdf_voxel_size_near(void);
int aether_tsdf_block_size(void);

// Mesh stability query.
typedef struct aether_mesh_stability_query {
    int32_t block_x;
    int32_t block_y;
    int32_t block_z;
    uint32_t last_mesh_generation;
} aether_mesh_stability_query_t;

typedef struct aether_mesh_stability_result {
    uint32_t current_integration_generation;
    int needs_re_extraction;
    float fade_in_alpha;
    float eviction_weight;
} aether_mesh_stability_result_t;

int aether_query_mesh_stability(
    const aether_mesh_stability_query_t* queries,
    int query_count,
    uint64_t current_integration_generation,
    uint64_t mesh_generation,
    double staleness_threshold_s,
    aether_mesh_stability_result_t* out_result);

typedef struct aether_memory_footprint {
    uint64_t phys_used_bytes;
    uint64_t phys_limit_bytes;
    uint64_t gpu_used_bytes;
    uint64_t gpu_budget_bytes;
    float usage_ratio;
} aether_memory_footprint_t;

typedef struct aether_core_health {
    uint64_t nan_count;
    uint64_t inf_count;
    uint64_t guarded_scalar_count;
    uint64_t guarded_vector_count;
    float icp_last_rmse;
    float icp_last_diag_ratio;
    float pose_graph_last_error;
    float pose_graph_last_diag_ratio;
    float loop_last_score;
    float thermal_headroom;
    float thermal_slope;
    float thermal_confidence;
    int memory_water_level;
    float memory_pressure_ratio;
    int current_integration_skip;
    int hash_table_size;
    int last_evicted_blocks;
    int ar_session_reconnect_count;
} aether_core_health_t;

int aether_get_core_health(aether_core_health_t* out_health);
int aether_reset_core_health(void);

// Two-state GPU scheduler.
typedef struct aether_gpu_scheduler_config {
    float total_frame_budget_ms;
    float system_reserve_ms;
    float capture_tracking_min_ms;
    float capture_rendering_min_ms;
    float capture_optimization_min_ms;
    float finished_tracking_min_ms;
    float finished_rendering_min_ms;
    float finished_optimization_min_ms;
    float capture_tracking_weight;
    float capture_rendering_weight;
    float capture_optimization_weight;
    float finished_tracking_weight;
    float finished_rendering_weight;
    float finished_optimization_weight;
} aether_gpu_scheduler_config_t;

typedef struct aether_gpu_budget {
    float tracking_ms;
    float rendering_ms;
    float optimization_ms;
    float flexible_pool_ms;
    float system_reserve_ms;
    float total_frame_budget_ms;
} aether_gpu_budget_t;

typedef struct aether_gpu_workload {
    float tracking_demand_ms;
    float rendering_demand_ms;
    float optimization_demand_ms;
} aether_gpu_workload_t;

typedef struct aether_gpu_frame_result {
    aether_gpu_budget_t budget;
    float tracking_assigned_ms;
    float rendering_assigned_ms;
    float optimization_assigned_ms;
    float unused_flexible_ms;
} aether_gpu_frame_result_t;

int aether_gpu_scheduler_create(
    const aether_gpu_scheduler_config_t* config,
    aether_gpu_scheduler_t** out_scheduler);
int aether_gpu_scheduler_destroy(aether_gpu_scheduler_t* scheduler);
int aether_gpu_scheduler_allocate_budget(
    const aether_gpu_scheduler_t* scheduler,
    int state,  // 0=capturing, 1=capture_finished
    aether_gpu_budget_t* out_budget);
int aether_gpu_scheduler_execute_frame(
    const aether_gpu_scheduler_t* scheduler,
    int state,  // 0=capturing, 1=capture_finished
    const aether_gpu_workload_t* workload,
    aether_gpu_frame_result_t* out_result);

// Confidence decay.
typedef struct aether_confidence_decay_config {
    float decay_per_frame;
    float min_confidence;
    float observation_boost;
    float max_confidence;
    uint32_t grace_frames;
    float peak_retention_floor;
    float perceptual_exponent;
} aether_confidence_decay_config_t;

int aether_decay_confidence(
    aether_gaussian_t* gaussians,
    int count,
    const int* in_current_frustum,
    uint64_t current_frame,
    const aether_confidence_decay_config_t* config);

// Patch identity matching.
typedef struct aether_patch_identity_sample {
    uint64_t patch_key;
    aether_float3_t centroid;
    float display;
} aether_patch_identity_sample_t;

int aether_match_patch_identities(
    const aether_patch_identity_sample_t* observations,
    int observation_count,
    const aether_patch_identity_sample_t* anchors,
    int anchor_count,
    float lock_threshold,
    float snap_radius,
    float display_threshold,
    uint64_t* out_resolved_keys);

// Stable render triangle selection.
typedef struct aether_render_triangle_candidate {
    uint64_t patch_key;
    aether_float3_t centroid;
    float display;
    float stability_fade_alpha;
    int32_t residency_until_frame;
} aether_render_triangle_candidate_t;

typedef struct aether_render_selection_config {
    int32_t current_frame;
    int max_triangles;
    aether_float3_t camera_position;
    float completion_threshold;
    float distance_bias;
    float display_weight;
    float residency_boost;
    float completion_boost;
    float stability_weight;
} aether_render_selection_config_t;

int aether_select_stable_render_triangles(
    const aether_render_triangle_candidate_t* candidates,
    int candidate_count,
    const aether_render_selection_config_t* config,
    int32_t* out_selected_indices,
    int* inout_selected_count);

// Render snapshot computation.
typedef struct aether_render_snapshot_input {
    float base_display;
    float confidence_display;
    int has_stability;
    float fade_in_alpha;
    float eviction_weight;
} aether_render_snapshot_input_t;

typedef struct aether_render_snapshot_config {
    float s3_to_s4_threshold;
    float s4_to_s5_threshold;
} aether_render_snapshot_config_t;

int aether_compute_render_snapshot(
    const aether_render_snapshot_input_t* inputs,
    int input_count,
    const aether_render_snapshot_config_t* config,
    float* out_rendered_display);

// Geo C API wrappers.
typedef struct aether_geo_rtree aether_geo_rtree_t;
typedef struct aether_geo_altitude_engine aether_geo_altitude_engine_t;
typedef struct aether_geo_renderer aether_geo_renderer_t;

typedef struct aether_geo_geodetic_coord {
    double lat_deg;
    double lon_deg;
    double alt_m;
} aether_geo_geodetic_coord_t;

typedef struct aether_geo_ecef_coord {
    double x;
    double y;
    double z;
} aether_geo_ecef_coord_t;

typedef struct aether_geo_solar_position {
    double azimuth_deg;
    double elevation_deg;
    double declination_deg;
    double hour_angle_deg;
} aether_geo_solar_position_t;

typedef struct aether_geo_env_light {
    float sh_coeffs[9];
    float sun_direction[3];
    float sun_color[3];
    float sun_intensity;
    float ambient_intensity;
    int32_t phase;
} aether_geo_env_light_t;

typedef struct aether_geo_gpu_budget {
    float terrain_ms;
    float tiles_ms;
    float labels_ms;
    float effects_ms;
    float reserve_ms;
    float total_ms;
} aether_geo_gpu_budget_t;

typedef struct aether_geo_render_input {
    double camera_lat;
    double camera_lon;
    double camera_altitude_m;
    float camera_fov_deg;
    float viewport_width;
    float viewport_height;
    double timestamp_utc;
    int32_t quality;  // 0=saver, 1=balanced, 2=cinematic
    uint32_t active_phase7_features;
    int32_t thermal_level;
    float frame_budget_ms;
} aether_geo_render_input_t;

typedef struct aether_geo_render_stats {
    uint32_t tiles_rendered;
    uint32_t tiles_culled;
    uint32_t labels_visible;
    uint32_t labels_culled;
    float frame_time_ms;
    aether_geo_gpu_budget_t budget_used;
    aether_geo_env_light_t solar_light;
} aether_geo_render_stats_t;

int aether_geo_distance_haversine(
    double lat1_deg,
    double lon1_deg,
    double lat2_deg,
    double lon2_deg,
    double* out_distance_m);
int aether_geo_distance_haversine_batch(
    double origin_lat_deg,
    double origin_lon_deg,
    const double* target_lats_deg,
    const double* target_lons_deg,
    double* out_distances_m,
    uint32_t count);
int aether_geo_distance_vincenty(
    double lat1_deg,
    double lon1_deg,
    double lat2_deg,
    double lon2_deg,
    double* out_distance_m);

int aether_geo_latlon_to_cell(
    double lat_deg,
    double lon_deg,
    uint32_t level,
    uint64_t* out_cell_id);
int aether_geo_cell_to_latlon(
    uint64_t cell_id,
    double* out_lat_deg,
    double* out_lon_deg);

int aether_geo_geodetic_to_ecef(
    const aether_geo_geodetic_coord_t* geo,
    aether_geo_ecef_coord_t* out);
int aether_geo_ecef_to_geodetic(
    const aether_geo_ecef_coord_t* ecef,
    aether_geo_geodetic_coord_t* out);
int aether_geo_horizon_cull(
    const aether_geo_ecef_coord_t* camera,
    const aether_geo_ecef_coord_t* point,
    double earth_radius,
    int* out_culled);
void aether_geo_rte_split(double value, float* out_high, float* out_low);

int aether_geo_solar_position(
    double timestamp_utc,
    double lat_deg,
    double lon_deg,
    aether_geo_solar_position_t* out);
int32_t aether_geo_solar_day_phase(double elevation_deg);
int aether_geo_solar_environment_light(
    const aether_geo_solar_position_t* pos,
    double lat_deg,
    double lon_deg,
    aether_geo_env_light_t* out);

aether_geo_rtree_t* aether_geo_rtree_create(uint32_t reserved_capacity);
void aether_geo_rtree_destroy(aether_geo_rtree_t* tree);
int aether_geo_rtree_insert(
    aether_geo_rtree_t* tree,
    double lat_deg,
    double lon_deg,
    uint64_t id,
    float score);
int aether_geo_rtree_query_range(
    const aether_geo_rtree_t* tree,
    double lat_min,
    double lat_max,
    double lon_min,
    double lon_max,
    uint64_t* out_ids,
    uint32_t max_results,
    uint32_t* out_count);

aether_geo_altitude_engine_t* aether_geo_altitude_engine_create(void);
void aether_geo_altitude_engine_destroy(aether_geo_altitude_engine_t* engine);
int aether_geo_altitude_engine_predict(aether_geo_altitude_engine_t* engine, double dt_s);
int aether_geo_altitude_engine_get_height(
    const aether_geo_altitude_engine_t* engine,
    double* out_height_m);

aether_geo_renderer_t* aether_geo_renderer_create(void);
void aether_geo_renderer_destroy(aether_geo_renderer_t* renderer);
int aether_geo_renderer_frame(
    aether_geo_renderer_t* renderer,
    const aether_geo_render_input_t* input,
    aether_geo_render_stats_t* out_stats);
void aether_geo_renderer_set_quality(aether_geo_renderer_t* renderer, int32_t preset);
int32_t aether_geo_renderer_get_quality(const aether_geo_renderer_t* renderer);
int aether_geo_renderer_enable_feature(aether_geo_renderer_t* renderer, uint32_t feature_bit);
int aether_geo_renderer_disable_feature(aether_geo_renderer_t* renderer, uint32_t feature_bit);

// ─── F1: Progressive Compression ──────────────────────────────────────
typedef struct aether_f1_progressive_config {
    uint32_t level_count;
    float area_gamma;
    float capture_order_priority;
    uint8_t quant_bits_position;
    uint8_t quant_bits_scale;
    uint8_t quant_bits_opacity;
    uint8_t quant_bits_uncertainty;
    uint8_t quant_bits_sh;
    uint8_t sh_coeff_count;
} aether_f1_progressive_config_t;

typedef struct aether_f1_lod_level {
    uint32_t level_index;
    float min_unit_area;
    float max_unit_area;
    uint32_t gaussian_count;
    uint32_t estimated_bytes;
} aether_f1_lod_level_t;

typedef struct aether_f1_hierarchy {
    uint32_t level_count;
    aether_f1_lod_level_t levels[16];  // max 16 LOD levels
    float scene_bounds_min[3];
    float scene_bounds_max[3];
    uint32_t estimated_bytes_per_gaussian;
} aether_f1_hierarchy_t;

typedef struct aether_f1_encoded_level {
    uint32_t level_index;
    uint32_t gaussian_count;
    uint8_t sh_coeff_count;
    const uint8_t* bytes;
    uint32_t byte_count;
} aether_f1_encoded_level_t;

typedef struct aether_f1_render_queue_entry {
    uint32_t gaussian_index;
    uint32_t gaussian_id;
    uint64_t host_unit_id;
    const char* patch_id;
    uint32_t capture_sequence;
    uint16_t patch_priority;
    uint64_t first_observed_frame_id;
    int64_t first_observed_ms;
    uint8_t lod_level;
} aether_f1_render_queue_entry_t;

int aether_f1_default_config(aether_f1_progressive_config_t* out_config);

int aether_f1_build_hierarchy(
    const aether_scaffold_unit_t* units, int unit_count,
    const aether_gaussian_t* gaussians, int gaussian_count,
    const aether_scaffold_patch_map_t* patch_map,
    const aether_f1_progressive_config_t* config,
    aether_f1_hierarchy_t* out_hierarchy);

int aether_f1_select_level_for_budget(
    const aether_f1_hierarchy_t* hierarchy,
    uint32_t byte_budget,
    uint32_t* out_level_index);

int aether_f1_encode_level(
    const aether_gaussian_t* gaussians, int gaussian_count,
    const aether_f1_hierarchy_t* hierarchy,
    uint32_t level_index,
    const aether_f1_progressive_config_t* config,
    uint8_t* out_bytes, uint32_t* inout_byte_count);

int aether_f1_decode_level(
    const uint8_t* encoded_bytes, uint32_t byte_count,
    uint8_t sh_coeff_count,
    aether_gaussian_t* out_gaussians, int* inout_count);

int aether_f1_build_capture_order_queue(
    const aether_f1_hierarchy_t* hierarchy,
    const aether_gaussian_t* gaussians, int gaussian_count,
    uint32_t level_index,
    aether_f1_render_queue_entry_t* out_entries, int* inout_count);

// ─── F1: Time Mirror Animation ────────────────────────────────────────
typedef struct aether_f1_time_mirror_config {
    float start_offset_meters;
    float min_flight_duration_s;
    float max_flight_duration_s;
    float appear_stagger_s;
    float appear_jitter_ratio;
    float priority_boost_appear_gain;
    float priority_boost_cap;
    float area_duration_power;
    float flight_distance_normalizer_m;
    float flight_distance_factor_min;
    float flight_distance_factor_max;
    float flight_duration_distance_blend_base;
    float flight_duration_distance_blend_gain;
    float opacity_ramp_ratio;
    float min_opacity_ramp_ratio;
    float sh_crossfade_start_ratio;
    float min_sh_crossfade_span;
    float arc_height_base_m;
    float arc_height_distance_gain;
    float arc_area_normalizer;
    float arc_area_factor_min;
    float spin_degrees_min;
    float spin_degrees_range;
    float min_progress_denominator_s;
    float safe_total_time_epsilon_s;
} aether_f1_time_mirror_config_t;

typedef struct aether_camera_trajectory_entry {
    uint64_t frame_id;
    aether_float3_t position;
    aether_float3_t forward;
    aether_float3_t up;
    double timestamp_ms;
} aether_camera_trajectory_entry_t;

typedef struct aether_f1_fragment_flight {
    uint64_t unit_id;
    aether_float3_t start_position;
    aether_float3_t end_position;
    aether_float3_t start_normal;
    aether_float3_t end_normal;
    uint64_t first_observed_frame_id;
    int64_t first_observed_ms;
    float priority_boost;
    uint32_t earliest_capture_sequence;
    float appear_offset_s;
    float flight_duration_s;
    uint32_t gaussian_count;
} aether_f1_fragment_flight_t;

typedef struct aether_f1_animation_metrics {
    uint32_t visible_gaussian_count;
    uint32_t hidden_gaussian_count;
    uint32_t active_fragment_count;
    float completion_ratio;
} aether_f1_animation_metrics_t;

int aether_f1_default_time_mirror_config(aether_f1_time_mirror_config_t* out_config);

int aether_f1_build_fragment_queue(
    const aether_scaffold_unit_t* units, int unit_count,
    const aether_scaffold_vertex_t* vertices, int vertex_count,
    const aether_gaussian_t* gaussians, int gaussian_count,
    const aether_scaffold_patch_map_t* patch_map,
    const aether_camera_trajectory_entry_t* trajectory, int trajectory_count,
    const aether_f1_time_mirror_config_t* config,
    aether_f1_fragment_flight_t* out_flights, int* inout_count);

int aether_f1_animate_frame(
    const aether_gaussian_t* gaussians, int gaussian_count,
    const aether_f1_fragment_flight_t* flights, int flight_count,
    const aether_scaffold_patch_map_t* patch_map,
    const aether_f1_time_mirror_config_t* config,
    float elapsed_s, float dt_s,
    aether_gaussian_t* out_animated, int* inout_animated_count,
    aether_f1_animation_metrics_t* out_metrics);

// ─── F2: Scaffold Collision Detection ─────────────────────────────────
typedef struct aether_f2_collision_mesh aether_f2_collision_mesh_t;

typedef struct aether_f2_collision_hit {
    int hit;  // 0/1
    float distance;
    aether_float3_t position;
    aether_float3_t normal;
    uint64_t unit_id;
    uint32_t triangle_index;
} aether_f2_collision_hit_t;

typedef struct aether_f2_point_distance_result {
    int valid;  // 0/1
    float distance;
    aether_float3_t closest_point;
    aether_float3_t normal;
    uint64_t unit_id;
    uint32_t triangle_index;
} aether_f2_point_distance_result_t;

aether_f2_collision_mesh_t* aether_f2_build_collision_mesh(
    const aether_scaffold_vertex_t* vertices, int vertex_count,
    const aether_scaffold_unit_t* units, int unit_count);

void aether_f2_destroy_collision_mesh(aether_f2_collision_mesh_t* mesh);

int aether_f2_intersect_ray(
    const aether_f2_collision_mesh_t* mesh,
    const aether_float3_t* origin,
    const aether_float3_t* direction,
    float max_distance,
    aether_f2_collision_hit_t* out_hit);

int aether_f2_query_point_distance(
    const aether_f2_collision_mesh_t* mesh,
    const aether_float3_t* point,
    float max_distance,
    aether_f2_point_distance_result_t* out_result);

// ─── F3: Evidence-Constrained Compression ─────────────────────────────
enum {
    AETHER_F3_TIER_PRESERVE = 0,
    AETHER_F3_TIER_BALANCED = 1,
    AETHER_F3_TIER_AGGRESSIVE = 2,
};

typedef struct aether_f3_belief_record {
    uint64_t unit_id;
    const char* patch_id;
    aether_ds_mass_t mass;
} aether_f3_belief_record_t;

typedef struct aether_f3_plan_config {
    double preserve_threshold;
    double aggressive_threshold;
    uint32_t target_byte_budget;
    uint32_t min_observation_keep;
    float patch_priority_boost;
    float score_weight_opacity;
    float score_weight_observation;
    float score_weight_certainty;
    uint8_t preserve_quant_bits;
    uint8_t balanced_quant_bits;
    uint8_t aggressive_quant_bits;
} aether_f3_plan_config_t;

typedef struct aether_f3_gaussian_decision {
    uint32_t gaussian_index;
    uint32_t gaussian_id;
    const char* patch_id;
    int tier;
    int keep;  // 0/1
    double score;
    double belief;
    uint8_t target_quant_bits;
} aether_f3_gaussian_decision_t;

typedef struct aether_f3_compression_plan {
    uint32_t kept_count;
    uint32_t estimated_bytes;
    const char* coverage_binding_sha256_hex;
} aether_f3_compression_plan_t;

int aether_f3_default_plan_config(aether_f3_plan_config_t* out_config);

int aether_f3_plan_compression(
    const aether_gaussian_t* gaussians, int gaussian_count,
    const aether_f3_belief_record_t* beliefs, int belief_count,
    const aether_scaffold_patch_map_t* patch_map,
    const aether_f1_progressive_config_t* compression_config,
    const aether_f3_plan_config_t* plan_config,
    aether_f3_gaussian_decision_t* out_decisions, int* inout_count,
    aether_f3_compression_plan_t* out_plan);

int aether_f3_extract_kept_gaussians(
    const aether_gaussian_t* gaussians, int gaussian_count,
    const aether_f3_gaussian_decision_t* decisions, int decision_count,
    aether_gaussian_t* out_kept, int* inout_count);

// ─── F5: Delta Patch Chain (Version Control + Merkle) ─────────────────
typedef struct aether_f5_patch_receipt {
    uint64_t version;
    uint64_t leaf_index;
    const char* patch_id;
    uint8_t patch_sha256[32];
    uint8_t merkle_root[32];
} aether_f5_patch_receipt_t;

aether_f5_chain_t* aether_f5_chain_create(void);
void aether_f5_chain_destroy(aether_f5_chain_t* chain);
int aether_f5_chain_reset(aether_f5_chain_t* chain);

int aether_f5_chain_append_patch(
    aether_f5_chain_t* chain,
    const aether_gaussian_t* added_gaussians, int add_count,
    const uint32_t* removed_gaussian_ids, int remove_count,
    const aether_scaffold_unit_t* added_units, int add_unit_count,
    const uint64_t* removed_unit_ids, int remove_unit_count,
    double timestamp_ms,
    aether_f5_patch_receipt_t* out_receipt);

int aether_f5_chain_patch_count(
    const aether_f5_chain_t* chain,
    uint64_t* out_count);

int aether_f5_chain_latest_version(
    const aether_f5_chain_t* chain,
    uint64_t* out_version);

int aether_f5_chain_merkle_root(
    const aether_f5_chain_t* chain,
    uint8_t out_hash[32]);

int aether_f5_chain_verify_receipt(
    const aether_f5_chain_t* chain,
    const aether_f5_patch_receipt_t* receipt,
    int* out_valid);

// ─── F6: Conflict Dynamic Rejection ───────────────────────────────────
typedef struct aether_f6_config {
    double conflict_threshold;
    double release_ratio;
    uint32_t sustain_frames;
    uint32_t recover_frames;
    double ema_alpha;
    double score_gain;
    double score_decay;
} aether_f6_config_t;

typedef struct aether_f6_observation_pair {
    uint32_t gaussian_id;
    uint64_t host_unit_id;
    aether_ds_mass_t predicted;
    aether_ds_mass_t observed;
} aether_f6_observation_pair_t;

typedef struct aether_f6_frame_metrics {
    uint32_t evaluated_count;
    uint32_t marked_dynamic_count;
    uint32_t restored_static_count;
    double mean_conflict;
} aether_f6_frame_metrics_t;

int aether_f6_default_config(aether_f6_config_t* out_config);

aether_f6_rejector_t* aether_f6_create(const aether_f6_config_t* config);
void aether_f6_destroy(aether_f6_rejector_t* rejector);
int aether_f6_reset(aether_f6_rejector_t* rejector);

int aether_f6_process_frame(
    aether_f6_rejector_t* rejector,
    const aether_f6_observation_pair_t* observations, int obs_count,
    aether_gaussian_t* gaussians, int gaussian_count,
    aether_f6_frame_metrics_t* out_metrics);

int aether_f6_collect_static_indices(
    const aether_gaussian_t* gaussians, int gaussian_count,
    uint32_t* out_indices, int* inout_count);

// ─── F7: Neural Appearance Decoding (ShaderML) ────────────────────────
enum {
    AETHER_F7_BACKEND_SH_FALLBACK = 0,
    AETHER_F7_BACKEND_TINY_MLP = 1,
};

typedef struct aether_f7_runtime_caps {
    int shaderml_supported;  // 0/1
    int prefer_neural_decode;  // 0/1
    uint32_t max_parameter_count;
} aether_f7_runtime_caps_t;

typedef struct aether_f7_mlp_weights {
    uint32_t input_dim;
    uint32_t hidden_dim;
    uint32_t output_dim;
    const float* layer0_weights;
    uint32_t layer0_weight_count;
    const float* layer0_bias;
    uint32_t layer0_bias_count;
    const float* layer1_weights;
    uint32_t layer1_weight_count;
    const float* layer1_bias;
    uint32_t layer1_bias_count;
} aether_f7_mlp_weights_t;

typedef struct aether_f7_decode_input {
    aether_float3_t position;
    aether_float3_t view_dir;
    float sh_coeffs[16];
} aether_f7_decode_input_t;

typedef struct aether_f7_decode_output {
    aether_float3_t rgb;
    int backend;  // AETHER_F7_BACKEND_*
} aether_f7_decode_output_t;

typedef struct aether_f7_batch_stats {
    uint32_t sample_count;
    uint32_t parameter_count;
    float estimated_memory_saving_ratio;
    int backend;
} aether_f7_batch_stats_t;

aether_f7_decoder_t* aether_f7_create(void);
void aether_f7_destroy(aether_f7_decoder_t* decoder);

int aether_f7_set_runtime_caps(
    aether_f7_decoder_t* decoder,
    const aether_f7_runtime_caps_t* caps);

int aether_f7_set_mlp_weights(
    aether_f7_decoder_t* decoder,
    const aether_f7_mlp_weights_t* weights);

int aether_f7_decode(
    aether_f7_decoder_t* decoder,
    const aether_f7_decode_input_t* input,
    aether_f7_decode_output_t* out);

int aether_f7_decode_batch(
    aether_f7_decoder_t* decoder,
    const aether_f7_decode_input_t* inputs, int count,
    aether_f7_decode_output_t* out_results,
    aether_f7_batch_stats_t* out_stats);

// ─── F8: Per-Gaussian Uncertainty Field ───────────────────────────────
typedef struct aether_f8_config {
    float observed_decay;
    float unobserved_growth;
    float view_penalty;
    float min_uncertainty;
    float max_uncertainty;
    float belief_mix_alpha;
} aether_f8_config_t;

typedef struct aether_f8_observation {
    uint32_t gaussian_id;
    int observed;  // 0/1
    float residual;
    float view_cosine;
    aether_ds_mass_t ds_belief;
} aether_f8_observation_t;

typedef struct aether_f8_frame_stats {
    uint32_t updated_count;
    float mean_uncertainty;
    float mean_fused_confidence;
} aether_f8_frame_stats_t;

aether_f8_field_t* aether_f8_create(const aether_f8_config_t* config);
void aether_f8_destroy(aether_f8_field_t* field);
int aether_f8_reset(aether_f8_field_t* field);

int aether_f8_bootstrap(
    aether_f8_field_t* field,
    const aether_gaussian_t* gaussians, int count);

int aether_f8_process_frame(
    aether_f8_field_t* field,
    const aether_f8_observation_t* observations, int obs_count,
    aether_gaussian_t* gaussians, int gaussian_count,
    aether_f8_frame_stats_t* out_stats);

int aether_f8_query_uncertainty(
    const aether_f8_field_t* field,
    uint32_t gaussian_id, float view_cosine,
    float* out_uncertainty);

int aether_f8_fused_confidence(
    const aether_f8_field_t* field,
    uint32_t gaussian_id, float view_cosine,
    double ds_belief,
    double* out_confidence);

int aether_f8_collect_high_uncertainty(
    const aether_gaussian_t* gaussians, int gaussian_count,
    float threshold,
    uint32_t* out_indices, int* inout_count);

// ─── F9: Scene Passport & Digital Watermarking ────────────────────────
typedef struct aether_f9_watermark_config {
    uint32_t bit_count;
    uint32_t replicas_per_bit;
    float opacity_quant_step;
    float sh_quant_step;
} aether_f9_watermark_config_t;

typedef struct aether_f9_watermark_packet {
    uint8_t bits[256];  // max 2048 bits = 256 bytes
    uint32_t bit_count;
    uint8_t bits_sha256[32];
} aether_f9_watermark_packet_t;

typedef struct aether_f9_scene_passport {
    const char* scene_id;
    uint8_t merkle_root[32];
    const char* owner_id;
    uint8_t watermark_sha256[32];
    const uint8_t* canonical_json;
    uint32_t canonical_json_size;
    const uint8_t* signature;
    uint32_t signature_size;
} aether_f9_scene_passport_t;

int aether_f9_default_watermark_config(aether_f9_watermark_config_t* out_config);

int aether_f9_generate_watermark(
    const char* scene_id,
    const char* owner_id,
    uint64_t timestamp_ms,
    uint32_t bit_count,
    aether_f9_watermark_packet_t* out_packet);

int aether_f9_embed_watermark(
    const aether_f9_watermark_packet_t* packet,
    uint64_t seed,
    const aether_f9_watermark_config_t* config,
    aether_gaussian_t* gaussians, int gaussian_count,
    uint32_t* out_embedded_count);

int aether_f9_extract_watermark(
    uint64_t seed,
    const aether_f9_watermark_config_t* config,
    const aether_gaussian_t* gaussians, int gaussian_count,
    uint32_t expected_bit_count,
    aether_f9_watermark_packet_t* out_packet,
    float* out_confidence);

int aether_f9_build_passport(
    const char* scene_id,
    const char* owner_id,
    const uint8_t merkle_root[32],
    const aether_f9_watermark_packet_t* watermark,
    const uint8_t* signing_key, uint32_t key_size,
    uint8_t* out_passport_bytes, uint32_t* inout_size);

int aether_f9_verify_passport(
    const uint8_t* passport_bytes, uint32_t size,
    const uint8_t* verification_key, uint32_t key_size,
    int* out_valid);

// ─── Scaffold Patch Map ───────────────────────────────────────────────
aether_scaffold_patch_map_t* aether_scaffold_patch_map_create(void);
void aether_scaffold_patch_map_destroy(aether_scaffold_patch_map_t* map);
int aether_scaffold_patch_map_reset(aether_scaffold_patch_map_t* map);

int aether_scaffold_patch_map_upsert_unit(
    aether_scaffold_patch_map_t* map,
    const aether_scaffold_unit_t* unit,
    int32_t block_x, int32_t block_y, int32_t block_z);

int aether_scaffold_patch_map_remove_unit(
    aether_scaffold_patch_map_t* map,
    uint64_t unit_id);

int aether_scaffold_patch_map_bind_gaussian(
    aether_scaffold_patch_map_t* map,
    uint32_t gaussian_id, uint64_t unit_id);

int aether_scaffold_patch_map_unbind_gaussian(
    aether_scaffold_patch_map_t* map,
    uint32_t gaussian_id);

int aether_scaffold_patch_map_unit_count(
    const aether_scaffold_patch_map_t* map,
    uint32_t* out_count);

int aether_scaffold_patch_map_binding_count(
    const aether_scaffold_patch_map_t* map,
    uint32_t* out_count);

int aether_scaffold_patch_map_gaussian_ids_for_unit(
    const aether_scaffold_patch_map_t* map,
    uint64_t unit_id,
    uint32_t* out_gaussian_ids, int* inout_count);

// ─── DGRUT Splat Selection ────────────────────────────────────────────
typedef struct aether_dgrut_splat {
    uint32_t id;
    float depth;
    float opacity;
    float radius;
    float tri_tet_confidence;
    float view_cosine;
    float screen_coverage;
    uint32_t frames_since_birth;
} aether_dgrut_splat_t;

typedef struct aether_dgrut_budget {
    uint32_t max_splats;
    uint32_t max_bytes;
} aether_dgrut_budget_t;

typedef struct aether_dgrut_scoring_config {
    float weight_confidence;
    float weight_opacity;
    float weight_radius;
    float weight_view_angle;
    float weight_screen_coverage;
    float newborn_boost;
    uint32_t newborn_frames;
    float depth_penalty_scale;
} aether_dgrut_scoring_config_t;

typedef struct aether_dgrut_selection_result {
    uint32_t selected_count;
    float mean_opacity;
} aether_dgrut_selection_result_t;

int aether_dgrut_default_scoring_config(aether_dgrut_scoring_config_t* out_config);

int aether_dgrut_select_splats(
    const aether_dgrut_splat_t* splats, int count,
    const aether_dgrut_budget_t* budget,
    const aether_dgrut_scoring_config_t* scoring,
    aether_dgrut_splat_t* out_selected, int* inout_count,
    aether_dgrut_selection_result_t* out_result);

// KHR standard Gaussian format interop
typedef struct aether_khr_gaussian_splat {
    float position[3];
    float rotation[4];
    float scale[3];
    float opacity;
    float color[3];
} aether_khr_gaussian_splat_t;

int aether_dgrut_to_khr(
    const aether_dgrut_splat_t* splats, int count,
    aether_khr_gaussian_splat_t* out_khr);

// ─── Frustum Culling ──────────────────────────────────────────────────
typedef struct aether_frustum_plane {
    float a, b, c, d;
} aether_frustum_plane_t;

typedef struct aether_frustum_cull_result {
    uint32_t visible_count;
    uint32_t occluded_count;
    uint32_t outside_count;
    uint32_t total_blocks;
} aether_frustum_cull_result_t;

int aether_extract_frustum_planes(
    const float* view_projection_16,
    aether_frustum_plane_t out_planes[6]);

int aether_frustum_cull_aabbs(
    const aether_frustum_plane_t planes[6],
    const aether_float3_t* aabb_mins, const aether_float3_t* aabb_maxs,
    int aabb_count,
    int* out_visible_mask,
    aether_frustum_cull_result_t* out_result);

// ─── Meshlet Building ─────────────────────────────────────────────────
typedef struct aether_meshlet_bounds {
    float min_x, min_y, min_z;
    float max_x, max_y, max_z;
} aether_meshlet_bounds_t;

typedef struct aether_meshlet {
    uint32_t first_triangle_index;
    uint32_t triangle_count;
    aether_meshlet_bounds_t bounds;
    uint8_t lod_level;
    float lod_error;
} aether_meshlet_t;

typedef struct aether_meshlet_build_config {
    uint32_t min_triangles_per_meshlet;
    uint32_t max_triangles_per_meshlet;
    uint32_t lod_activation_threshold;
} aether_meshlet_build_config_t;

int aether_meshlet_default_config(aether_meshlet_build_config_t* out_config);

int aether_meshlet_build(
    const float* vertices, int vertex_count,
    const uint32_t* indices, int index_count,
    const aether_meshlet_build_config_t* config,
    aether_meshlet_t* out_meshlets, int* inout_count);

// ─── Two-Pass GPU Culling ─────────────────────────────────────────────
enum {
    AETHER_TWO_PASS_TIER_A = 0,  // Full mesh shader + HiZ
    AETHER_TWO_PASS_TIER_B = 1,  // Compute + HiZ
    AETHER_TWO_PASS_TIER_C = 2,  // CPU fallback
};

typedef struct aether_two_pass_runtime {
    int mesh_shader_supported;  // 0/1
    int gpu_hzb_supported;  // 0/1
    int compute_supported;  // 0/1
} aether_two_pass_runtime_t;

typedef struct aether_two_pass_stats {
    int tier;
    uint32_t total_meshlets;
    uint32_t frustum_rejected;
    uint32_t pass1_visible;
    uint32_t pass1_rejected;
    uint32_t pass2_recovered;
    int pass2_executed;  // 0/1
    float conservative_reject_ratio;
} aether_two_pass_stats_t;

int aether_two_pass_select_tier(
    const aether_two_pass_runtime_t* runtime,
    int* out_tier);

int aether_two_pass_cull_meshlets(
    const aether_meshlet_t* meshlets, int meshlet_count,
    const float* view_matrix_16, const float* proj_matrix_16,
    const float* hi_z_data, int hi_z_resolution,
    const aether_two_pass_runtime_t* runtime,
    uint32_t* out_visible_indices, int* inout_count,
    aether_two_pass_stats_t* out_stats);

// ─── Screen-Space Detail Selection ────────────────────────────────────
int aether_screen_detail_factor(
    const aether_scaffold_unit_t* units, int unit_count,
    const float* view_matrix_16, const float* proj_matrix_16,
    float screen_area,
    float* out_factors);

// ─── Tri-Tet Splat Projection ─────────────────────────────────────────
typedef struct aether_camera_intrinsics {
    float fx, fy, cx, cy;
    uint32_t width, height;
} aether_camera_intrinsics_t;

typedef struct aether_projected_splat {
    float u, v, depth;
    uint32_t tile_x, tile_y;
    int valid;  // 0/1
} aether_projected_splat_t;

int aether_project_tri_tet_splat(
    float x, float y, float z, float radius,
    const aether_camera_intrinsics_t* intrinsics,
    uint32_t tile_size,
    aether_projected_splat_t* out_splat);

// ─── TSDF Mesh Extraction Scheduler ───────────────────────────────────
aether_mesh_extraction_scheduler_t* aether_mesh_extraction_scheduler_create(void);
void aether_mesh_extraction_scheduler_destroy(aether_mesh_extraction_scheduler_t* scheduler);

int aether_mesh_extraction_next_budget(
    aether_mesh_extraction_scheduler_t* scheduler,
    int* out_budget);

int aether_mesh_extraction_report_cycle(
    aether_mesh_extraction_scheduler_t* scheduler,
    double elapsed_ms);

// ─── Noise-Aware Training ─────────────────────────────────────────────
// tri_tet_class uses AETHER_TRI_TET_CLASS_* enum declared above (line ~575).

typedef struct aether_noise_aware_sample {
    float photometric_residual;
    float depth_residual;
    float sigma2;
    float confidence;
    uint8_t tri_tet_class;  // AETHER_TRI_TET_CLASS_*
} aether_noise_aware_sample_t;

typedef struct aether_noise_aware_result {
    float weighted_loss;
    float weight_sum;
    uint32_t sample_count;
} aether_noise_aware_result_t;

int aether_noise_aware_compute_weight(
    const aether_noise_aware_sample_t* sample,
    float* out_weight);

int aether_noise_aware_batch_loss(
    const aether_noise_aware_sample_t* samples, int count,
    aether_noise_aware_result_t* out_result);

// ─── Core: Canonicalization ───────────────────────────────────────────
int aether_canonicalize_block(
    int32_t x, int32_t y, int32_t z,
    int32_t* out_x, int32_t* out_y, int32_t* out_z);

float aether_canonicalize_float(float value);

// ─── Core: Numeric Guard ──────────────────────────────────────────────
typedef struct aether_numerical_health {
    uint64_t nan_count;
    uint64_t inf_count;
    uint64_t guarded_scalar_count;
    uint64_t guarded_vector_count;
} aether_numerical_health_t;

int aether_numerical_health_snapshot(aether_numerical_health_t* out_health);
int aether_numerical_health_reset(void);
int aether_guard_finite_scalar(float* value);
int aether_guard_finite_vector(float* values, int count);

// ═══════════════════════════════════════════════════════════════════════
// PRMath: Mathematical Utilities
// ═══════════════════════════════════════════════════════════════════════

double aether_sigmoid(double x);
double aether_sigmoid01_from_threshold(double value, double threshold, double transition_width);
double aether_sigmoid_inverted01(double value, double threshold, double transition_width);
double aether_exp_safe(double x);
double aether_atan2_safe(double y, double x);
double aether_asin_safe(double x);
double aether_sqrt_safe(double x);
double aether_clamp01(double x);
double aether_clamp_range(double x, double lo, double hi);
int aether_is_usable(double x);

double aether_log_sigmoid(double x);
double aether_log_complement_sigmoid(double x);
double aether_softplus(double x);

int64_t aether_quantize_q01(double value);
double aether_dequantize_q01(int64_t q);
int aether_quantized_are_close(int64_t a, int64_t b, int64_t tolerance);

// ═══════════════════════════════════════════════════════════════════════
// SpatialQuantizer: Morton Code / Z-Order Curve
// ═══════════════════════════════════════════════════════════════════════

uint64_t aether_morton_encode(int32_t x, int32_t y, int32_t z);
void aether_morton_decode(uint64_t code, int32_t* out_x, int32_t* out_y, int32_t* out_z);

typedef struct aether_spatial_quantizer_config {
    float origin_x, origin_y, origin_z;
    float cell_size;
} aether_spatial_quantizer_config_t;

void aether_spatial_quantize(
    const aether_spatial_quantizer_config_t* config,
    float wx, float wy, float wz,
    int32_t* out_gx, int32_t* out_gy, int32_t* out_gz);

uint64_t aether_spatial_morton_code(
    const aether_spatial_quantizer_config_t* config,
    float wx, float wy, float wz);

// ═══════════════════════════════════════════════════════════════════════
// SpatialQuantizer: Hilbert Curve Encoding
// ═══════════════════════════════════════════════════════════════════════

uint64_t aether_hilbert_encode(int32_t x, int32_t y, int32_t z);
void aether_hilbert_decode(uint64_t code, int32_t* out_x, int32_t* out_y, int32_t* out_z);

uint64_t aether_spatial_hilbert_code(
    const aether_spatial_quantizer_config_t* config,
    float wx, float wy, float wz);

// ═══════════════════════════════════════════════════════════════════════
// TriTetMapping: Kuhn 5-Tet Decomposition
// ═══════════════════════════════════════════════════════════════════════

typedef struct aether_tri_tet_cell {
    int32_t vertex_indices[4];
    int32_t tet_index;
} aether_tri_tet_cell_t;

int aether_tri_tet_parity(int32_t bx, int32_t by, int32_t bz);

int aether_tri_tet_decompose(
    int32_t bx, int32_t by, int32_t bz,
    aether_tri_tet_cell_t out_cells[5]);

int aether_tri_tet_map_single(
    int32_t bx, int32_t by, int32_t bz,
    int local_tet_index,
    aether_tri_tet_cell_t* out_cell);

// ═══════════════════════════════════════════════════════════════════════
// GPU Abstraction Layer
// ═══════════════════════════════════════════════════════════════════════

enum {
    AETHER_GPU_STORAGE_SHARED = 0,
    AETHER_GPU_STORAGE_PRIVATE = 1,
    AETHER_GPU_STORAGE_MANAGED = 2,
};

enum {
    AETHER_GPU_BACKEND_UNKNOWN = 0,
    AETHER_GPU_BACKEND_METAL = 1,
    AETHER_GPU_BACKEND_VULKAN = 2,
    AETHER_GPU_BACKEND_OPENGLES = 3,
};

typedef struct aether_gpu_caps {
    int backend;
    uint32_t max_buffer_size;
    uint32_t max_texture_size;
    uint32_t max_compute_workgroup_size;
    uint32_t max_threadgroup_memory;
    int supports_compute;
    int supports_indirect_draw;
    int supports_shared_memory;
    int supports_half_precision;
    int supports_simd_group;
    uint32_t simd_width;
} aether_gpu_caps_t;

typedef struct aether_gpu_memory_stats {
    uint64_t allocated_bytes;
    uint64_t peak_bytes;
    uint32_t buffer_count;
    uint32_t texture_count;
} aether_gpu_memory_stats_t;

typedef struct aether_gpu_timestamp {
    double gpu_time_ms;
    double cpu_submit_ms;
    double cpu_complete_ms;
} aether_gpu_timestamp_t;

// ─── Opaque handle typedefs for GPU objects ───
typedef struct aether_gpu_device aether_gpu_device_t;
typedef struct aether_gpu_command_buffer aether_gpu_command_buffer_t;
typedef struct aether_gpu_compute_encoder aether_gpu_compute_encoder_t;
typedef struct aether_gpu_render_encoder aether_gpu_render_encoder_t;

// ─── Lightweight handle typedefs (uint32_t-based, matching C++ GPUBufferHandle etc.) ───
typedef uint32_t aether_gpu_buffer_handle_t;
typedef uint32_t aether_gpu_texture_handle_t;
typedef uint32_t aether_gpu_shader_handle_t;
typedef uint32_t aether_gpu_render_pipeline_handle_t;
typedef uint32_t aether_gpu_compute_pipeline_handle_t;

// ─── GPU enumerations ───
enum { AETHER_GPU_LOAD_CLEAR=0, AETHER_GPU_LOAD_LOAD=1, AETHER_GPU_LOAD_DONT_CARE=2 };
enum { AETHER_GPU_STORE_STORE=0, AETHER_GPU_STORE_DONT_CARE=1 };
enum { AETHER_GPU_PRIMITIVE_TRIANGLE=0, AETHER_GPU_PRIMITIVE_TRIANGLE_STRIP=1, AETHER_GPU_PRIMITIVE_LINE=2, AETHER_GPU_PRIMITIVE_POINT=3 };
enum { AETHER_GPU_CULL_NONE=0, AETHER_GPU_CULL_FRONT=1, AETHER_GPU_CULL_BACK=2 };
enum { AETHER_GPU_WINDING_CW=0, AETHER_GPU_WINDING_CCW=1 };
enum { AETHER_GPU_SHADER_VERTEX=0, AETHER_GPU_SHADER_FRAGMENT=1, AETHER_GPU_SHADER_COMPUTE=2 };
enum { AETHER_GPU_FORMAT_RGBA8=0, AETHER_GPU_FORMAT_RGBA16F=1, AETHER_GPU_FORMAT_RGBA32F=2, AETHER_GPU_FORMAT_R32F=3, AETHER_GPU_FORMAT_DEPTH32F=4, AETHER_GPU_FORMAT_R8=5, AETHER_GPU_FORMAT_RG16F=6 };
enum { AETHER_GPU_BUFFER_VERTEX=1, AETHER_GPU_BUFFER_INDEX=2, AETHER_GPU_BUFFER_UNIFORM=4, AETHER_GPU_BUFFER_STORAGE=8 };
enum { AETHER_GPU_TEXTURE_SAMPLE=1, AETHER_GPU_TEXTURE_RENDER_TARGET=2, AETHER_GPU_TEXTURE_STORAGE=4 };

// ─── GPU descriptor structs ───
typedef struct {
    uint32_t size;
    int storage_mode; // AETHER_GPU_STORAGE_*
    uint32_t usage;   // AETHER_GPU_BUFFER_* flags
} aether_gpu_buffer_desc_t;

typedef struct {
    uint32_t width, height, depth;
    int format;       // AETHER_GPU_FORMAT_*
    uint32_t usage;   // AETHER_GPU_TEXTURE_* flags
    int storage_mode; // AETHER_GPU_STORAGE_*
} aether_gpu_texture_desc_t;

typedef struct {
    float x, y, width, height, near_depth, far_depth;
} aether_gpu_viewport_t;

typedef struct {
    uint32_t x, y, width, height;
} aether_gpu_scissor_rect_t;

typedef struct {
    aether_gpu_texture_handle_t color_texture;
    aether_gpu_texture_handle_t depth_texture;
    int color_load_action;
    int color_store_action;
    int depth_load_action;
    int depth_store_action;
    float clear_color[4];
    float clear_depth;
} aether_gpu_render_target_desc_t;

// ─── GPU Device lifecycle ───
aether_gpu_device_t* aether_gpu_device_create_null(void);
void aether_gpu_device_destroy(aether_gpu_device_t* device);
int aether_gpu_device_get_backend(const aether_gpu_device_t* device);
int aether_gpu_device_get_caps(const aether_gpu_device_t* device, aether_gpu_caps_t* out);
int aether_gpu_device_get_memory_stats(const aether_gpu_device_t* device, aether_gpu_memory_stats_t* out);
int aether_gpu_device_wait_idle(aether_gpu_device_t* device);

// ─── GPU Buffer ───
aether_gpu_buffer_handle_t aether_gpu_buffer_create(aether_gpu_device_t* device, const aether_gpu_buffer_desc_t* desc);
void aether_gpu_buffer_destroy(aether_gpu_device_t* device, aether_gpu_buffer_handle_t handle);
void* aether_gpu_buffer_map(aether_gpu_device_t* device, aether_gpu_buffer_handle_t handle);
void aether_gpu_buffer_unmap(aether_gpu_device_t* device, aether_gpu_buffer_handle_t handle);
int aether_gpu_buffer_update(aether_gpu_device_t* device, aether_gpu_buffer_handle_t handle, const void* data, uint32_t offset, uint32_t size);

// ─── GPU Texture ───
aether_gpu_texture_handle_t aether_gpu_texture_create(aether_gpu_device_t* device, const aether_gpu_texture_desc_t* desc);
void aether_gpu_texture_destroy(aether_gpu_device_t* device, aether_gpu_texture_handle_t handle);
int aether_gpu_texture_update(aether_gpu_device_t* device, aether_gpu_texture_handle_t handle, const void* data, uint32_t width, uint32_t height, uint32_t bytes_per_row);

// ─── GPU Shader & Pipeline ───
aether_gpu_shader_handle_t aether_gpu_shader_load(aether_gpu_device_t* device, const char* name, int stage);
void aether_gpu_shader_destroy(aether_gpu_device_t* device, aether_gpu_shader_handle_t handle);
aether_gpu_render_pipeline_handle_t aether_gpu_render_pipeline_create(aether_gpu_device_t* device, aether_gpu_shader_handle_t vs, aether_gpu_shader_handle_t fs, const aether_gpu_render_target_desc_t* target);
void aether_gpu_render_pipeline_destroy(aether_gpu_device_t* device, aether_gpu_render_pipeline_handle_t handle);
aether_gpu_compute_pipeline_handle_t aether_gpu_compute_pipeline_create(aether_gpu_device_t* device, aether_gpu_shader_handle_t cs);
void aether_gpu_compute_pipeline_destroy(aether_gpu_device_t* device, aether_gpu_compute_pipeline_handle_t handle);

// ─── GPU Command Buffer ───
aether_gpu_command_buffer_t* aether_gpu_command_buffer_create(aether_gpu_device_t* device);
void aether_gpu_command_buffer_destroy(aether_gpu_command_buffer_t* buf);
int aether_gpu_command_buffer_commit(aether_gpu_command_buffer_t* buf);
int aether_gpu_command_buffer_wait(aether_gpu_command_buffer_t* buf);
int aether_gpu_command_buffer_had_error(const aether_gpu_command_buffer_t* buf);

// ─── GPU Compute Encoder ───
aether_gpu_compute_encoder_t* aether_gpu_compute_encoder_create(aether_gpu_command_buffer_t* buf);
void aether_gpu_compute_encoder_destroy(aether_gpu_compute_encoder_t* enc);
int aether_gpu_compute_set_pipeline(aether_gpu_compute_encoder_t* enc, aether_gpu_compute_pipeline_handle_t p);
int aether_gpu_compute_set_buffer(aether_gpu_compute_encoder_t* enc, aether_gpu_buffer_handle_t buf, uint32_t offset, uint32_t index);
int aether_gpu_compute_set_texture(aether_gpu_compute_encoder_t* enc, aether_gpu_texture_handle_t tex, uint32_t index);
int aether_gpu_compute_dispatch(aether_gpu_compute_encoder_t* enc, uint32_t gx, uint32_t gy, uint32_t gz, uint32_t tx, uint32_t ty, uint32_t tz);
int aether_gpu_compute_end(aether_gpu_compute_encoder_t* enc);

// ─── GPU Render Encoder ───
aether_gpu_render_encoder_t* aether_gpu_render_encoder_create(aether_gpu_command_buffer_t* buf, const aether_gpu_render_target_desc_t* target);
void aether_gpu_render_encoder_destroy(aether_gpu_render_encoder_t* enc);
int aether_gpu_render_set_pipeline(aether_gpu_render_encoder_t* enc, aether_gpu_render_pipeline_handle_t p);
int aether_gpu_render_set_vertex_buffer(aether_gpu_render_encoder_t* enc, aether_gpu_buffer_handle_t buf, uint32_t offset, uint32_t index);
int aether_gpu_render_set_viewport(aether_gpu_render_encoder_t* enc, const aether_gpu_viewport_t* vp);
int aether_gpu_render_set_scissor(aether_gpu_render_encoder_t* enc, const aether_gpu_scissor_rect_t* r);
int aether_gpu_render_set_cull_mode(aether_gpu_render_encoder_t* enc, int mode);
int aether_gpu_render_draw(aether_gpu_render_encoder_t* enc, int primitive, uint32_t vertex_start, uint32_t vertex_count);
int aether_gpu_render_draw_indexed(aether_gpu_render_encoder_t* enc, int primitive, uint32_t index_count, aether_gpu_buffer_handle_t index_buf, uint32_t offset);
int aether_gpu_render_draw_instanced(aether_gpu_render_encoder_t* enc, int primitive, uint32_t vertex_count, uint32_t instance_count);
int aether_gpu_render_end(aether_gpu_render_encoder_t* enc);


// ===========================================================================
// Evidence State Machine (S0-S5 global coverage state)
// ===========================================================================

/// Color state enum matching C++ ColorState.
///   0 = kBlack (S0), 1 = kDarkGray (S1/S2), 2 = kLightGray (S3),
///   3 = kWhite (S4), 4 = kOriginal (S5), 255 = kUnknown.
typedef int aether_color_state_t;

#define AETHER_COLOR_STATE_BLACK      0
#define AETHER_COLOR_STATE_DARK_GRAY  1
#define AETHER_COLOR_STATE_LIGHT_GRAY 2
#define AETHER_COLOR_STATE_WHITE      3
#define AETHER_COLOR_STATE_ORIGINAL   4
#define AETHER_COLOR_STATE_UNKNOWN    255

typedef struct aether_evidence_state_machine_config {
    double s0_to_s1_threshold;      // default 0.10
    double s1_to_s2_threshold;      // default 0.25
    double s2_to_s3_threshold;      // default 0.50
    double s3_to_s4_threshold;      // default 0.75
    double s4_to_s5_threshold;      // default 0.88
    /* S5 information-theoretic gate thresholds */
    double s5_min_choquet;              // default 0.72
    double s5_min_dimension_score;      // default 0.45
    double s5_max_uncertainty_width;    // default 0.15
    double s5_min_high_obs_ratio;       // default 0.30
    double s5_max_lyapunov_rate;        // default 0.05
} aether_evidence_state_machine_config_t;

typedef struct aether_evidence_state_machine_input {
    double coverage;                    // [0,1] DS Belief coverage (lower bound)
    double plausibility_coverage;       // [0,1] DS Plausibility (upper bound)
    double uncertainty_width;           // Pl - Bel
    double high_observation_ratio;      // L5+ ratio
    double lyapunov_rate;               // |dV/dt|/V convergence rate
    double dim_scores[10];              // 10 dimensional raw scores
} aether_evidence_state_machine_input_t;

typedef struct aether_evidence_state_machine_result {
    aether_color_state_t state;           // Current state after evaluation
    aether_color_state_t previous_state;  // State before this evaluation
    int transitioned;                     // 1 if state changed, 0 otherwise
    /* Certification diagnostics */
    int coverage_cert;                    // 0=Certified, 1=Uncertain, 2=Impossible
    int choquet_cert;                     // 0=Certified, 1=Uncertain, 2=Impossible
    double choquet_value;                 // Actual Choquet integral value
    double min_super_dim;                 // Minimum of 5 super-dimensions
    double certification_margin;          // Min margin across all 6 gates
} aether_evidence_state_machine_result_t;

int aether_evidence_state_machine_default_config(
    aether_evidence_state_machine_config_t* out_config);
int aether_evidence_state_machine_create(
    const aether_evidence_state_machine_config_t* config_or_null,
    aether_evidence_state_machine_t** out_machine);
int aether_evidence_state_machine_destroy(
    aether_evidence_state_machine_t* machine);
int aether_evidence_state_machine_reset(
    aether_evidence_state_machine_t* machine);
int aether_evidence_state_machine_evaluate(
    aether_evidence_state_machine_t* machine,
    const aether_evidence_state_machine_input_t* input,
    aether_evidence_state_machine_result_t* out_result);
int aether_evidence_state_machine_current_state(
    const aether_evidence_state_machine_t* machine,
    aether_color_state_t* out_state);

/* ═══════════════════════════════════════════════════════════════════════════ */
/* Mesh Topology Diagnostics (post-processing, not a gate)                   */
/* ═══════════════════════════════════════════════════════════════════════════ */

typedef struct aether_mesh_topology_diagnostics {
    int64_t vertex_count;
    int64_t edge_count;
    int64_t face_count;
    int32_t euler_characteristic;
    int32_t expected_euler;
    int topology_ok;               /* 1 if chi == expected_euler */
    int32_t boundary_edge_count;
} aether_mesh_topology_diagnostics_t;

int aether_compute_mesh_topology(
    const uint32_t* indices,
    uint64_t index_count,
    uint64_t vertex_count,
    aether_mesh_topology_diagnostics_t* out);

/* ═══════════════════════════════════════════════════════════════════════════ */
/* Fiedler Value (algebraic connectivity, triggered at S4->S5 only)          */
/* ═══════════════════════════════════════════════════════════════════════════ */

typedef struct aether_fiedler_result {
    double fiedler_value;
    int computed;
    int iterations_used;
} aether_fiedler_result_t;

int aether_compute_fiedler_value(
    const uint32_t* indices,
    uint64_t index_count,
    uint64_t vertex_count,
    int max_iterations,
    aether_fiedler_result_t* out);

#ifdef __cplusplus
}
#endif

#endif  // AETHER_TSDF_C_H
