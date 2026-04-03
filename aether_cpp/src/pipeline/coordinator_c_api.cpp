// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/pipeline/aether_coordinator_c.h"
#include "aether/pipeline/pipeline_coordinator.h"
#include "aether/render/gpu_device.h"
#include "aether/splat/splat_render_engine.h"

// ═══════════════════════════════════════════════════════════════════════
// Pipeline Coordinator C API Implementation
// ═══════════════════════════════════════════════════════════════════════

// Must match layout in metal_c_api.mm and splat_c_api.cpp (single-pointer wrappers).
struct aether_gpu_device {
    aether::render::GPUDevice* impl;
};

struct aether_splat_engine {
    aether::splat::SplatRenderEngine* impl;
    aether::render::GPUDevice* device;  // Must match splat_c_api.cpp layout
};

struct aether_pipeline_coordinator_s {
    aether::pipeline::PipelineCoordinator* coordinator;
};

extern "C" {

int aether_coordinator_default_config(aether_coordinator_config_t* config) {
    if (!config) return -1;

    // ═══════════════════════════════════════════════════════════════
    // C API defaults — calibrated against SOTA benchmarks (Sprint 3)
    // ═══════════════════════════════════════════════════════════════
    // These are conservative defaults. DevicePreset overrides per-tier.
    // Competitors surpassed:
    //   PocketGS: 168K pts, 500 iters, 23.5dB → we target 10M pts, 20K iters, ≥31dB
    //   Polycam:  5-6M pts (cloud) → we do 10M+ on-device
    //   3DGS-MCMC: 30K iters → we match with Student-t for faster convergence

    // Point cloud accumulation: 10M (surpass Polycam's 6M by 67%)
    // With 5mm spatial hash dedup, this gives ~50pts/cm³ density
    config->max_point_cloud_vertices = 10000000;  // 10M — S6+ density target

    // Training: start ASAP for fastest S6+ — 4 frames is enough for DAv2 init + MVS
    config->min_frames_to_start_training = 4;     // 4 frames (was 8; PocketGS: 50)
    config->training_batch_size = 4;
    config->low_quality_loss_weight = 0.3f;

    // Frame selection: aggressive acquisition for dense coverage
    // PocketGS: displacement=0.05m. We go lower for more training data.
    config->min_displacement_m = 0.02f;           // 2cm — denser frame sampling
    config->min_blur_score = 0.15f;               // Accept more frames (DAv2 depth compensates blur)
    config->min_quality_score = 0.08f;            // Very permissive (more data > less noise)

    // Training budget: no artificial cap — device preset determines real limit
    config->max_gaussians = 100000000;            // 100M = unlimited; preset caps to device capacity
    config->max_iterations = 3000;                // Global engine: TSDF init + MCMC converges fast
    config->render_width = 800;                   // Higher than PocketGS
    config->render_height = 600;
    config->local_preview_mode = 0;

    // Thermal: robust recovery with predictive management
    config->thermal_recovery_delay_s = 3.0f;      // Faster recovery (was 5.0)
    config->thermal_transition_s = 1.5f;          // Faster transition (was 2.0)

    // Low-light adaptation: more lenient with DAv2 depth supervision
    config->low_light_brightness_threshold = 40.0f;  // Lower threshold (DAv2 handles dim scenes)
    config->low_light_blur_strictness = 1.5f;        // Less strict (was 2.0)

    // Rendering stability
    config->max_consecutive_gpu_errors = 5;       // More tolerance (was 3)
    config->nan_check_interval_steps = 10.0f;

    // TSDF→Gaussian: geometry-based gate (has_surface + avg_weight ≥ 8), no quality score threshold

    // Point cloud → 3DGS transition: faster blend
    config->blend_start_splat_count = 500.0f;     // Start blending sooner (was 1000)
    config->blend_end_splat_count = 30000.0f;     // Fully 3DGS sooner (was 50000)

    // Depth inference (DAv2 dual-model cross-validation)
    config->depth_model_path = nullptr;
    config->depth_model_path_large = nullptr;
    config->depth_model_path_video = nullptr;
    config->large_model_interval = 5;

    return 0;
}

aether_pipeline_coordinator_t* aether_pipeline_coordinator_create(
    void* gpu_device_ptr,
    void* splat_engine_ptr,
    const aether_coordinator_config_t* config) {

    if (!gpu_device_ptr || !splat_engine_ptr || !config) return nullptr;

    // Both pointers are opaque C wrappers — extract the impl pointers.
    auto* device_wrapper = static_cast<aether_gpu_device*>(gpu_device_ptr);
    auto* engine_wrapper = static_cast<aether_splat_engine*>(splat_engine_ptr);
    auto* device = device_wrapper->impl;
    auto* renderer = engine_wrapper->impl;
    if (!device || !renderer) return nullptr;

    // Convert C config to C++ config
    aether::pipeline::CoordinatorConfig cpp_config;
    cpp_config.max_point_cloud_vertices = config->max_point_cloud_vertices;
    cpp_config.min_frames_to_start_training = config->min_frames_to_start_training;
    cpp_config.training_batch_size = config->training_batch_size;
    cpp_config.low_quality_loss_weight = config->low_quality_loss_weight;

    cpp_config.frame_selection.min_displacement_m = config->min_displacement_m;
    cpp_config.frame_selection.min_blur_score = config->min_blur_score;
    cpp_config.frame_selection.min_quality_score = config->min_quality_score;

    cpp_config.training.max_gaussians = config->max_gaussians;
    cpp_config.training.max_iterations = config->max_iterations;
    cpp_config.training.render_width = config->render_width;
    cpp_config.training.render_height = config->render_height;
    cpp_config.local_preview_mode = config->local_preview_mode != 0;

    cpp_config.thermal.recovery_delay_s = config->thermal_recovery_delay_s;
    cpp_config.thermal.transition_duration_s = config->thermal_transition_s;

    cpp_config.low_light_brightness_threshold = config->low_light_brightness_threshold;
    cpp_config.low_light_blur_strictness = config->low_light_blur_strictness;
    cpp_config.max_consecutive_gpu_errors = config->max_consecutive_gpu_errors;
    cpp_config.nan_check_interval_steps = config->nan_check_interval_steps;
    // TSDF→Gaussian gate is geometry-based (has_surface + avg_weight), no configurable threshold
    cpp_config.blend_start_splat_count = config->blend_start_splat_count;
    cpp_config.blend_end_splat_count = config->blend_end_splat_count;
    cpp_config.depth_model_path =
        config->depth_model_path ? config->depth_model_path : "";          // DAv2 Small
    cpp_config.depth_model_path_large =
        config->depth_model_path_large ? config->depth_model_path_large : "";  // DAv2 Large
    cpp_config.depth_model_path_video =
        config->depth_model_path_video ? config->depth_model_path_video : "";  // Video Depth
    cpp_config.large_model_interval = config->large_model_interval;

    auto* wrapper = new (std::nothrow) aether_pipeline_coordinator_s;
    if (!wrapper) return nullptr;

    wrapper->coordinator = new (std::nothrow) aether::pipeline::PipelineCoordinator(
        *device, *renderer, cpp_config);

    if (!wrapper->coordinator) {
        delete wrapper;
        return nullptr;
    }

    return wrapper;
}

void aether_pipeline_coordinator_destroy(
    aether_pipeline_coordinator_t* coordinator) {
    if (!coordinator) return;
    delete coordinator->coordinator;
    delete coordinator;
}

int aether_pipeline_coordinator_on_frame(
    aether_pipeline_coordinator_t* coordinator,
    const uint8_t* rgba, uint32_t w, uint32_t h,
    const float* transform,
    const float* intrinsics,
    const float* feature_points_xyz,
    uint32_t feature_count,
    const float* ne_depth,
    uint32_t ne_depth_w,
    uint32_t ne_depth_h,
    const float* lidar_depth,
    uint32_t lidar_w,
    uint32_t lidar_h,
    int thermal_state) {

    if (!coordinator || !coordinator->coordinator) return -1;
    if (!rgba || w == 0 || h == 0) return -1;
    if (!transform || !intrinsics) return -1;

    return coordinator->coordinator->on_frame(
        rgba, w, h,
        transform, intrinsics,
        feature_points_xyz, feature_count,
        ne_depth, ne_depth_w, ne_depth_h,
        lidar_depth, lidar_w, lidar_h,
        thermal_state);
}

int aether_pipeline_coordinator_on_imported_video_frame(
    aether_pipeline_coordinator_t* coordinator,
    const uint8_t* rgba, uint32_t w, uint32_t h,
    const float* intrinsics,
    int intrinsics_source,
    double timestamp_seconds,
    uint32_t frame_index,
    uint32_t total_frames,
    int thermal_state) {

    if (!coordinator || !coordinator->coordinator) return -1;
    if (!rgba || w == 0 || h == 0) return -1;

    return coordinator->coordinator->on_imported_video_frame(
        rgba,
        w,
        h,
        intrinsics,
        intrinsics_source,
        timestamp_seconds,
        frame_index,
        total_frames,
        thermal_state);
}

int aether_pipeline_coordinator_get_snapshot(
    aether_pipeline_coordinator_t* coordinator,
    aether_evidence_snapshot_t* out) {

    if (!coordinator || !coordinator->coordinator || !out) return -1;

    auto snapshot = coordinator->coordinator->get_snapshot();
    out->coverage = snapshot.coverage;
    out->overall_quality = snapshot.overall_quality;
    out->training_progress = snapshot.training_progress;
    out->frame_count = snapshot.frame_count;
    out->selected_frames = snapshot.selected_frames;
    out->min_frames_needed = snapshot.min_frames_needed;
    out->num_gaussians = snapshot.num_gaussians;
    out->training_active = snapshot.training_active ? 1 : 0;
    out->scan_complete = snapshot.scan_complete ? 1 : 0;
    out->has_s6_quality = snapshot.has_s6_quality ? 1 : 0;
    out->thermal_level = static_cast<int>(snapshot.thermal_level);

    // 全局训练状态
    out->training_loss = snapshot.training_loss;
    out->training_step = snapshot.training_step;
    out->assigned_blocks = snapshot.assigned_blocks;
    out->pending_gaussian_count = snapshot.pending_gaussian_count;
    out->preview_elapsed_ms = snapshot.preview_elapsed_ms;
    out->preview_phase_depth_ms = snapshot.preview_phase_depth_ms;
    out->preview_phase_seed_ms = snapshot.preview_phase_seed_ms;
    out->preview_phase_refine_ms = snapshot.preview_phase_refine_ms;
    out->preview_depth_batches_submitted = snapshot.preview_depth_batches_submitted;
    out->preview_depth_results_ready = snapshot.preview_depth_results_ready;
    out->preview_depth_reuse_frames = snapshot.preview_depth_reuse_frames;
    out->preview_prefilter_accepts = snapshot.preview_prefilter_accepts;
    out->preview_prefilter_brightness_rejects = snapshot.preview_prefilter_brightness_rejects;
    out->preview_prefilter_blur_rejects = snapshot.preview_prefilter_blur_rejects;
    out->preview_keyframe_gate_accepts = snapshot.preview_keyframe_gate_accepts;
    out->preview_keyframe_gate_rejects = snapshot.preview_keyframe_gate_rejects;
    out->preview_imported_frames_evaluated = snapshot.preview_imported_frames_evaluated;
    out->preview_imported_low_parallax_rejects = snapshot.preview_imported_low_parallax_rejects;
    out->preview_imported_near_duplicate_rejects = snapshot.preview_imported_near_duplicate_rejects;
    out->preview_imported_selected_keyframes = snapshot.preview_imported_selected_keyframes;
    out->preview_imported_selected_translation_mean_mm =
        snapshot.preview_imported_selected_translation_mean_mm;
    out->preview_imported_selected_rotation_mean_deg =
        snapshot.preview_imported_selected_rotation_mean_deg;
    out->preview_imported_selected_overlap_mean =
        snapshot.preview_imported_selected_overlap_mean;
    out->preview_seed_candidates = snapshot.preview_seed_candidates;
    out->preview_seed_accepted = snapshot.preview_seed_accepted;
    out->preview_seed_rejected = snapshot.preview_seed_rejected;
    out->preview_seed_quality_mean = snapshot.preview_seed_quality_mean;
    out->preview_frames_enqueued = snapshot.preview_frames_enqueued;
    out->preview_frames_ingested = snapshot.preview_frames_ingested;
    out->preview_frame_backlog = snapshot.preview_frame_backlog;

    return 0;
}

int aether_pipeline_coordinator_finish_scanning(
    aether_pipeline_coordinator_t* coordinator) {
    if (!coordinator || !coordinator->coordinator) return -1;
    coordinator->coordinator->finish_scanning();
    return 0;
}

void aether_pipeline_coordinator_set_thermal(
    aether_pipeline_coordinator_t* coordinator,
    int level) {
    if (!coordinator || !coordinator->coordinator) return;
    coordinator->coordinator->set_thermal_state(level);
}

void aether_pipeline_coordinator_set_foreground_active(
    aether_pipeline_coordinator_t* coordinator,
    int active) {
    if (!coordinator || !coordinator->coordinator) return;
    coordinator->coordinator->set_foreground_active(active != 0);
}

int aether_pipeline_coordinator_enhance(
    aether_pipeline_coordinator_t* coordinator,
    size_t extra_iterations) {
    if (!coordinator || !coordinator->coordinator) return -1;
    coordinator->coordinator->request_enhance(extra_iterations);
    return 0;
}

size_t aether_pipeline_coordinator_wait_for_training(
    aether_pipeline_coordinator_t* coordinator,
    size_t min_steps,
    double timeout_seconds) {
    if (!coordinator || !coordinator->coordinator) return 0;
    return coordinator->coordinator->wait_for_training(min_steps, timeout_seconds);
}

int aether_pipeline_coordinator_is_training(
    const aether_pipeline_coordinator_t* coordinator) {
    if (!coordinator || !coordinator->coordinator) return 0;
    return coordinator->coordinator->is_training_active() ? 1 : 0;
}

int aether_pipeline_coordinator_service_local_subject_first_bootstrap(
    aether_pipeline_coordinator_t* coordinator) {
    if (!coordinator || !coordinator->coordinator) return -1;
    return coordinator->coordinator->service_local_subject_first_bootstrap() ? 1 : 0;
}

int aether_pipeline_coordinator_service_local_preview_bootstrap(
    aether_pipeline_coordinator_t* coordinator) {
    return aether_pipeline_coordinator_service_local_subject_first_bootstrap(coordinator);
}

int aether_pipeline_coordinator_is_gpu_training(
    const aether_pipeline_coordinator_t* coordinator) {
    if (!coordinator || !coordinator->coordinator) return -1;
    return coordinator->coordinator->is_gpu_training() ? 1 : 0;
}

int aether_pipeline_coordinator_get_training_progress(
    const aether_pipeline_coordinator_t* coordinator,
    aether_coordinator_training_progress_t* out) {
    if (!coordinator || !coordinator->coordinator || !out) return -1;

    auto progress = coordinator->coordinator->training_progress();
    out->step = progress.step;
    out->total_steps = progress.total_steps;
    out->loss = progress.loss;
    out->num_gaussians = progress.num_gaussians;
    out->is_complete = progress.is_complete ? 1 : 0;

    return 0;
}

int aether_pipeline_coordinator_get_render_data(
    aether_pipeline_coordinator_t* coordinator,
    aether_render_data_t* out) {
    if (!coordinator || !coordinator->coordinator || !out) return -1;

    auto snap = coordinator->coordinator->get_render_snapshot();
    out->point_cloud_vertices = snap.pc_vertices
        ? reinterpret_cast<const float*>(snap.pc_vertices)
        : nullptr;
    out->point_cloud_count = static_cast<uint32_t>(snap.pc_count);
    out->point_cloud_alpha = snap.pc_alpha;

    // Packed splats from SplatRenderEngine (16 bytes each)
    out->packed_splats = snap.packed_splats;
    out->splat_count = static_cast<uint32_t>(snap.splat_count);

    // Quality overlay (C++ generated, OverlayVertex layout matches aether_overlay_vertex_t)
    out->overlay_vertices = snap.overlay_vertices
        ? reinterpret_cast<const aether_overlay_vertex_t*>(snap.overlay_vertices)
        : nullptr;
    out->overlay_count = static_cast<uint32_t>(snap.overlay_count);

    out->tsdf_block_count = static_cast<uint32_t>(snap.tsdf_block_count);

    return 0;
}

int aether_pipeline_coordinator_export_ply(
    aether_pipeline_coordinator_t* coordinator,
    const char* path) {
    if (!coordinator || !coordinator->coordinator || !path) return -1;
    auto status = coordinator->coordinator->export_ply(path);
    return static_cast<int>(status);
}

int aether_pipeline_coordinator_export_point_cloud_ply(
    aether_pipeline_coordinator_t* coordinator,
    const char* path) {
    if (!coordinator || !coordinator->coordinator || !path) return -1;
    auto status = coordinator->coordinator->export_point_cloud_ply(path);
    return static_cast<int>(status);
}

size_t aether_pipeline_coordinator_copy_surface_points_xyz(
    aether_pipeline_coordinator_t* coordinator,
    float* out_xyz,
    size_t max_points) {
    if (!coordinator || !coordinator->coordinator || !out_xyz || max_points == 0) {
        return 0;
    }
    return coordinator->coordinator->copy_surface_points_xyz(out_xyz, max_points);
}

// ═══════════════════════════════════════════════════════════════════════
// Viewer Entry Signal
// ═══════════════════════════════════════════════════════════════════════

void aether_pipeline_coordinator_signal_viewer_entered(
    aether_pipeline_coordinator_t* coordinator) {
    if (!coordinator || !coordinator->coordinator) return;
    coordinator->coordinator->signal_viewer_entered();
}

}  // extern "C"
