// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// Phase 6.2.G-K Step 10 — project_forward.wgsl via DawnGPUDevice path.
//
// Same test as aether_dawn_splat_smoke_project_forward (the harness
// version), but routed through the production DawnGPUDevice + GPUDevice
// virtual API instead of DawnKernelHarness. Validates that all of
// Steps 1-9 compose end-to-end:
//   - device factory + limits/features (Step 1)
//   - register_wgsl + load_shader (Step 2)
//   - create_compute_pipeline (Step 3)
//   - create_buffer / update_buffer (6.2.F + Step 5)
//   - DawnComputeEncoder + DawnCommandBuffer (Steps 6-8)
//   - kStaging buffer + map_buffer for readback (6.2.F)
//
// Expected output (matches harness smoke 1): num_visible=4, depths=[2,4,6,8]

#include "aether_dawn_splat_test_data.h"

#include "aether/render/dawn_gpu_device.h"
#include "aether/render/gpu_command.h"
#include "aether/render/gpu_device.h"

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

using aether::tools::splat_test_data::RenderArgsStorage;
using aether::tools::splat_test_data::PackedVec3;
using aether::tools::splat_test_data::make_identity_camera_args;

int main() {
    using namespace aether::render;

    auto device = create_dawn_gpu_device();
    if (!device) {
        std::fprintf(stderr, "FAIL: create_dawn_gpu_device returned nullptr\n");
        return EXIT_FAILURE;
    }

    // ─── Inputs ────────────────────────────────────────────────────────
    constexpr std::uint32_t kNumSplats = 4;
    RenderArgsStorage uniforms = make_identity_camera_args(kNumSplats);

    PackedVec3 means[kNumSplats] = {
        {0.0f, 0.0f, 2.0f},
        {0.0f, 0.0f, 4.0f},
        {0.0f, 0.0f, 6.0f},
        {0.0f, 0.0f, 8.0f},
    };

    // Buffer setup. project_forward.wgsl bindings (7 total, all storage):
    //   0 uniforms       (read_write — atomicAdd to num_visible)
    //   1 means          (PackedVec3 array)
    //   2 quats          (vec4 array)
    //   3 log_scales     (PackedVec3 array)
    //   4 raw_opacities  (f32 array)
    //   5 global_from_compact_gid (output)
    //   6 depths         (output)

    PackedVec3 log_scales[kNumSplats] = {{0,0,0},{0,0,0},{0,0,0},{0,0,0}};
    float quats[kNumSplats][4] = {
        {1.0f, 0.0f, 0.0f, 0.0f},
        {1.0f, 0.0f, 0.0f, 0.0f},
        {1.0f, 0.0f, 0.0f, 0.0f},
        {1.0f, 0.0f, 0.0f, 0.0f},
    };
    float raw_opacities[kNumSplats] = {1.0f, 1.0f, 1.0f, 1.0f};

    auto make_storage = [&](std::size_t bytes, const char* label) {
        GPUBufferDesc desc{};
        desc.size_bytes = bytes;
        desc.storage = GPUStorageMode::kPrivate;
        desc.usage_mask = static_cast<std::uint8_t>(GPUBufferUsage::kStorage);
        desc.label = label;
        return device->create_buffer(desc);
    };
    auto make_staging = [&](std::size_t bytes, const char* label) {
        GPUBufferDesc desc{};
        desc.size_bytes = bytes;
        desc.storage = GPUStorageMode::kShared;
        desc.usage_mask = static_cast<std::uint8_t>(GPUBufferUsage::kStaging);
        desc.label = label;
        return device->create_buffer(desc);
    };

    // The DawnGPUDevice's create_buffer maps kStorage → CopySrc|CopyDst|Storage,
    // so update_buffer (queue.WriteBuffer) is allowed for input buffers.
    GPUBufferHandle h_uniforms = make_storage(sizeof(uniforms), "uniforms");
    GPUBufferHandle h_means    = make_storage(sizeof(means),    "means");
    GPUBufferHandle h_quats    = make_storage(sizeof(quats),    "quats");
    GPUBufferHandle h_logsc    = make_storage(sizeof(log_scales), "log_scales");
    GPUBufferHandle h_opac     = make_storage(sizeof(raw_opacities), "raw_opacities");
    GPUBufferHandle h_gid_out  = make_storage(kNumSplats * sizeof(std::uint32_t), "gid_out");
    GPUBufferHandle h_depth_out= make_storage(kNumSplats * sizeof(float),         "depth_out");

    if (!h_uniforms.valid() || !h_means.valid() || !h_gid_out.valid() ||
        !h_depth_out.valid()) {
        std::fprintf(stderr, "FAIL: create_buffer\n");
        return EXIT_FAILURE;
    }

    device->update_buffer(h_uniforms, &uniforms, 0, sizeof(uniforms));
    device->update_buffer(h_means,    means,     0, sizeof(means));
    device->update_buffer(h_quats,    quats,     0, sizeof(quats));
    device->update_buffer(h_logsc,    log_scales,0, sizeof(log_scales));
    device->update_buffer(h_opac,     raw_opacities, 0, sizeof(raw_opacities));

    // ─── Shader + pipeline ─────────────────────────────────────────────
    if (!register_wgsl_from_file(*device, "project_forward",
                                 "aether_cpp/shaders/wgsl/project_forward.wgsl")) {
        std::fprintf(stderr, "FAIL: register WGSL\n");
        return EXIT_FAILURE;
    }
    GPUShaderHandle shader = device->load_shader("project_forward", GPUShaderStage::kCompute);
    GPUComputePipelineHandle pipeline = device->create_compute_pipeline(shader);
    if (!pipeline.valid()) {
        std::fprintf(stderr, "FAIL: pipeline\n");
        return EXIT_FAILURE;
    }

    // ─── Encode + dispatch ─────────────────────────────────────────────
    auto cb = device->create_command_buffer();
    if (!cb) { std::fprintf(stderr, "FAIL: create_command_buffer\n"); return EXIT_FAILURE; }
    auto* ce = cb->make_compute_encoder();
    if (!ce) { std::fprintf(stderr, "FAIL: make_compute_encoder\n"); return EXIT_FAILURE; }

    ce->set_pipeline(pipeline);
    ce->set_buffer(h_uniforms, 0, 0);
    ce->set_buffer(h_means,    0, 1);
    ce->set_buffer(h_quats,    0, 2);
    ce->set_buffer(h_logsc,    0, 3);
    ce->set_buffer(h_opac,     0, 4);
    ce->set_buffer(h_gid_out,  0, 5);
    ce->set_buffer(h_depth_out,0, 6);

    // workgroup_size(256) → 1 workgroup covers up to 256 splats.
    const std::uint32_t wg_x = (kNumSplats + 255) / 256;
    ce->dispatch(wg_x, 1, 1, /*threads_x=*/256, /*threads_y=*/1, /*threads_z=*/1);
    ce->end_encoding();
    cb->commit();
    cb->wait_until_completed();

    if (cb->had_error()) {
        std::fprintf(stderr, "FAIL: command buffer reported error\n");
        return EXIT_FAILURE;
    }

    // ─── Readback via dawn_copy_buffer_to_buffer + map_buffer ──────────
    GPUBufferHandle h_depth_staging =
        make_staging(kNumSplats * sizeof(float), "depth_staging");
    GPUBufferHandle h_gid_staging =
        make_staging(kNumSplats * sizeof(std::uint32_t), "gid_staging");

    if (!dawn_copy_buffer_to_buffer(*device, h_depth_out, h_depth_staging,
                                     kNumSplats * sizeof(float))) {
        std::fprintf(stderr, "FAIL: copy depth_out → staging\n");
        return EXIT_FAILURE;
    }
    if (!dawn_copy_buffer_to_buffer(*device, h_gid_out, h_gid_staging,
                                     kNumSplats * sizeof(std::uint32_t))) {
        std::fprintf(stderr, "FAIL: copy gid_out → staging\n");
        return EXIT_FAILURE;
    }

    void* depth_mapped = device->map_buffer(h_depth_staging);
    void* gid_mapped   = device->map_buffer(h_gid_staging);
    if (!depth_mapped || !gid_mapped) {
        std::fprintf(stderr, "FAIL: map_buffer (depth=%p gid=%p)\n",
                     depth_mapped, gid_mapped);
        return EXIT_FAILURE;
    }
    float depths[kNumSplats];
    std::uint32_t gids[kNumSplats];
    std::memcpy(depths, depth_mapped, sizeof(depths));
    std::memcpy(gids,   gid_mapped,   sizeof(gids));
    device->unmap_buffer(h_depth_staging);
    device->unmap_buffer(h_gid_staging);

    // ─── Verification ─────────────────────────────────────────────────
    std::printf("=== aether_dawn_splat_smoke_project_forward_via_device ===\n");
    std::printf("dispatched project_forward.wgsl through DawnGPUDevice\n");
    std::printf("  shader handle:   %u\n", shader.id);
    std::printf("  pipeline handle: %u\n", pipeline.id);
    std::printf("  depths: %.3f %.3f %.3f %.3f\n",
                depths[0], depths[1], depths[2], depths[3]);

    // Expected (matches harness smoke 1): depths=[2,4,6,8] for our
    // splats at z={2,4,6,8} under identity view matrix.
    const float expected_depths[kNumSplats] = {2.0f, 4.0f, 6.0f, 8.0f};
    for (std::uint32_t i = 0; i < kNumSplats; ++i) {
        if (std::abs(depths[i] - expected_depths[i]) > 1e-4f) {
            std::fprintf(stderr,
                "FAIL: depths[%u] = %f, expected %f (matches harness smoke 1)\n",
                i, depths[i], expected_depths[i]);
            return EXIT_FAILURE;
        }
    }
    std::printf("depths match harness smoke 1 within 1e-4f\n");

    device->destroy_buffer(h_depth_staging);
    device->destroy_buffer(h_gid_staging);
    device->destroy_compute_pipeline(pipeline);
    device->destroy_shader(shader);
    device->destroy_buffer(h_uniforms);
    device->destroy_buffer(h_means);
    device->destroy_buffer(h_quats);
    device->destroy_buffer(h_logsc);
    device->destroy_buffer(h_opac);
    device->destroy_buffer(h_gid_out);
    device->destroy_buffer(h_depth_out);
    std::printf("teardown clean (memory_stats.buffer_count = %u)\n",
                device->memory_stats().buffer_count);

    std::printf("PASS\n");
    return EXIT_SUCCESS;
}
