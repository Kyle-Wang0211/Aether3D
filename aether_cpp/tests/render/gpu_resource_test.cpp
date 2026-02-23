// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/render/gpu_resource.h"
#include "aether/render/gpu_handle.h"
#include "aether/render/gpu_device.h"
#include "aether/render/gpu_command.h"
#include "aether_tsdf_c.h"

#include <cstdio>
#include <cstring>

int main() {
    int failed = 0;
    using namespace aether::render;

    // ── NullGPUDevice ──
    NullGPUDevice device;

    if (device.backend() != GraphicsBackend::kUnknown) {
        std::fprintf(stderr, "NullGPUDevice backend should be Unknown\n");
        ++failed;
    }

    // Create buffer
    GPUBufferDesc buf_desc{};
    buf_desc.size_bytes = 1024;
    buf_desc.storage = GPUStorageMode::kShared;
    buf_desc.usage_mask = static_cast<std::uint8_t>(GPUBufferUsage::kVertex);
    buf_desc.label = "test_buffer";

    GPUBufferHandle buf = device.create_buffer(buf_desc);
    if (!buf.valid()) {
        std::fprintf(stderr, "Buffer handle should be valid\n");
        ++failed;
    }

    // Create texture
    GPUTextureDesc tex_desc{};
    tex_desc.width = 256;
    tex_desc.height = 256;
    tex_desc.format = GPUTextureFormat::kRGBA8Unorm;
    tex_desc.usage_mask = static_cast<std::uint8_t>(GPUTextureUsage::kShaderRead);

    GPUTextureHandle tex = device.create_texture(tex_desc);
    if (!tex.valid()) {
        std::fprintf(stderr, "Texture handle should be valid\n");
        ++failed;
    }

    // Unique IDs
    GPUBufferHandle buf2 = device.create_buffer(buf_desc);
    if (buf.id == buf2.id) {
        std::fprintf(stderr, "Buffer handles should have unique IDs\n");
        ++failed;
    }

    // Load shader
    GPUShaderHandle shader = device.load_shader("test_vertex", GPUShaderStage::kVertex);
    if (!shader.valid()) {
        std::fprintf(stderr, "Shader handle should be valid\n");
        ++failed;
    }

    // Create pipelines
    GPURenderTargetDesc rt_desc{};
    rt_desc.width = 1920;
    rt_desc.height = 1080;
    GPURenderPipelineHandle rp = device.create_render_pipeline(shader, shader, rt_desc);
    if (!rp.valid()) {
        std::fprintf(stderr, "Render pipeline handle should be valid\n");
        ++failed;
    }

    GPUComputePipelineHandle cp = device.create_compute_pipeline(shader);
    if (!cp.valid()) {
        std::fprintf(stderr, "Compute pipeline handle should be valid\n");
        ++failed;
    }

    // Capabilities
    GPUCaps caps = device.capabilities();
    if (caps.backend != GraphicsBackend::kUnknown) {
        std::fprintf(stderr, "NullGPUDevice caps backend should be Unknown\n");
        ++failed;
    }

    // Memory stats
    GPUMemoryStats mem = device.memory_stats();
    if (mem.allocated_bytes != 0 || mem.buffer_count != 0) {
        std::fprintf(stderr, "NullGPUDevice memory stats should be zero\n");
        ++failed;
    }

    // Map buffer (null device returns nullptr)
    void* mapped = device.map_buffer(buf);
    if (mapped != nullptr) {
        std::fprintf(stderr, "NullGPUDevice map_buffer should return nullptr\n");
        ++failed;
    }
    device.unmap_buffer(buf);

    // Cleanup
    device.destroy_buffer(buf);
    device.destroy_buffer(buf2);
    device.destroy_texture(tex);
    device.destroy_shader(shader);
    device.destroy_render_pipeline(rp);
    device.destroy_compute_pipeline(cp);
    device.wait_idle();

    // ── Resource Descriptor defaults ──
    GPURenderTargetDesc default_rt{};
    if (default_rt.clear_depth != 1.0f) {
        std::fprintf(stderr, "Default clear depth should be 1.0\n");
        ++failed;
    }
    if (default_rt.sample_count != 1) {
        std::fprintf(stderr, "Default sample count should be 1\n");
        ++failed;
    }
    if (default_rt.color_load != GPULoadAction::kClear) {
        std::fprintf(stderr, "Default color load should be Clear\n");
        ++failed;
    }
    if (default_rt.color_store != GPUStoreAction::kStore) {
        std::fprintf(stderr, "Default color store should be Store\n");
        ++failed;
    }

    // ── Handle validity ──
    GPUBufferHandle invalid_buf{};
    if (invalid_buf.valid()) {
        std::fprintf(stderr, "Default handle should be invalid\n");
        ++failed;
    }

    GPUTextureHandle invalid_tex{};
    if (invalid_tex.valid()) {
        std::fprintf(stderr, "Default texture handle should be invalid\n");
        ++failed;
    }

    GPUShaderHandle invalid_shader{};
    if (invalid_shader.valid()) {
        std::fprintf(stderr, "Default shader handle should be invalid\n");
        ++failed;
    }

    GPURenderPipelineHandle invalid_rp{};
    if (invalid_rp.valid()) {
        std::fprintf(stderr, "Default render pipeline handle should be invalid\n");
        ++failed;
    }

    GPUComputePipelineHandle invalid_cp{};
    if (invalid_cp.valid()) {
        std::fprintf(stderr, "Default compute pipeline handle should be invalid\n");
        ++failed;
    }

    // ── GPUViewport defaults ──
    GPUViewport vp{};
    if (vp.far_depth != 1.0f || vp.near_depth != 0.0f) {
        std::fprintf(stderr, "Default viewport depth range should be [0, 1]\n");
        ++failed;
    }

    // ── GPUCaps defaults ──
    GPUCaps default_caps{};
    if (default_caps.supports_compute || default_caps.simd_width != 0) {
        std::fprintf(stderr, "Default caps should have no features enabled\n");
        ++failed;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // C API Tests
    // ═══════════════════════════════════════════════════════════════════════

    // ── C API: Create null GPU device ──
    aether_gpu_device_t* c_dev = aether_gpu_device_create_null();
    if (c_dev == nullptr) {
        std::fprintf(stderr, "C API: aether_gpu_device_create_null should return non-null\n");
        ++failed;
    }

    // ── C API: Device backend ──
    {
        int backend = aether_gpu_device_get_backend(c_dev);
        if (backend != AETHER_GPU_BACKEND_UNKNOWN) {
            std::fprintf(stderr, "C API: null device backend should be UNKNOWN (%d)\n", backend);
            ++failed;
        }
    }

    // ── C API: Device capabilities ──
    {
        aether_gpu_caps_t c_caps{};
        int rc = aether_gpu_device_get_caps(c_dev, &c_caps);
        if (rc != 0) {
            std::fprintf(stderr, "C API: get_caps should return 0, got %d\n", rc);
            ++failed;
        }
        if (c_caps.backend != AETHER_GPU_BACKEND_UNKNOWN) {
            std::fprintf(stderr, "C API: caps backend should be UNKNOWN\n");
            ++failed;
        }
    }

    // ── C API: Device memory stats ──
    {
        aether_gpu_memory_stats_t c_mem{};
        int rc = aether_gpu_device_get_memory_stats(c_dev, &c_mem);
        if (rc != 0) {
            std::fprintf(stderr, "C API: get_memory_stats should return 0\n");
            ++failed;
        }
        if (c_mem.allocated_bytes != 0 || c_mem.buffer_count != 0) {
            std::fprintf(stderr, "C API: null device memory stats should be zero\n");
            ++failed;
        }
    }

    // ── C API: Null checks ──
    {
        if (aether_gpu_device_get_backend(nullptr) != AETHER_GPU_BACKEND_UNKNOWN) {
            std::fprintf(stderr, "C API: get_backend(null) should return UNKNOWN\n");
            ++failed;
        }
        if (aether_gpu_device_get_caps(nullptr, nullptr) != -1) {
            std::fprintf(stderr, "C API: get_caps(null, null) should return -1\n");
            ++failed;
        }
        if (aether_gpu_device_get_memory_stats(nullptr, nullptr) != -1) {
            std::fprintf(stderr, "C API: get_memory_stats(null, null) should return -1\n");
            ++failed;
        }
        if (aether_gpu_device_wait_idle(nullptr) != -1) {
            std::fprintf(stderr, "C API: wait_idle(null) should return -1\n");
            ++failed;
        }
    }

    // ── C API: Create buffer ──
    aether_gpu_buffer_desc_t c_buf_desc{};
    c_buf_desc.size = 2048;
    c_buf_desc.storage_mode = AETHER_GPU_STORAGE_SHARED;
    c_buf_desc.usage = AETHER_GPU_BUFFER_VERTEX;

    aether_gpu_buffer_handle_t c_buf = aether_gpu_buffer_create(c_dev, &c_buf_desc);
    if (c_buf == 0) {
        std::fprintf(stderr, "C API: buffer create should return non-zero handle\n");
        ++failed;
    }

    // ── C API: Create second buffer (unique IDs) ──
    aether_gpu_buffer_handle_t c_buf2 = aether_gpu_buffer_create(c_dev, &c_buf_desc);
    if (c_buf2 == 0) {
        std::fprintf(stderr, "C API: second buffer create should return non-zero handle\n");
        ++failed;
    }
    if (c_buf == c_buf2) {
        std::fprintf(stderr, "C API: buffer handles should be unique\n");
        ++failed;
    }

    // ── C API: Buffer null create ──
    {
        aether_gpu_buffer_handle_t h = aether_gpu_buffer_create(nullptr, &c_buf_desc);
        if (h != 0) {
            std::fprintf(stderr, "C API: buffer_create(null device) should return 0\n");
            ++failed;
        }
        h = aether_gpu_buffer_create(c_dev, nullptr);
        if (h != 0) {
            std::fprintf(stderr, "C API: buffer_create(null desc) should return 0\n");
            ++failed;
        }
    }

    // ── C API: Buffer map (null device returns nullptr) ──
    {
        void* ptr = aether_gpu_buffer_map(c_dev, c_buf);
        if (ptr != nullptr) {
            std::fprintf(stderr, "C API: null device buffer_map should return nullptr\n");
            ++failed;
        }
        aether_gpu_buffer_unmap(c_dev, c_buf);
    }

    // ── C API: Buffer update ──
    {
        uint8_t data[64]{};
        int rc = aether_gpu_buffer_update(c_dev, c_buf, data, 0, 64);
        if (rc != 0) {
            std::fprintf(stderr, "C API: buffer_update should return 0\n");
            ++failed;
        }
        rc = aether_gpu_buffer_update(nullptr, c_buf, data, 0, 64);
        if (rc != -1) {
            std::fprintf(stderr, "C API: buffer_update(null) should return -1\n");
            ++failed;
        }
    }

    // ── C API: Create texture ──
    aether_gpu_texture_desc_t c_tex_desc{};
    c_tex_desc.width = 512;
    c_tex_desc.height = 512;
    c_tex_desc.depth = 1;
    c_tex_desc.format = AETHER_GPU_FORMAT_RGBA8;
    c_tex_desc.usage = AETHER_GPU_TEXTURE_SAMPLE;
    c_tex_desc.storage_mode = AETHER_GPU_STORAGE_PRIVATE;

    aether_gpu_texture_handle_t c_tex = aether_gpu_texture_create(c_dev, &c_tex_desc);
    if (c_tex == 0) {
        std::fprintf(stderr, "C API: texture create should return non-zero handle\n");
        ++failed;
    }

    // ── C API: Texture update ──
    {
        uint8_t pixels[16]{};
        int rc = aether_gpu_texture_update(c_dev, c_tex, pixels, 2, 2, 8);
        if (rc != 0) {
            std::fprintf(stderr, "C API: texture_update should return 0\n");
            ++failed;
        }
        rc = aether_gpu_texture_update(nullptr, c_tex, pixels, 2, 2, 8);
        if (rc != -1) {
            std::fprintf(stderr, "C API: texture_update(null) should return -1\n");
            ++failed;
        }
    }

    // ── C API: Load shaders ──
    aether_gpu_shader_handle_t c_vs = aether_gpu_shader_load(c_dev, "test_vert", AETHER_GPU_SHADER_VERTEX);
    if (c_vs == 0) {
        std::fprintf(stderr, "C API: vertex shader load should return non-zero\n");
        ++failed;
    }

    aether_gpu_shader_handle_t c_fs = aether_gpu_shader_load(c_dev, "test_frag", AETHER_GPU_SHADER_FRAGMENT);
    if (c_fs == 0) {
        std::fprintf(stderr, "C API: fragment shader load should return non-zero\n");
        ++failed;
    }

    aether_gpu_shader_handle_t c_cs = aether_gpu_shader_load(c_dev, "test_compute", AETHER_GPU_SHADER_COMPUTE);
    if (c_cs == 0) {
        std::fprintf(stderr, "C API: compute shader load should return non-zero\n");
        ++failed;
    }

    // ── C API: Null shader load ──
    {
        aether_gpu_shader_handle_t h = aether_gpu_shader_load(nullptr, "x", AETHER_GPU_SHADER_VERTEX);
        if (h != 0) {
            std::fprintf(stderr, "C API: shader_load(null device) should return 0\n");
            ++failed;
        }
        h = aether_gpu_shader_load(c_dev, nullptr, AETHER_GPU_SHADER_VERTEX);
        if (h != 0) {
            std::fprintf(stderr, "C API: shader_load(null name) should return 0\n");
            ++failed;
        }
    }

    // ── C API: Create render pipeline ──
    aether_gpu_render_target_desc_t c_rt_desc{};
    c_rt_desc.color_load_action = AETHER_GPU_LOAD_CLEAR;
    c_rt_desc.color_store_action = AETHER_GPU_STORE_STORE;
    c_rt_desc.depth_load_action = AETHER_GPU_LOAD_CLEAR;
    c_rt_desc.depth_store_action = AETHER_GPU_STORE_DONT_CARE;
    c_rt_desc.clear_color[0] = 0.0f;
    c_rt_desc.clear_color[1] = 0.0f;
    c_rt_desc.clear_color[2] = 0.0f;
    c_rt_desc.clear_color[3] = 1.0f;
    c_rt_desc.clear_depth = 1.0f;

    aether_gpu_render_pipeline_handle_t c_rp = aether_gpu_render_pipeline_create(c_dev, c_vs, c_fs, &c_rt_desc);
    if (c_rp == 0) {
        std::fprintf(stderr, "C API: render pipeline create should return non-zero\n");
        ++failed;
    }

    // ── C API: Create compute pipeline ──
    aether_gpu_compute_pipeline_handle_t c_cp = aether_gpu_compute_pipeline_create(c_dev, c_cs);
    if (c_cp == 0) {
        std::fprintf(stderr, "C API: compute pipeline create should return non-zero\n");
        ++failed;
    }

    // ── C API: Null pipeline create ──
    {
        aether_gpu_render_pipeline_handle_t h = aether_gpu_render_pipeline_create(nullptr, c_vs, c_fs, &c_rt_desc);
        if (h != 0) {
            std::fprintf(stderr, "C API: render_pipeline_create(null device) should return 0\n");
            ++failed;
        }
        aether_gpu_compute_pipeline_handle_t h2 = aether_gpu_compute_pipeline_create(nullptr, c_cs);
        if (h2 != 0) {
            std::fprintf(stderr, "C API: compute_pipeline_create(null device) should return 0\n");
            ++failed;
        }
    }

    // ── C API: Command buffer ──
    aether_gpu_command_buffer_t* c_cmd = aether_gpu_command_buffer_create(c_dev);
    if (c_cmd == nullptr) {
        std::fprintf(stderr, "C API: command buffer create should return non-null\n");
        ++failed;
    }

    // ── C API: Null command buffer create ──
    {
        aether_gpu_command_buffer_t* h = aether_gpu_command_buffer_create(nullptr);
        if (h != nullptr) {
            std::fprintf(stderr, "C API: command_buffer_create(null) should return null\n");
            ++failed;
        }
    }

    // ── C API: Compute encoder ──
    {
        aether_gpu_compute_encoder_t* enc = aether_gpu_compute_encoder_create(c_cmd);
        if (enc == nullptr) {
            std::fprintf(stderr, "C API: compute encoder create should return non-null\n");
            ++failed;
        }

        int rc = aether_gpu_compute_set_pipeline(enc, c_cp);
        if (rc != 0) {
            std::fprintf(stderr, "C API: compute_set_pipeline should return 0\n");
            ++failed;
        }

        rc = aether_gpu_compute_set_buffer(enc, c_buf, 0, 0);
        if (rc != 0) {
            std::fprintf(stderr, "C API: compute_set_buffer should return 0\n");
            ++failed;
        }

        rc = aether_gpu_compute_set_texture(enc, c_tex, 0);
        if (rc != 0) {
            std::fprintf(stderr, "C API: compute_set_texture should return 0\n");
            ++failed;
        }

        rc = aether_gpu_compute_dispatch(enc, 4, 4, 1, 8, 8, 1);
        if (rc != 0) {
            std::fprintf(stderr, "C API: compute_dispatch should return 0\n");
            ++failed;
        }

        rc = aether_gpu_compute_end(enc);
        if (rc != 0) {
            std::fprintf(stderr, "C API: compute_end should return 0\n");
            ++failed;
        }

        // Null checks
        if (aether_gpu_compute_set_pipeline(nullptr, c_cp) != -1) {
            std::fprintf(stderr, "C API: compute_set_pipeline(null) should return -1\n");
            ++failed;
        }
        if (aether_gpu_compute_set_buffer(nullptr, c_buf, 0, 0) != -1) {
            std::fprintf(stderr, "C API: compute_set_buffer(null) should return -1\n");
            ++failed;
        }
        if (aether_gpu_compute_set_texture(nullptr, c_tex, 0) != -1) {
            std::fprintf(stderr, "C API: compute_set_texture(null) should return -1\n");
            ++failed;
        }
        if (aether_gpu_compute_dispatch(nullptr, 1, 1, 1, 1, 1, 1) != -1) {
            std::fprintf(stderr, "C API: compute_dispatch(null) should return -1\n");
            ++failed;
        }
        if (aether_gpu_compute_end(nullptr) != -1) {
            std::fprintf(stderr, "C API: compute_end(null) should return -1\n");
            ++failed;
        }

        aether_gpu_compute_encoder_destroy(enc);
    }

    // ── C API: Null compute encoder create ──
    {
        aether_gpu_compute_encoder_t* enc = aether_gpu_compute_encoder_create(nullptr);
        if (enc != nullptr) {
            std::fprintf(stderr, "C API: compute_encoder_create(null) should return null\n");
            ++failed;
        }
    }

    // ── C API: Render encoder ──
    {
        aether_gpu_render_encoder_t* enc = aether_gpu_render_encoder_create(c_cmd, &c_rt_desc);
        if (enc == nullptr) {
            std::fprintf(stderr, "C API: render encoder create should return non-null\n");
            ++failed;
        }

        int rc = aether_gpu_render_set_pipeline(enc, c_rp);
        if (rc != 0) {
            std::fprintf(stderr, "C API: render_set_pipeline should return 0\n");
            ++failed;
        }

        rc = aether_gpu_render_set_vertex_buffer(enc, c_buf, 0, 0);
        if (rc != 0) {
            std::fprintf(stderr, "C API: render_set_vertex_buffer should return 0\n");
            ++failed;
        }

        aether_gpu_viewport_t c_vp{};
        c_vp.x = 0.0f;
        c_vp.y = 0.0f;
        c_vp.width = 1920.0f;
        c_vp.height = 1080.0f;
        c_vp.near_depth = 0.0f;
        c_vp.far_depth = 1.0f;
        rc = aether_gpu_render_set_viewport(enc, &c_vp);
        if (rc != 0) {
            std::fprintf(stderr, "C API: render_set_viewport should return 0\n");
            ++failed;
        }

        aether_gpu_scissor_rect_t c_scissor{};
        c_scissor.x = 0;
        c_scissor.y = 0;
        c_scissor.width = 1920;
        c_scissor.height = 1080;
        rc = aether_gpu_render_set_scissor(enc, &c_scissor);
        if (rc != 0) {
            std::fprintf(stderr, "C API: render_set_scissor should return 0\n");
            ++failed;
        }

        rc = aether_gpu_render_set_cull_mode(enc, AETHER_GPU_CULL_BACK);
        if (rc != 0) {
            std::fprintf(stderr, "C API: render_set_cull_mode should return 0\n");
            ++failed;
        }

        rc = aether_gpu_render_draw(enc, AETHER_GPU_PRIMITIVE_TRIANGLE, 0, 36);
        if (rc != 0) {
            std::fprintf(stderr, "C API: render_draw should return 0\n");
            ++failed;
        }

        rc = aether_gpu_render_draw_indexed(enc, AETHER_GPU_PRIMITIVE_TRIANGLE, 36, c_buf, 0);
        if (rc != 0) {
            std::fprintf(stderr, "C API: render_draw_indexed should return 0\n");
            ++failed;
        }

        rc = aether_gpu_render_draw_instanced(enc, AETHER_GPU_PRIMITIVE_TRIANGLE, 36, 10);
        if (rc != 0) {
            std::fprintf(stderr, "C API: render_draw_instanced should return 0\n");
            ++failed;
        }

        rc = aether_gpu_render_end(enc);
        if (rc != 0) {
            std::fprintf(stderr, "C API: render_end should return 0\n");
            ++failed;
        }

        // Null checks
        if (aether_gpu_render_set_pipeline(nullptr, c_rp) != -1) {
            std::fprintf(stderr, "C API: render_set_pipeline(null) should return -1\n");
            ++failed;
        }
        if (aether_gpu_render_set_vertex_buffer(nullptr, c_buf, 0, 0) != -1) {
            std::fprintf(stderr, "C API: render_set_vertex_buffer(null) should return -1\n");
            ++failed;
        }
        if (aether_gpu_render_set_viewport(nullptr, &c_vp) != -1) {
            std::fprintf(stderr, "C API: render_set_viewport(null enc) should return -1\n");
            ++failed;
        }
        if (aether_gpu_render_set_viewport(enc, nullptr) != -1) {
            std::fprintf(stderr, "C API: render_set_viewport(null vp) should return -1\n");
            ++failed;
        }
        if (aether_gpu_render_set_scissor(nullptr, &c_scissor) != -1) {
            std::fprintf(stderr, "C API: render_set_scissor(null enc) should return -1\n");
            ++failed;
        }
        if (aether_gpu_render_set_scissor(enc, nullptr) != -1) {
            std::fprintf(stderr, "C API: render_set_scissor(null rect) should return -1\n");
            ++failed;
        }
        if (aether_gpu_render_set_cull_mode(nullptr, AETHER_GPU_CULL_NONE) != -1) {
            std::fprintf(stderr, "C API: render_set_cull_mode(null) should return -1\n");
            ++failed;
        }
        if (aether_gpu_render_draw(nullptr, AETHER_GPU_PRIMITIVE_TRIANGLE, 0, 3) != -1) {
            std::fprintf(stderr, "C API: render_draw(null) should return -1\n");
            ++failed;
        }
        if (aether_gpu_render_draw_indexed(nullptr, AETHER_GPU_PRIMITIVE_TRIANGLE, 3, c_buf, 0) != -1) {
            std::fprintf(stderr, "C API: render_draw_indexed(null) should return -1\n");
            ++failed;
        }
        if (aether_gpu_render_draw_instanced(nullptr, AETHER_GPU_PRIMITIVE_TRIANGLE, 3, 1) != -1) {
            std::fprintf(stderr, "C API: render_draw_instanced(null) should return -1\n");
            ++failed;
        }
        if (aether_gpu_render_end(nullptr) != -1) {
            std::fprintf(stderr, "C API: render_end(null) should return -1\n");
            ++failed;
        }

        aether_gpu_render_encoder_destroy(enc);
    }

    // ── C API: Null render encoder create ──
    {
        aether_gpu_render_encoder_t* enc = aether_gpu_render_encoder_create(nullptr, &c_rt_desc);
        if (enc != nullptr) {
            std::fprintf(stderr, "C API: render_encoder_create(null) should return null\n");
            ++failed;
        }
    }

    // ── C API: Command buffer commit, wait, had_error ──
    {
        int rc = aether_gpu_command_buffer_commit(c_cmd);
        if (rc != 0) {
            std::fprintf(stderr, "C API: command_buffer_commit should return 0\n");
            ++failed;
        }

        rc = aether_gpu_command_buffer_wait(c_cmd);
        if (rc != 0) {
            std::fprintf(stderr, "C API: command_buffer_wait should return 0\n");
            ++failed;
        }

        int err = aether_gpu_command_buffer_had_error(c_cmd);
        if (err != 0) {
            std::fprintf(stderr, "C API: null command buffer should have no error (got %d)\n", err);
            ++failed;
        }

        // Null checks
        if (aether_gpu_command_buffer_commit(nullptr) != -1) {
            std::fprintf(stderr, "C API: command_buffer_commit(null) should return -1\n");
            ++failed;
        }
        if (aether_gpu_command_buffer_wait(nullptr) != -1) {
            std::fprintf(stderr, "C API: command_buffer_wait(null) should return -1\n");
            ++failed;
        }
        if (aether_gpu_command_buffer_had_error(nullptr) != -1) {
            std::fprintf(stderr, "C API: command_buffer_had_error(null) should return -1\n");
            ++failed;
        }
    }

    // ── C API: wait_idle ──
    {
        int rc = aether_gpu_device_wait_idle(c_dev);
        if (rc != 0) {
            std::fprintf(stderr, "C API: wait_idle should return 0\n");
            ++failed;
        }
    }

    // ── C API: Destroy calls (safe with null) ──
    aether_gpu_buffer_destroy(c_dev, c_buf);
    aether_gpu_buffer_destroy(c_dev, c_buf2);
    aether_gpu_texture_destroy(c_dev, c_tex);
    aether_gpu_shader_destroy(c_dev, c_vs);
    aether_gpu_shader_destroy(c_dev, c_fs);
    aether_gpu_shader_destroy(c_dev, c_cs);
    aether_gpu_render_pipeline_destroy(c_dev, c_rp);
    aether_gpu_compute_pipeline_destroy(c_dev, c_cp);
    aether_gpu_command_buffer_destroy(c_cmd);

    // Destroy with null device/handle should not crash
    aether_gpu_buffer_destroy(nullptr, 1);
    aether_gpu_texture_destroy(nullptr, 1);
    aether_gpu_shader_destroy(nullptr, 1);
    aether_gpu_render_pipeline_destroy(nullptr, 1);
    aether_gpu_compute_pipeline_destroy(nullptr, 1);
    aether_gpu_command_buffer_destroy(nullptr);
    aether_gpu_compute_encoder_destroy(nullptr);
    aether_gpu_render_encoder_destroy(nullptr);

    // ── C API: Texture format variants ──
    {
        aether_gpu_texture_desc_t desc{};
        desc.width = 64;
        desc.height = 64;
        desc.depth = 1;
        desc.storage_mode = AETHER_GPU_STORAGE_SHARED;
        desc.usage = AETHER_GPU_TEXTURE_SAMPLE;

        int formats[] = {
            AETHER_GPU_FORMAT_RGBA8, AETHER_GPU_FORMAT_RGBA16F, AETHER_GPU_FORMAT_RGBA32F,
            AETHER_GPU_FORMAT_R32F, AETHER_GPU_FORMAT_DEPTH32F, AETHER_GPU_FORMAT_R8,
            AETHER_GPU_FORMAT_RG16F
        };
        for (int fmt : formats) {
            desc.format = fmt;
            aether_gpu_texture_handle_t h = aether_gpu_texture_create(c_dev, &desc);
            if (h == 0) {
                std::fprintf(stderr, "C API: texture create with format %d should succeed\n", fmt);
                ++failed;
            }
            aether_gpu_texture_destroy(c_dev, h);
        }
    }

    // ── C API: Storage mode variants ──
    {
        aether_gpu_buffer_desc_t desc{};
        desc.size = 256;
        desc.usage = AETHER_GPU_BUFFER_UNIFORM;

        int modes[] = {AETHER_GPU_STORAGE_SHARED, AETHER_GPU_STORAGE_PRIVATE, AETHER_GPU_STORAGE_MANAGED};
        for (int mode : modes) {
            desc.storage_mode = mode;
            aether_gpu_buffer_handle_t h = aether_gpu_buffer_create(c_dev, &desc);
            if (h == 0) {
                std::fprintf(stderr, "C API: buffer create with storage mode %d should succeed\n", mode);
                ++failed;
            }
            aether_gpu_buffer_destroy(c_dev, h);
        }
    }

    // ── C API: All primitive types in render draw ──
    {
        aether_gpu_command_buffer_t* cmd2 = aether_gpu_command_buffer_create(c_dev);
        aether_gpu_render_encoder_t* enc2 = aether_gpu_render_encoder_create(cmd2, &c_rt_desc);

        int prims[] = {
            AETHER_GPU_PRIMITIVE_TRIANGLE, AETHER_GPU_PRIMITIVE_TRIANGLE_STRIP,
            AETHER_GPU_PRIMITIVE_LINE, AETHER_GPU_PRIMITIVE_POINT
        };
        for (int prim : prims) {
            int rc = aether_gpu_render_draw(enc2, prim, 0, 3);
            if (rc != 0) {
                std::fprintf(stderr, "C API: render_draw with primitive %d should return 0\n", prim);
                ++failed;
            }
        }

        // All cull modes
        int culls[] = {AETHER_GPU_CULL_NONE, AETHER_GPU_CULL_FRONT, AETHER_GPU_CULL_BACK};
        for (int cull : culls) {
            int rc = aether_gpu_render_set_cull_mode(enc2, cull);
            if (rc != 0) {
                std::fprintf(stderr, "C API: render_set_cull_mode(%d) should return 0\n", cull);
                ++failed;
            }
        }

        aether_gpu_render_end(enc2);
        aether_gpu_render_encoder_destroy(enc2);
        aether_gpu_command_buffer_commit(cmd2);
        aether_gpu_command_buffer_destroy(cmd2);
    }

    // ── C API: Destroy device last ──
    aether_gpu_device_destroy(c_dev);
    // Destroying null should not crash
    aether_gpu_device_destroy(nullptr);

    // ═══════════════════════════════════════════════════════════════════════
    // GPUHandle Tests
    // ═══════════════════════════════════════════════════════════════════════

    // ── GPUHandle: default is invalid ──
    {
        GPUHandle h{};
        if (h.is_valid()) {
            std::fprintf(stderr, "GPUHandle: default should be invalid\n");
            ++failed;
        }
        if (h.packed != GPUHandle::kInvalid) {
            std::fprintf(stderr, "GPUHandle: default packed should be kInvalid\n");
            ++failed;
        }
    }

    // ── GPUHandle: make and decompose ──
    {
        GPUHandle h = GPUHandle::make(42, 7);
        if (h.index() != 42) {
            std::fprintf(stderr, "GPUHandle: index should be 42, got %u\n", h.index());
            ++failed;
        }
        if (h.generation() != 7) {
            std::fprintf(stderr, "GPUHandle: generation should be 7, got %u\n", h.generation());
            ++failed;
        }
        if (!h.is_valid()) {
            std::fprintf(stderr, "GPUHandle: make(42,7) should be valid\n");
            ++failed;
        }
    }

    // ── GPUHandle: equality ──
    {
        GPUHandle a = GPUHandle::make(10, 3);
        GPUHandle b = GPUHandle::make(10, 3);
        GPUHandle c = GPUHandle::make(10, 4);
        GPUHandle d = GPUHandle::make(11, 3);
        if (!(a == b)) {
            std::fprintf(stderr, "GPUHandle: same index+gen should be equal\n");
            ++failed;
        }
        if (a == c) {
            std::fprintf(stderr, "GPUHandle: different gen should not be equal\n");
            ++failed;
        }
        if (a == d) {
            std::fprintf(stderr, "GPUHandle: different index should not be equal\n");
            ++failed;
        }
        if (!(a != c)) {
            std::fprintf(stderr, "GPUHandle: different gen should be != \n");
            ++failed;
        }
    }

    // ── GPUHandle: max index and generation ──
    {
        GPUHandle h = GPUHandle::make(GPUHandle::kMaxIndex, GPUHandle::kMaxGeneration);
        if (h.index() != 0xFFFF) {
            std::fprintf(stderr, "GPUHandle: max index should be 0xFFFF\n");
            ++failed;
        }
        if (h.generation() != 0xFFFF) {
            std::fprintf(stderr, "GPUHandle: max generation should be 0xFFFF\n");
            ++failed;
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // GPUSlotMap Tests
    // ═══════════════════════════════════════════════════════════════════════

    // ── SlotMap: basic allocate/get/free cycle ──
    {
        GPUSlotMap<int, 8> map;
        if (!map.empty()) {
            std::fprintf(stderr, "SlotMap: new map should be empty\n");
            ++failed;
        }
        if (map.count() != 0) {
            std::fprintf(stderr, "SlotMap: new map count should be 0\n");
            ++failed;
        }
        if (map.capacity() != 8) {
            std::fprintf(stderr, "SlotMap: capacity should be 8\n");
            ++failed;
        }

        GPUHandle h = map.allocate(42);
        if (!h.is_valid()) {
            std::fprintf(stderr, "SlotMap: allocate should return valid handle\n");
            ++failed;
        }
        if (map.count() != 1) {
            std::fprintf(stderr, "SlotMap: count should be 1 after allocate\n");
            ++failed;
        }
        if (map.empty()) {
            std::fprintf(stderr, "SlotMap: should not be empty after allocate\n");
            ++failed;
        }

        int* val = map.get(h);
        if (val == nullptr) {
            std::fprintf(stderr, "SlotMap: get should return non-null\n");
            ++failed;
        } else if (*val != 42) {
            std::fprintf(stderr, "SlotMap: get should return 42, got %d\n", *val);
            ++failed;
        }

        bool freed = map.free(h);
        if (!freed) {
            std::fprintf(stderr, "SlotMap: free should return true\n");
            ++failed;
        }
        if (map.count() != 0) {
            std::fprintf(stderr, "SlotMap: count should be 0 after free\n");
            ++failed;
        }
        if (!map.empty()) {
            std::fprintf(stderr, "SlotMap: should be empty after free\n");
            ++failed;
        }
    }

    // ── SlotMap: generation increments on free ──
    {
        GPUSlotMap<int, 4> map;
        GPUHandle h1 = map.allocate(100);
        std::uint16_t gen1 = h1.generation();
        if (gen1 != 1) {
            std::fprintf(stderr, "SlotMap: first generation should be 1, got %u\n", gen1);
            ++failed;
        }

        map.free(h1);

        // Allocate again — should reuse the same index but with incremented generation
        GPUHandle h2 = map.allocate(200);
        if (h2.index() != h1.index()) {
            std::fprintf(stderr, "SlotMap: should reuse freed index\n");
            ++failed;
        }
        std::uint16_t gen2 = h2.generation();
        if (gen2 != 2) {
            std::fprintf(stderr, "SlotMap: second generation should be 2, got %u\n", gen2);
            ++failed;
        }
    }

    // ── SlotMap: stale handle returns nullptr ──
    {
        GPUSlotMap<int, 4> map;
        GPUHandle h1 = map.allocate(10);
        map.free(h1);
        GPUHandle h2 = map.allocate(20);

        // h1 is stale — same index but old generation
        int* stale = map.get(h1);
        if (stale != nullptr) {
            std::fprintf(stderr, "SlotMap: stale handle should return nullptr\n");
            ++failed;
        }

        // h2 should work
        int* current = map.get(h2);
        if (current == nullptr || *current != 20) {
            std::fprintf(stderr, "SlotMap: new handle should return correct value\n");
            ++failed;
        }

        // Double free of stale handle should fail
        bool double_free = map.free(h1);
        if (double_free) {
            std::fprintf(stderr, "SlotMap: freeing stale handle should return false\n");
            ++failed;
        }
    }

    // ── SlotMap: fill to capacity, verify full ──
    {
        GPUSlotMap<int, 4> map;
        GPUHandle handles[4];
        for (int i = 0; i < 4; ++i) {
            handles[i] = map.allocate(i * 10);
            if (!handles[i].is_valid()) {
                std::fprintf(stderr, "SlotMap: allocate %d should succeed\n", i);
                ++failed;
            }
        }
        if (map.count() != 4) {
            std::fprintf(stderr, "SlotMap: count should be 4 when full\n");
            ++failed;
        }

        // Should fail when full
        GPUHandle overflow = map.allocate(999);
        if (overflow.is_valid()) {
            std::fprintf(stderr, "SlotMap: allocate when full should return invalid handle\n");
            ++failed;
        }

        // All existing handles should still work
        for (int i = 0; i < 4; ++i) {
            int* v = map.get(handles[i]);
            if (v == nullptr || *v != i * 10) {
                std::fprintf(stderr, "SlotMap: get(%d) should return %d\n", i, i * 10);
                ++failed;
            }
        }
    }

    // ── SlotMap: free and reallocate same slot, old handle invalid ──
    {
        GPUSlotMap<int, 4> map;
        GPUHandle h1 = map.allocate(100);
        GPUHandle h2 = map.allocate(200);
        GPUHandle h3 = map.allocate(300);

        // Free middle slot
        bool ok = map.free(h2);
        if (!ok) {
            std::fprintf(stderr, "SlotMap: free h2 should succeed\n");
            ++failed;
        }

        // Reallocate — should reuse h2's index
        GPUHandle h4 = map.allocate(400);
        if (!h4.is_valid()) {
            std::fprintf(stderr, "SlotMap: reallocate after free should succeed\n");
            ++failed;
        }
        if (h4.index() != h2.index()) {
            std::fprintf(stderr, "SlotMap: reallocated handle should reuse freed index\n");
            ++failed;
        }

        // Old handle h2 should be invalid
        int* stale = map.get(h2);
        if (stale != nullptr) {
            std::fprintf(stderr, "SlotMap: old handle after realloc should return nullptr\n");
            ++failed;
        }

        // New handle h4 should work
        int* v4 = map.get(h4);
        if (v4 == nullptr || *v4 != 400) {
            std::fprintf(stderr, "SlotMap: new handle should return 400\n");
            ++failed;
        }

        // Other handles still valid
        int* v1 = map.get(h1);
        int* v3 = map.get(h3);
        if (v1 == nullptr || *v1 != 100) {
            std::fprintf(stderr, "SlotMap: h1 should still be valid\n");
            ++failed;
        }
        if (v3 == nullptr || *v3 != 300) {
            std::fprintf(stderr, "SlotMap: h3 should still be valid\n");
            ++failed;
        }
    }

    // ── SlotMap: clear resets occupancy but NOT generations ──
    {
        GPUSlotMap<int, 4> map;
        GPUHandle h1 = map.allocate(10);
        GPUHandle h2 = map.allocate(20);

        map.clear();

        if (map.count() != 0) {
            std::fprintf(stderr, "SlotMap: count should be 0 after clear\n");
            ++failed;
        }
        if (!map.empty()) {
            std::fprintf(stderr, "SlotMap: should be empty after clear\n");
            ++failed;
        }

        // Old handles should be invalid after clear
        int* stale1 = map.get(h1);
        int* stale2 = map.get(h2);
        if (stale1 != nullptr) {
            std::fprintf(stderr, "SlotMap: h1 should be invalid after clear\n");
            ++failed;
        }
        if (stale2 != nullptr) {
            std::fprintf(stderr, "SlotMap: h2 should be invalid after clear\n");
            ++failed;
        }

        // Allocate again — generation should still be 1 (unchanged by clear)
        // because clear preserves generations
        GPUHandle h3 = map.allocate(30);
        if (!h3.is_valid()) {
            std::fprintf(stderr, "SlotMap: allocate after clear should succeed\n");
            ++failed;
        }
        // The generation was 1 when allocated, not bumped by clear,
        // so reallocation at the same slot reuses the same generation.
        // But stale handles still fail because clear set occupied=false.
        int* v3 = map.get(h3);
        if (v3 == nullptr || *v3 != 30) {
            std::fprintf(stderr, "SlotMap: get after clear+reallocate should return 30\n");
            ++failed;
        }
    }

    // ── SlotMap: multiple allocate/free cycles verify generation wrapping ──
    {
        GPUSlotMap<int, 2> map;

        // We'll cycle through generations on slot index 0.
        // Generations start at 1 and increment on each free.
        // After 0xFFFF (65535) frees, generation should wrap to 1 (skipping 0).
        GPUHandle prev_handle{};
        bool wrap_detected = false;

        // Cycle enough to see wrapping. Generation starts at 1.
        // After 65534 frees, generation is 65535. After one more free, it wraps to 1.
        // We test a smaller cycle to confirm generation increments, then
        // directly test the wrap boundary.
        for (int i = 0; i < 10; ++i) {
            GPUHandle h = map.allocate(i);
            if (!h.is_valid()) {
                std::fprintf(stderr, "SlotMap: cycle %d allocate should succeed\n", i);
                ++failed;
                break;
            }
            if (i > 0 && h.index() == prev_handle.index()) {
                // Same index, generation should have incremented
                if (h.generation() <= prev_handle.generation() && h.generation() != 1) {
                    // Only valid if wrapping happened
                    if (prev_handle.generation() != GPUHandle::kMaxGeneration || h.generation() != 1) {
                        std::fprintf(stderr, "SlotMap: generation should increment, prev=%u cur=%u\n",
                                     prev_handle.generation(), h.generation());
                        ++failed;
                    }
                }
            }
            prev_handle = h;
            map.free(h);
        }

        // Now test exact wrap boundary: manually cycle to kMaxGeneration.
        // We already did 10 alloc/free cycles above. The generation for
        // the first slot (index depending on free_list order) should be 11.
        // Let's use a fresh map for the wrap test.
        GPUSlotMap<std::uint16_t, 1> wrap_map;

        // Cycle through 65534 alloc/free to reach generation 65535
        for (std::uint32_t i = 0; i < 65534; ++i) {
            GPUHandle h = wrap_map.allocate(static_cast<std::uint16_t>(i & 0xFFFF));
            wrap_map.free(h);
        }

        // Generation should now be 65535 (started at 1, freed 65534 times => 1+65534=65535)
        GPUHandle h_max = wrap_map.allocate(static_cast<std::uint16_t>(0xAAAA));
        if (h_max.generation() != 0xFFFF) {
            std::fprintf(stderr, "SlotMap: generation should be 0xFFFF before wrap, got %u\n",
                         h_max.generation());
            ++failed;
        }
        wrap_map.free(h_max);

        // After one more free, generation should wrap to 1 (skipping 0)
        GPUHandle h_wrap = wrap_map.allocate(static_cast<std::uint16_t>(0xBBBB));
        if (h_wrap.generation() != 1) {
            std::fprintf(stderr, "SlotMap: generation should wrap to 1, got %u\n",
                         h_wrap.generation());
            ++failed;
        } else {
            wrap_detected = true;
        }

        // Stale max-generation handle should fail
        std::uint16_t* stale = wrap_map.get(h_max);
        if (stale != nullptr) {
            std::fprintf(stderr, "SlotMap: stale max-gen handle should return nullptr\n");
            ++failed;
        }

        // Current handle should work
        std::uint16_t* current = wrap_map.get(h_wrap);
        if (current == nullptr || *current != 0xBBBB) {
            std::fprintf(stderr, "SlotMap: wrapped handle should return 0xBBBB\n");
            ++failed;
        }

        if (!wrap_detected) {
            std::fprintf(stderr, "SlotMap: generation wrapping was not verified\n");
            ++failed;
        }
    }

    // ── SlotMap: invalid handle operations ──
    {
        GPUSlotMap<int, 4> map;

        // Get with invalid handle
        GPUHandle invalid{};
        int* val = map.get(invalid);
        if (val != nullptr) {
            std::fprintf(stderr, "SlotMap: get(invalid) should return nullptr\n");
            ++failed;
        }

        // Free with invalid handle
        bool freed = map.free(invalid);
        if (freed) {
            std::fprintf(stderr, "SlotMap: free(invalid) should return false\n");
            ++failed;
        }

        // Get with out-of-range index
        GPUHandle oob = GPUHandle::make(100, 1);  // index 100 > capacity 4
        int* oob_val = map.get(oob);
        if (oob_val != nullptr) {
            std::fprintf(stderr, "SlotMap: get(out-of-range) should return nullptr\n");
            ++failed;
        }
    }

    // ── SlotMap: const get ──
    {
        GPUSlotMap<int, 4> map;
        GPUHandle h = map.allocate(77);

        const auto& const_map = map;
        const int* val = const_map.get(h);
        if (val == nullptr || *val != 77) {
            std::fprintf(stderr, "SlotMap: const get should return 77\n");
            ++failed;
        }

        // Const get with invalid handle
        GPUHandle invalid{};
        const int* inv_val = const_map.get(invalid);
        if (inv_val != nullptr) {
            std::fprintf(stderr, "SlotMap: const get(invalid) should return nullptr\n");
            ++failed;
        }
    }

    // ── SlotMap: move value ──
    {
        // Test that allocate(T&&) works with a moveable type.
        // Using a simple struct with an int to verify the value is moved correctly.
        struct Resource {
            int id{0};
        };

        GPUSlotMap<Resource, 4> map;
        Resource r{};
        r.id = 555;
        GPUHandle h = map.allocate(static_cast<Resource&&>(r));
        if (!h.is_valid()) {
            std::fprintf(stderr, "SlotMap: move allocate should return valid handle\n");
            ++failed;
        }
        Resource* stored = map.get(h);
        if (stored == nullptr || stored->id != 555) {
            std::fprintf(stderr, "SlotMap: moved resource id should be 555\n");
            ++failed;
        }
    }

    std::fprintf(stdout, "gpu_resource_test: %d failures\n", failed);
    return failed;
}
