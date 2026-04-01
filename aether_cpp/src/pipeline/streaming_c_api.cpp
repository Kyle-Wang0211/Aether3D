// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/pipeline/aether_streaming_c.h"
#include "aether/pipeline/streaming_pipeline.h"
#include "aether/render/gpu_device.h"
#include "aether/splat/splat_render_engine.h"

using namespace aether;

struct aether_streaming_pipeline_s {
    pipeline::StreamingPipeline* impl;
};

extern "C" {

int aether_streaming_default_config(aether_streaming_config_t* config) {
    if (!config) return -1;
    config->min_frames_to_start_training = 20;
    config->training_batch_size = 4;
    config->low_quality_loss_weight = 0.3f;
    config->min_displacement_m = 0.05f;
    config->min_blur_score = 0.3f;
    config->min_quality_score = 0.15f;
    config->max_gaussians = 250000;
    config->max_iterations = 500;
    config->render_width = 960;
    config->render_height = 720;
    return 0;
}

aether_streaming_pipeline_t* aether_streaming_pipeline_create(
    void* gpu_device_ptr,
    void* splat_engine_ptr,
    const aether_streaming_config_t* config)
{
    if (!gpu_device_ptr || !splat_engine_ptr || !config) return nullptr;

    auto* device = static_cast<render::GPUDevice*>(gpu_device_ptr);
    auto* renderer = static_cast<splat::SplatRenderEngine*>(splat_engine_ptr);

    pipeline::StreamingConfig cfg;
    cfg.min_frames_to_start_training = config->min_frames_to_start_training;
    cfg.training_batch_size = config->training_batch_size;
    cfg.low_quality_loss_weight = config->low_quality_loss_weight;
    cfg.frame_selection.min_displacement_m = config->min_displacement_m;
    cfg.frame_selection.min_blur_score = config->min_blur_score;
    cfg.frame_selection.min_quality_score = config->min_quality_score;
    cfg.training.max_gaussians = config->max_gaussians;
    cfg.training.max_iterations = config->max_iterations;
    cfg.training.render_width = config->render_width;
    cfg.training.render_height = config->render_height;

    auto* wrapper = new aether_streaming_pipeline_s;
    wrapper->impl = new pipeline::StreamingPipeline(*device, *renderer, cfg);
    return wrapper;
}

void aether_streaming_pipeline_destroy(aether_streaming_pipeline_t* pipeline) {
    if (!pipeline) return;
    delete pipeline->impl;
    delete pipeline;
}

int aether_streaming_pipeline_on_frame(
    aether_streaming_pipeline_t* pipeline,
    const uint8_t* rgba, uint32_t w, uint32_t h,
    const float* transform,
    const float* intrinsics,
    double timestamp,
    float quality_score,
    float blur_score)
{
    if (!pipeline || !pipeline->impl || !rgba || !transform || !intrinsics)
        return -1;
    pipeline->impl->on_frame(rgba, w, h, transform, intrinsics,
                              timestamp, quality_score, blur_score);
    return 0;
}

int aether_streaming_pipeline_is_training(
    const aether_streaming_pipeline_t* pipeline)
{
    if (!pipeline || !pipeline->impl) return 0;
    return pipeline->impl->is_training_active() ? 1 : 0;
}

int aether_streaming_pipeline_progress(
    const aether_streaming_pipeline_t* pipeline,
    aether_training_progress_t* out)
{
    if (!pipeline || !pipeline->impl || !out) return -1;
    auto prog = pipeline->impl->training_progress();
    out->step = prog.step;
    out->total_steps = prog.total_steps;
    out->loss = prog.loss;
    out->num_gaussians = prog.num_gaussians;
    out->is_complete = prog.is_complete ? 1 : 0;
    return 0;
}

int aether_streaming_pipeline_finish_scanning(
    aether_streaming_pipeline_t* pipeline)
{
    if (!pipeline || !pipeline->impl) return -1;
    pipeline->impl->finish_scanning();
    return 0;
}

int aether_streaming_pipeline_enhance(
    aether_streaming_pipeline_t* pipeline,
    size_t extra_iterations)
{
    if (!pipeline || !pipeline->impl) return -1;
    pipeline->impl->request_enhance(extra_iterations);
    return 0;
}

void aether_streaming_pipeline_set_thermal(
    aether_streaming_pipeline_t* pipeline,
    int level)
{
    if (!pipeline || !pipeline->impl) return;
    pipeline->impl->set_thermal_state(level);
}

int aether_streaming_pipeline_export_ply(
    aether_streaming_pipeline_t* pipeline,
    const char* path)
{
    if (!pipeline || !pipeline->impl || !path) return -1;
    auto status = pipeline->impl->export_ply(path);
    return static_cast<int>(status);
}

}  // extern "C"
