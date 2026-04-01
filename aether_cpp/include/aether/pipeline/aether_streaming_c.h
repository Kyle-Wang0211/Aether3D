// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_PIPELINE_STREAMING_C_H
#define AETHER_PIPELINE_STREAMING_C_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ═══════════════════════════════════════════════════════════════════════
// Streaming Pipeline C API
// ═══════════════════════════════════════════════════════════════════════
// Swift bridge for the StreamingPipeline coordinator.
// All functions are non-blocking unless noted.

typedef struct aether_streaming_pipeline_s aether_streaming_pipeline_t;

/// Configuration for streaming pipeline.
typedef struct {
    size_t min_frames_to_start_training;   // Default: 20
    size_t training_batch_size;            // Default: 4
    float low_quality_loss_weight;         // Default: 0.3
    // Frame selection
    float min_displacement_m;              // Default: 0.05
    float min_blur_score;                  // Default: 0.3
    float min_quality_score;               // Default: 0.15
    // Training
    size_t max_gaussians;                  // Default: 250000
    size_t max_iterations;                 // Default: 500
    uint32_t render_width;                 // Default: 960
    uint32_t render_height;               // Default: 720
} aether_streaming_config_t;

/// Training progress (lock-free snapshot).
typedef struct {
    size_t step;
    size_t total_steps;
    float loss;
    size_t num_gaussians;
    int is_complete;
} aether_training_progress_t;

/// Fill config with defaults.
int aether_streaming_default_config(aether_streaming_config_t* config);

/// Create streaming pipeline.
/// gpu_device_ptr: opaque pointer to GPUDevice
/// splat_engine_ptr: opaque pointer to SplatRenderEngine
aether_streaming_pipeline_t* aether_streaming_pipeline_create(
    void* gpu_device_ptr,
    void* splat_engine_ptr,
    const aether_streaming_config_t* config);

/// Destroy pipeline (blocks until threads stop).
void aether_streaming_pipeline_destroy(aether_streaming_pipeline_t* pipeline);

/// Submit frame from main thread (<1ms, non-blocking).
int aether_streaming_pipeline_on_frame(
    aether_streaming_pipeline_t* pipeline,
    const uint8_t* rgba, uint32_t w, uint32_t h,
    const float* transform,     // float[16], column-major
    const float* intrinsics,    // float[4], [fx, fy, cx, cy]
    double timestamp,
    float quality_score,
    float blur_score);

/// Query if training has started (lock-free).
int aether_streaming_pipeline_is_training(
    const aether_streaming_pipeline_t* pipeline);

/// Get training progress snapshot (lock-free).
int aether_streaming_pipeline_progress(
    const aether_streaming_pipeline_t* pipeline,
    aether_training_progress_t* out);

/// Stop accepting frames, drain queue, continue training.
int aether_streaming_pipeline_finish_scanning(
    aether_streaming_pipeline_t* pipeline);

/// Request additional training iterations.
int aether_streaming_pipeline_enhance(
    aether_streaming_pipeline_t* pipeline,
    size_t extra_iterations);

/// Set thermal state (0-3).
void aether_streaming_pipeline_set_thermal(
    aether_streaming_pipeline_t* pipeline,
    int level);

/// Export trained Gaussians to PLY file (may block briefly).
int aether_streaming_pipeline_export_ply(
    aether_streaming_pipeline_t* pipeline,
    const char* path);

#ifdef __cplusplus
}
#endif

#endif  // AETHER_PIPELINE_STREAMING_C_H
