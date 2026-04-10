// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_PIPELINE_COORDINATOR_C_H
#define AETHER_PIPELINE_COORDINATOR_C_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ═══════════════════════════════════════════════════════════════════════
// Pipeline Coordinator C API
// ═══════════════════════════════════════════════════════════════════════
// Swift bridge for the PipelineCoordinator (3-thread unified pipeline).
// All functions are non-blocking unless noted.

typedef struct aether_pipeline_coordinator_s aether_pipeline_coordinator_t;

/// Configuration for pipeline coordinator.
/// Defaults calibrated against SOTA (Sprint 3). See aether_coordinator_default_config().
typedef struct {
    // Point cloud — surpass Polycam (6M) and Scaniverse (1-5M)
    uint32_t max_point_cloud_vertices;         // Default: 10000000 (10M)

    // Training — start early with depth priors
    size_t min_frames_to_start_training;       // Default: 8 (PocketGS needs 50)
    size_t training_batch_size;                // Default: 4
    float low_quality_loss_weight;             // Default: 0.3

    // Frame selection — dense sampling for coverage
    float min_displacement_m;                  // Default: 0.02 (PocketGS: 0.05)
    float min_blur_score;                      // Default: 0.15 (depth priors compensate blur)
    float min_quality_score;                   // Default: 0.08 (permissive)

    // Training params — Student-t + MCMC for S6+ quality
    size_t max_gaussians;                      // Default: 100M (no cap); device preset determines real limit
    size_t max_iterations;                     // Default: 3000 (global engine: TSDF init + MCMC converges fast)
    uint32_t render_width;                     // Default: 800
    uint32_t render_height;                    // Default: 600
    uint32_t local_preview_mode;              // ABI-compat flag: 0 (cloud/default), 1 = bounded on-device subject-first monocular mode

    // Thermal — predictive management
    float thermal_recovery_delay_s;            // Default: 3.0
    float thermal_transition_s;                // Default: 1.5

    // Low-light — more lenient with DAv2 depth
    float low_light_brightness_threshold;      // Default: 40.0
    float low_light_blur_strictness;           // Default: 1.5

    // Rendering stability
    uint32_t max_consecutive_gpu_errors;       // Default: 5
    float nan_check_interval_steps;            // Default: 10

    // TSDF→Gaussian: geometry-focused gate (has_surface + avg_weight ≥ 8).
    // composite_quality (0.85 S6+) is display-only. See pipeline_coordinator.cpp.
    // (No configurable threshold — gate is geometry-based, not quality-score-based.)

    // Point cloud → 3DGS blend — faster transition
    float blend_start_splat_count;             // Default: 500
    float blend_end_splat_count;               // Default: 30000

    // Depth inference (DAv2 dual-model cross-validation)
    // Path to compiled .mlmodelc directory on iOS/macOS.
    // e.g., Bundle.main.resourcePath + "/DepthAnythingV2Small.mlmodelc"
    // NULL → that model unavailable. Both NULL → fallback to MVS-only.
    const char* depth_model_path;              // Small model (primary). Default: NULL
    const char* depth_model_path_large;        // Large model (cross-validation). Default: NULL
    const char* depth_model_path_video;        // Video model (imported-video local subject-first). Default: NULL
    uint32_t large_model_interval;             // Run Large every N frames. Default: 5
} aether_coordinator_config_t;

/// Evidence snapshot (lock-free read).
typedef struct {
    float coverage;              // [0, 1]
    float overall_quality;       // [0, 1]
    float training_progress;     // [0, 1]
    size_t frame_count;
    size_t selected_frames;
    size_t min_frames_needed;    // min_frames_to_start_training (for HUD)
    size_t num_gaussians;
    int training_active;         // 0 or 1
    int scan_complete;           // 0 or 1
    int has_s6_quality;          // 0 or 1 — ANY TSDF block reached S6+ (display only, 0.85)
    int thermal_level;           // 0-3

    // ── 全局训练状态 ──
    float training_loss;                  // Current training loss
    size_t training_step;                 // Current global training step
    size_t assigned_blocks;               // Surface blocks → Gaussians (geometry gate, NOT S6+)
    size_t pending_gaussian_count;        // Gaussians waiting in queue for engine
    size_t retained_export_gaussians;     // Current retained export snapshot size
    size_t peak_training_gaussians;       // Peak live trainer gaussian count
    size_t peak_working_set_gaussians;    // Peak trainer + pending working set
    size_t peak_retained_export_gaussians; // Peak retained export snapshot size

    // Local preview diagnostics (internal archival only)
    uint64_t preview_elapsed_ms;
    uint64_t preview_phase_depth_ms;
    uint64_t preview_phase_seed_ms;
    uint64_t preview_phase_refine_ms;
    uint32_t preview_depth_batches_submitted;
    uint32_t preview_depth_results_ready;
    uint32_t preview_depth_reuse_frames;
    uint32_t preview_prefilter_accepts;
    uint32_t preview_prefilter_brightness_rejects;
    uint32_t preview_prefilter_blur_rejects;
    uint32_t preview_keyframe_gate_accepts;
    uint32_t preview_keyframe_gate_rejects;
    uint32_t preview_imported_frames_evaluated;
    uint32_t preview_imported_low_parallax_rejects;
    uint32_t preview_imported_near_duplicate_rejects;
    uint32_t preview_imported_selected_keyframes;
    float preview_imported_selected_translation_mean_mm;
    float preview_imported_selected_rotation_mean_deg;
    float preview_imported_selected_overlap_mean;
    uint32_t preview_seed_candidates;
    uint32_t preview_seed_accepted;
    uint32_t preview_seed_rejected;
    float preview_seed_quality_mean;
    uint32_t preview_frames_enqueued;
    uint32_t preview_frames_ingested;
    uint32_t preview_frame_backlog;
} aether_evidence_snapshot_t;

/// Training progress (from existing streaming pipeline).
typedef struct {
    size_t step;
    size_t total_steps;
    float loss;
    size_t num_gaussians;
    int is_complete;
} aether_coordinator_training_progress_t;

/// Quality overlay vertex (C++ generated, surface-aligned quad, 32 bytes).
/// Reverse logic: quality=0 → red overlay (needs scanning), quality=1 → transparent (S6+ ready).
typedef struct {
    float position[3];   // World space
    float normal[3];     // Surface normal (for oriented quad rendering)
    float size;          // Quad half-size in world units (meters)
    float quality;       // Composite quality [0,1] — shader maps to color + alpha
} aether_overlay_vertex_t;

/// Render data for Metal pipeline (point cloud + splat + quality overlay).
/// Pointers are valid until next call to get_render_data().
typedef struct {
    // Point cloud vertices: [x,y,z, r,g,b, size, alpha] × N (32 bytes each)
    const float* point_cloud_vertices;
    uint32_t point_cloud_count;
    float point_cloud_alpha;             // Global alpha [0,1], fades as 3DGS grows

    // Splats (packed for GPU, 16 bytes each) — reserved for future use
    const void* packed_splats;
    uint32_t splat_count;

    // Quality overlay (C++ generated billboard vertices, ~63KB)
    const aether_overlay_vertex_t* overlay_vertices;
    uint32_t overlay_count;

    // TSDF active block count (scan coverage diagnostic)
    uint32_t tsdf_block_count;
} aether_render_data_t;

/// Fill config with defaults.
int aether_coordinator_default_config(aether_coordinator_config_t* config);

/// Create pipeline coordinator.
/// gpu_device_ptr: opaque pointer to GPUDevice
/// splat_engine_ptr: opaque pointer to SplatRenderEngine
aether_pipeline_coordinator_t* aether_pipeline_coordinator_create(
    void* gpu_device_ptr,
    void* splat_engine_ptr,
    const aether_coordinator_config_t* config);

/// Destroy coordinator (blocks until threads stop).
void aether_pipeline_coordinator_destroy(
    aether_pipeline_coordinator_t* coordinator);

/// Submit frame from main thread (<0.3ms, non-blocking).
/// Returns: 0=accepted, 1=dropped (queue full).
int aether_pipeline_coordinator_on_frame(
    aether_pipeline_coordinator_t* coordinator,
    const uint8_t* rgba, uint32_t w, uint32_t h,
    const float* transform,          // float[16], column-major 4x4
    const float* intrinsics,         // float[9], 3x3 camera matrix
    const float* feature_points_xyz, // float[N*3], ARKit feature points
    uint32_t feature_count,
    const float* ne_depth,           // float[dw*dh], DAv2 depth (NULL if unavailable)
    uint32_t ne_depth_w,
    uint32_t ne_depth_h,
    const float* lidar_depth,        // float[lw*lh], LiDAR depth (NULL if no LiDAR)
    uint32_t lidar_w,
    uint32_t lidar_h,
    int thermal_state);              // ProcessInfo.ThermalState raw value

/// Submit imported-video frame for local subject-first processing using native bootstrap pose/intrinsics.
/// Returns: 0=accepted, 1=dropped (queue full).
int aether_pipeline_coordinator_on_imported_video_frame(
    aether_pipeline_coordinator_t* coordinator,
    const uint8_t* rgba, uint32_t w, uint32_t h,
    const float* intrinsics,         // optional float[9], 3x3 camera matrix
    int intrinsics_source,           // 1=real, 2=metadata_35mm, 3=colmap_default
    double timestamp_seconds,
    uint32_t frame_index,
    uint32_t total_frames,
    int thermal_state);

/// Get latest evidence snapshot (lock-free read).
int aether_pipeline_coordinator_get_snapshot(
    aether_pipeline_coordinator_t* coordinator,
    aether_evidence_snapshot_t* out);

/// Signal scan completion. Training continues to convergence.
int aether_pipeline_coordinator_finish_scanning(
    aether_pipeline_coordinator_t* coordinator);

/// Set thermal state (thread-safe).
void aether_pipeline_coordinator_set_thermal(
    aether_pipeline_coordinator_t* coordinator,
    int level);

/// Set whether the host app is currently foreground-active.
/// Local-preview training pauses GPU refine while inactive.
void aether_pipeline_coordinator_set_foreground_active(
    aether_pipeline_coordinator_t* coordinator,
    int active);

/// Request additional training iterations after scan.
int aether_pipeline_coordinator_enhance(
    aether_pipeline_coordinator_t* coordinator,
    size_t extra_iterations);

/// Wait for training to reach minimum quality before export.
/// Blocks until training reaches min_steps or timeout_seconds elapses.
/// Call after finish_scanning() and before export_ply().
/// Returns the actual training step count reached.
size_t aether_pipeline_coordinator_wait_for_training(
    aether_pipeline_coordinator_t* coordinator,
    size_t min_steps,
    double timeout_seconds);

/// Check if training is active (lock-free).
int aether_pipeline_coordinator_is_training(
    const aether_pipeline_coordinator_t* coordinator);

/// Service imported-video local subject-first bootstrap work (async depth prior polling).
int aether_pipeline_coordinator_service_local_subject_first_bootstrap(
    aether_pipeline_coordinator_t* coordinator);

/// Compatibility wrapper for older local_preview naming.
/// Returns 1 once a usable cached depth prior exists, 0 otherwise.
int aether_pipeline_coordinator_service_local_preview_bootstrap(
    aether_pipeline_coordinator_t* coordinator);

/// Check if training is running on GPU (1) or CPU fallback (0).
/// Returns -1 if coordinator is invalid, 0 before training starts.
/// Use this to detect GPU shader loading failures and surface to UI.
int aether_pipeline_coordinator_is_gpu_training(
    const aether_pipeline_coordinator_t* coordinator);

/// Get training progress (lock-free).
int aether_pipeline_coordinator_get_training_progress(
    const aether_pipeline_coordinator_t* coordinator,
    aether_coordinator_training_progress_t* out);

/// Get render data for Metal pipeline (lock-free read from triple buffers).
/// Main thread only. Pointers valid until next call.
int aether_pipeline_coordinator_get_render_data(
    aether_pipeline_coordinator_t* coordinator,
    aether_render_data_t* out);

/// Export final PLY (may block briefly).
int aether_pipeline_coordinator_export_ply(
    aether_pipeline_coordinator_t* coordinator,
    const char* path);

/// Copy TSDF surface sample positions as tightly packed xyz triplets.
/// Returns the number of points written to out_xyz.
size_t aether_pipeline_coordinator_copy_surface_points_xyz(
    aether_pipeline_coordinator_t* coordinator,
    float* out_xyz,
    size_t max_points);

#ifdef __cplusplus
}
#endif

#endif  // AETHER_PIPELINE_COORDINATOR_C_H
