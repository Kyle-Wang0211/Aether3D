// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// Phase 6.2.G smoke — DawnGPUDevice factory + capabilities + shader load.
//
// Verifies the production-path device construction works end-to-end with
// the harness-tested limits + features carried into init():
//   - Subgroups feature (with graceful fallback if unsupported)
//   - maxComputeInvocationsPerWorkgroup = 512
//   - maxComputeWorkgroupSizeX = 512
//   - maxStorageBuffersPerShaderStage = 10
//   - SetUncapturedErrorCallback registered (abort path)
//
// And the Step 2 shader registry / load_shader path:
//   - register_wgsl_source() stores WGSL bytes
//   - device.load_shader() compiles via Tint, returns valid handle
//   - device.destroy_shader() releases the WGPUShaderModule
//
// This is the simplest possible regression catcher for Phase 6.2.G —
// if init() OR shader compilation ever drifts, this smoke fails at the
// factory call OR the load_shader call respectively.

#include "aether/render/dawn_gpu_device.h"
#include "aether/render/gpu_device.h"
#include "aether/render/runtime_backend.h"

#include <cstdio>
#include <cstdlib>
#include <string>

int main() {
    using namespace aether::render;

    auto device = create_dawn_gpu_device(/*request_high_performance=*/true);
    if (!device) {
        std::fprintf(stderr, "FAIL: create_dawn_gpu_device returned nullptr\n");
        return EXIT_FAILURE;
    }

    if (device->backend() != GraphicsBackend::kDawn) {
        std::fprintf(stderr, "FAIL: backend() != kDawn\n");
        return EXIT_FAILURE;
    }

    GPUCaps caps = device->capabilities();
    if (caps.backend != GraphicsBackend::kDawn) {
        std::fprintf(stderr, "FAIL: caps.backend != kDawn\n");
        return EXIT_FAILURE;
    }
    if (!caps.supports_compute) {
        std::fprintf(stderr, "FAIL: caps.supports_compute false (Dawn must support compute)\n");
        return EXIT_FAILURE;
    }

    GPUMemoryStats stats = device->memory_stats();
    if (stats.allocated_bytes != 0 || stats.buffer_count != 0) {
        std::fprintf(stderr, "FAIL: fresh device has non-zero memory stats: "
                            "allocated=%zu buffers=%u\n",
                            stats.allocated_bytes, stats.buffer_count);
        return EXIT_FAILURE;
    }

    std::printf("=== aether_dawn_gpu_device_smoke ===\n");
    std::printf("backend            : %u (kDawn=4)\n", static_cast<unsigned>(caps.backend));
    std::printf("max_buffer_size    : %u\n", caps.max_buffer_size);
    std::printf("supports_compute   : %s\n", caps.supports_compute ? "true" : "false");
    std::printf("device created cleanly with subgroups + bumped limits\n");

    // ─── Step 2: shader registry + load_shader ─────────────────────────
    if (!register_wgsl_from_file(*device, "project_forward",
                                 "aether_cpp/shaders/wgsl/project_forward.wgsl")) {
        std::fprintf(stderr, "FAIL: register_wgsl_from_file(project_forward) returned false\n");
        return EXIT_FAILURE;
    }

    GPUShaderHandle compute_handle =
        device->load_shader("project_forward", GPUShaderStage::kCompute);
    if (!compute_handle.valid()) {
        std::fprintf(stderr, "FAIL: load_shader returned invalid handle\n");
        return EXIT_FAILURE;
    }
    std::printf("compiled compute shader: handle=%u\n", compute_handle.id);

    // Negative test: load_shader on a name that wasn't registered should
    // return an invalid handle without aborting.
    GPUShaderHandle bad_handle =
        device->load_shader("never_registered_kernel", GPUShaderStage::kCompute);
    if (bad_handle.valid()) {
        std::fprintf(stderr, "FAIL: unregistered name returned valid handle %u\n",
                     bad_handle.id);
        return EXIT_FAILURE;
    }
    std::printf("unregistered name → invalid handle (correct, no abort)\n");

    // ─── Step 3: create_compute_pipeline ───────────────────────────────
    GPUComputePipelineHandle compute_pipe =
        device->create_compute_pipeline(compute_handle);
    if (!compute_pipe.valid()) {
        std::fprintf(stderr, "FAIL: create_compute_pipeline returned invalid handle\n");
        return EXIT_FAILURE;
    }
    std::printf("created compute pipeline: handle=%u\n", compute_pipe.id);

    // ─── Step 4: create_render_pipeline (splat_render's vs/fs) ─────────
    if (!register_wgsl_from_file(*device, "splat_render_vs",
                                 "aether_cpp/shaders/wgsl/splat_render.wgsl",
                                 /*entry_point=*/"vs_main")) {
        std::fprintf(stderr, "FAIL: register splat_render vs\n");
        return EXIT_FAILURE;
    }
    if (!register_wgsl_from_file(*device, "splat_render_fs",
                                 "aether_cpp/shaders/wgsl/splat_render.wgsl",
                                 /*entry_point=*/"fs_main")) {
        std::fprintf(stderr, "FAIL: register splat_render fs\n");
        return EXIT_FAILURE;
    }
    GPUShaderHandle vs_handle = device->load_shader("splat_render_vs", GPUShaderStage::kVertex);
    GPUShaderHandle fs_handle = device->load_shader("splat_render_fs", GPUShaderStage::kFragment);
    if (!vs_handle.valid() || !fs_handle.valid()) {
        std::fprintf(stderr, "FAIL: load_shader vs/fs (vs=%u fs=%u)\n",
                     vs_handle.id, fs_handle.id);
        return EXIT_FAILURE;
    }

    GPURenderTargetDesc rt_desc{};
    rt_desc.color_format = GPUTextureFormat::kRGBA8Unorm;
    rt_desc.depth_format = GPUTextureFormat::kInvalid;  // no depth for splats
    rt_desc.width = 256;
    rt_desc.height = 256;
    rt_desc.sample_count = 1;
    rt_desc.blending_enabled = true;  // → premultiplied alpha
    rt_desc.depth_test_enabled = false;
    rt_desc.depth_write_enabled = false;
    rt_desc.color_attachment_count = 1;

    GPURenderPipelineHandle render_pipe =
        device->create_render_pipeline(vs_handle, fs_handle, rt_desc);
    if (!render_pipe.valid()) {
        std::fprintf(stderr, "FAIL: create_render_pipeline returned invalid handle\n");
        return EXIT_FAILURE;
    }
    std::printf("created render pipeline (splat_render premultiplied): handle=%u\n",
                render_pipe.id);

    // ─── Step 5: create_texture ────────────────────────────────────────
    GPUTextureDesc tex_desc{};
    tex_desc.width = 256;
    tex_desc.height = 256;
    tex_desc.depth = 1;
    tex_desc.mip_levels = 1;
    tex_desc.format = GPUTextureFormat::kRGBA8Unorm;
    tex_desc.usage_mask = static_cast<std::uint8_t>(GPUTextureUsage::kRenderTarget);
    tex_desc.label = "splat_render_target";

    GPUTextureHandle tex_handle = device->create_texture(tex_desc);
    if (!tex_handle.valid()) {
        std::fprintf(stderr, "FAIL: create_texture returned invalid handle\n");
        return EXIT_FAILURE;
    }
    std::printf("created render target: handle=%u (256x256 RGBA8Unorm)\n",
                tex_handle.id);

    // Sanity: stats reflect new texture.
    GPUMemoryStats stats2 = device->memory_stats();
    if (stats2.texture_count != 1) {
        std::fprintf(stderr, "FAIL: texture_count expected 1, got %u\n",
                     stats2.texture_count);
        return EXIT_FAILURE;
    }

    device->destroy_texture(tex_handle);
    device->destroy_render_pipeline(render_pipe);
    device->destroy_shader(fs_handle);
    device->destroy_shader(vs_handle);
    device->destroy_compute_pipeline(compute_pipe);
    device->destroy_shader(compute_handle);
    std::printf("all shader/pipeline/texture handles destroyed cleanly\n");

    std::printf("PASS\n");
    return EXIT_SUCCESS;
}
