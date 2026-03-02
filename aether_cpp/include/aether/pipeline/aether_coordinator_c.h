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
    size_t max_gaussians;                      // Default: 1000000 (1M Student-t ≈ 5M Gaussian)
    size_t max_iterations;                     // Default: 20000 (3DGS-MCMC: 30K)
    uint32_t render_width;                     // Default: 800
    uint32_t render_height;                    // Default: 600

    // Thermal — predictive management
    float thermal_recovery_delay_s;            // Default: 3.0
    float thermal_transition_s;                // Default: 1.5

    // Low-light — more lenient with DAv2 depth
    float low_light_brightness_threshold;      // Default: 40.0
    float low_light_blur_strictness;           // Default: 1.5

    // Rendering stability
    uint32_t max_consecutive_gpu_errors;       // Default: 5
    float nan_check_interval_steps;            // Default: 10

    // Point cloud → 3DGS blend — faster transition
    float blend_start_splat_count;             // Default: 500
    float blend_end_splat_count;               // Default: 30000

    // Depth inference (DAv2 dual-model cross-validation)
    // Path to compiled .mlmodelc directory on iOS/macOS.
    // e.g., Bundle.main.resourcePath + "/DepthAnythingV2Small.mlmodelc"
    // NULL → that model unavailable. Both NULL → fallback to MVS-only.
    const char* depth_model_path;              // Small model (primary). Default: NULL
    const char* depth_model_path_large;        // Large model (cross-validation). Default: NULL
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
    size_t converged_regions;
    size_t total_regions;
    int training_active;         // 0 or 1
    int scan_complete;           // 0 or 1
    int has_s6_quality;          // 0 or 1 — ANY TSDF block reached S6+ (training gate)
    int thermal_level;           // 0-3

    // ── 区域化训练状态 (破镜重圆 progressive reveal) ──
    uint32_t training_region_total;       // Total regions formed (no limit)
    uint32_t training_region_completed;   // Converged + revealed
    uint16_t active_region_id;            // Currently training (0xFFFF = none)
    float active_region_progress;         // Current region progress [0, 1]
    int is_animating;                     // 0 or 1 — any region doing fly-in
    uint32_t staged_count;                // Regions waiting to fly in
} aether_evidence_snapshot_t;

/// Training progress (from existing streaming pipeline).
typedef struct {
    size_t step;
    size_t total_steps;
    float loss;
    size_t num_gaussians;
    size_t converged_regions;
    size_t total_regions;
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

/// Export accumulated point cloud as Gaussian-format PLY for 3D viewing.
int aether_pipeline_coordinator_export_point_cloud_ply(
    aether_pipeline_coordinator_t* coordinator,
    const char* path);

// ═══════════════════════════════════════════════════════════════════════
// D4: Temporal Region State API ("破镜重圆" Progressive Reveal)
// ═══════════════════════════════════════════════════════════════════════
// Swift reads region state to control per-region fade-in rendering.
// All queries are lock-free reads.

/// Temporal region state (C-safe mirror).
typedef struct {
    uint32_t start_frame;
    uint32_t end_frame;
    uint32_t steps_trained;
    float best_loss;
    int geometry_ready;      // 0 or 1
    int detail_ready;        // 0 or 1
    float fade_alpha;        // [0, 1] — current fade-in progress
} aether_temporal_region_t;

/// Get the number of trained temporal regions.
int aether_get_trained_region_count(
    const aether_pipeline_coordinator_t* coordinator);

/// Get the state of a specific temporal region.
/// Returns 0 on success, -1 on error (invalid index).
int aether_get_region_state(
    const aether_pipeline_coordinator_t* coordinator,
    int region_idx,
    aether_temporal_region_t* out);

/// Check if a region's geometry is ready for rendering.
/// Returns 1 if ready, 0 if not, -1 on error.
int aether_get_region_geometry_ready(
    const aether_pipeline_coordinator_t* coordinator,
    int region_idx);

/// Get the fade-in alpha for a region.
/// Returns alpha [0, 1], or -1.0 on error.
float aether_get_region_fade_alpha(
    const aether_pipeline_coordinator_t* coordinator,
    int region_idx);

// ═══════════════════════════════════════════════════════════════════════
// 区域化训练: Viewer Entry Signal
// ═══════════════════════════════════════════════════════════════════════
// Call when user enters the 3D viewer black space.
// Triggers sequential fly-in animation of completed regions.

void aether_pipeline_coordinator_signal_viewer_entered(
    aether_pipeline_coordinator_t* coordinator);

#ifdef __cplusplus
}
#endif

#endif  // AETHER_PIPELINE_COORDINATOR_C_H
