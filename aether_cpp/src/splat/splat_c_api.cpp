// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/splat/aether_splat_c.h"

#include "aether/render/gpu_device.h"
#include "aether/render/metal_gpu_device.h"    // wrap_metal_command_buffer
#include "aether/splat/packed_splats.h"
#include "aether/splat/splat_render_engine.h"
#include "aether/splat/ply_loader.h"

#include <cstring>
#include <new>

// ═══════════════════════════════════════════════════════════════════════
// Opaque wrappers
// ═══════════════════════════════════════════════════════════════════════

// Must match layout in metal_c_api.mm (single-pointer wrapper).
struct aether_gpu_device {
    aether::render::GPUDevice* impl;
};

struct aether_splat_engine {
    aether::splat::SplatRenderEngine* impl;
    aether::render::GPUDevice* device;  // Stored for wrapping MTLCommandBuffer→GPUCommandBuffer
};

// ═══════════════════════════════════════════════════════════════════════
// Lifecycle
// ═══════════════════════════════════════════════════════════════════════

extern "C" {

int aether_splat_default_config(aether_splat_config_t* out_config) {
    if (!out_config) return -1;
    out_config->max_splats = 500000;
    // Match the full float depth key width so we do not collapse far/near
    // splats into the same truncated radix buckets once GPU sort is re-enabled.
    out_config->sort_precision_bits = 32;
    out_config->max_screen_radius = 1024.0f;
    out_config->triple_buffer_count = 3;
    return 0;
}

int aether_splat_engine_create(void* gpu_device_ptr,
                                const aether_splat_config_t* config,
                                aether_splat_engine_t** out_engine) {
    if (!gpu_device_ptr || !config || !out_engine) return -1;

    // gpu_device_ptr is aether_gpu_device_t* (wrapper), extract the impl.
    auto* device_wrapper = static_cast<aether_gpu_device*>(gpu_device_ptr);
    auto* device = device_wrapper->impl;
    if (!device) return -1;

    aether::splat::SplatRenderConfig cpp_config;
    cpp_config.max_splats = config->max_splats;
    cpp_config.sort_precision_bits = config->sort_precision_bits;
    cpp_config.max_screen_radius = config->max_screen_radius;
    cpp_config.triple_buffer_count = config->triple_buffer_count;

    auto* engine = new (std::nothrow) aether_splat_engine();
    if (!engine) return -3;

    engine->impl = new (std::nothrow) aether::splat::SplatRenderEngine(
        *device, cpp_config);
    if (!engine->impl) {
        delete engine;
        return -3;
    }
    engine->device = device;  // Store for MTLCommandBuffer → GPUCommandBuffer wrapping

    *out_engine = engine;
    return 0;
}

void aether_splat_engine_destroy(aether_splat_engine_t* engine) {
    if (!engine) return;
    delete engine->impl;
    delete engine;
}

// ═══════════════════════════════════════════════════════════════════════
// Data Loading
// ═══════════════════════════════════════════════════════════════════════

int aether_splat_load_ply(aether_splat_engine_t* engine, const char* path) {
    if (!engine || !engine->impl || !path) return -1;
    auto status = engine->impl->load_from_ply(path);
    return aether::core::is_ok(status) ? 0 : -1;
}

int aether_splat_load_spz(aether_splat_engine_t* engine,
                           const uint8_t* data, size_t size) {
    if (!engine || !engine->impl || !data || size == 0) return -1;
    auto status = engine->impl->load_from_spz(data, size);
    return aether::core::is_ok(status) ? 0 : -1;
}

int aether_splat_load_gaussians(aether_splat_engine_t* engine,
                                 const aether_gaussian_params_t* params,
                                 size_t count) {
    if (!engine || !engine->impl || !params || count == 0) return -1;

    // aether_gaussian_params_t and aether::splat::GaussianParams have
    // identical memory layout (92 bytes, same field order including SH coefficients).
    static_assert(sizeof(aether_gaussian_params_t) ==
                  sizeof(aether::splat::GaussianParams),
                  "C and C++ Gaussian structs must match");

    auto* cpp_params = reinterpret_cast<const aether::splat::GaussianParams*>(params);
    auto status = engine->impl->load_gaussians(cpp_params, count);
    return aether::core::is_ok(status) ? 0 : -1;
}

// ═══════════════════════════════════════════════════════════════════════
// Incremental Update
// ═══════════════════════════════════════════════════════════════════════

int aether_splat_push(aether_splat_engine_t* engine,
                       const aether_gaussian_params_t* params,
                       size_t count) {
    if (!engine || !engine->impl || !params || count == 0) return -1;
    auto* cpp_params = reinterpret_cast<const aether::splat::GaussianParams*>(params);
    engine->impl->push_splats(cpp_params, count);
    return 0;
}

int aether_splat_push_with_regions(aether_splat_engine_t* engine,
                                    const aether_gaussian_params_t* params,
                                    const uint8_t* region_ids,
                                    size_t count) {
    if (!engine || !engine->impl || !params || !region_ids || count == 0) return -1;
    auto* cpp_params = reinterpret_cast<const aether::splat::GaussianParams*>(params);
    engine->impl->push_splats_with_regions(cpp_params, region_ids, count);
    return 0;
}

void aether_splat_set_region_fade_alphas(aether_splat_engine_t* engine,
                                          const float* fade_alphas,
                                          size_t count) {
    if (!engine || !engine->impl || !fade_alphas || count == 0) return;
    engine->impl->set_region_fade_alphas(fade_alphas, count);
}

void aether_splat_clear(aether_splat_engine_t* engine) {
    if (!engine || !engine->impl) return;
    engine->impl->clear_splats();
}

// ═══════════════════════════════════════════════════════════════════════
// Per-Frame Rendering
// ═══════════════════════════════════════════════════════════════════════

void aether_splat_begin_frame(aether_splat_engine_t* engine) {
    if (!engine || !engine->impl) return;
    engine->impl->begin_frame();
}

void aether_splat_update_camera(aether_splat_engine_t* engine,
                                 const aether_splat_camera_t* camera) {
    if (!engine || !engine->impl || !camera) return;

    aether::splat::SplatCameraState state;
    std::memcpy(state.view, camera->view, sizeof(state.view));
    std::memcpy(state.proj, camera->proj, sizeof(state.proj));
    state.fx = camera->fx;
    state.fy = camera->fy;
    state.cx = camera->cx;
    state.cy = camera->cy;
    state.vp_width = camera->vp_width;
    state.vp_height = camera->vp_height;
    state.render_splat_limit = camera->render_splat_limit;

    engine->impl->update_camera(state);
}

void aether_splat_encode_sort(aether_splat_engine_t* engine,
                               void* cmd_buffer_ptr) {
    if (!engine || !engine->impl || !engine->device || !cmd_buffer_ptr) return;

    // cmd_buffer_ptr is an MTLCommandBuffer* from Swift (via Unmanaged.passUnretained.toOpaque).
    // We MUST wrap it in a MetalCommandBuffer adapter for C++ virtual dispatch.
    // Previous code did static_cast<GPUCommandBuffer*> which is WRONG — MTLCommandBuffer is
    // an ObjC object, not a C++ class with vtable. This caused EXC_BAD_ACCESS.
    auto cmd = aether::render::wrap_metal_command_buffer(cmd_buffer_ptr, *engine->device);
    if (!cmd) return;
    engine->impl->encode_sort_pass(*cmd);
}

void aether_splat_encode_render(aether_splat_engine_t* engine,
                                 void* cmd_buffer_ptr,
                                 void* render_target_ptr) {
    if (!engine || !engine->impl || !engine->device || !cmd_buffer_ptr || !render_target_ptr) return;

    // Same wrapping as encode_sort — MTLCommandBuffer* → MetalCommandBuffer adapter.
    auto cmd = aether::render::wrap_metal_command_buffer(cmd_buffer_ptr, *engine->device);
    if (!cmd) return;
    auto* target = static_cast<aether::render::GPURenderTargetDesc*>(render_target_ptr);
    engine->impl->encode_render_pass(*cmd, *target);
}

void aether_splat_encode_render_native(aether_splat_engine_t* engine,
                                        void* cmd_buffer_ptr,
                                        void* render_pass_desc_ptr) {
    if (!engine || !engine->impl || !engine->device || !cmd_buffer_ptr || !render_pass_desc_ptr) return;

    // MTLCommandBuffer* → MetalCommandBuffer adapter (same as encode_sort).
    auto cmd = aether::render::wrap_metal_command_buffer(cmd_buffer_ptr, *engine->device);
    if (!cmd) return;

    // render_pass_desc_ptr is an MTLRenderPassDescriptor* from Swift.
    // Pass it through to the native render encoder — renders directly into the drawable.
    engine->impl->encode_render_pass_native(*cmd, render_pass_desc_ptr);
}

void aether_splat_end_frame(aether_splat_engine_t* engine,
                             aether_splat_stats_t* out_stats) {
    if (!engine || !engine->impl) return;
    auto stats = engine->impl->end_frame();
    if (out_stats) {
        out_stats->total_splats = stats.total_splats;
        out_stats->visible_splats = stats.visible_splats;
        out_stats->sort_mode = stats.sort_mode;
        out_stats->sort_time_ms = stats.sort_time_ms;
        out_stats->render_time_ms = stats.render_time_ms;
    }
}

// ═══════════════════════════════════════════════════════════════════════
// Queries
// ═══════════════════════════════════════════════════════════════════════

size_t aether_splat_count(const aether_splat_engine_t* engine) {
    if (!engine || !engine->impl) return 0;
    return engine->impl->splat_count();
}

int aether_splat_is_initialized(const aether_splat_engine_t* engine) {
    if (!engine || !engine->impl) return 0;
    return engine->impl->is_initialized() ? 1 : 0;
}

int aether_splat_get_bounds(const aether_splat_engine_t* engine,
                             float center[3], float* radius) {
    if (!engine || !engine->impl || !center || !radius) return -1;
    return engine->impl->get_bounds(center, radius) ? 0 : -1;
}

const void* aether_splat_get_packed_data(const aether_splat_engine_t* engine) {
    if (!engine || !engine->impl) return nullptr;
    const auto& buf = engine->impl->packed_data();
    return buf.empty() ? nullptr : static_cast<const void*>(buf.data());
}

size_t aether_splat_get_packed_count(const aether_splat_engine_t* engine) {
    if (!engine || !engine->impl) return 0;
    return engine->impl->packed_data().size();
}

const void* aether_splat_get_sh_data(const aether_splat_engine_t* engine) {
    if (!engine || !engine->impl) return nullptr;
    const auto& buf = engine->impl->sh_data();
    return buf.empty() ? nullptr : static_cast<const void*>(buf.data());
}

size_t aether_splat_get_sh_float_count(const aether_splat_engine_t* engine) {
    if (!engine || !engine->impl) return 0;
    return engine->impl->sh_data().size();
}

// ═══════════════════════════════════════════════════════════════════════
// Utility
// ═══════════════════════════════════════════════════════════════════════

int aether_splat_ply_vertex_count(const char* path, size_t* out_count) {
    if (!path || !out_count) return -1;
    aether::splat::PlyLoadResult result;
    auto status = aether::splat::load_ply(path, result);
    if (!aether::core::is_ok(status)) return -1;
    *out_count = result.vertex_count;
    return 0;
}

void aether_splat_pack(const aether_gaussian_params_t* params,
                        uint8_t out_packed[16]) {
    if (!params || !out_packed) return;
    auto* cpp = reinterpret_cast<const aether::splat::GaussianParams*>(params);
    aether::splat::PackedSplat packed = aether::splat::pack_gaussian(*cpp);
    std::memcpy(out_packed, &packed, 16);
}

void aether_splat_unpack(const uint8_t packed[16],
                          aether_gaussian_params_t* out_params) {
    if (!packed || !out_params) return;
    aether::splat::PackedSplat ps;
    std::memcpy(&ps, packed, 16);
    aether::splat::GaussianParams result = aether::splat::unpack_gaussian(ps);
    std::memcpy(out_params, &result, sizeof(result));
}

}  // extern "C"
