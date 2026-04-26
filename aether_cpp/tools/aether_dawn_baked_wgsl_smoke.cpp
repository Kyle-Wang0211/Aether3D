// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// Phase 6.4a Q1 verification — baked WGSL bit-exact vs file-loaded WGSL.
//
// Runs project_forward.wgsl twice on the same DawnGPUDevice:
//   (a) register_wgsl_from_file: reads aether_cpp/shaders/wgsl/project_forward.wgsl
//   (b) register_baked_wgsl_into_device: uses the build-time baked source
//
// Asserts the dispatch output (depths array) is bit-exact identical.
//
// This is the Q1 DoD line item:
//   "DawnGPUDevice 跑 splat_render baked 版本输出与 file-based 版本
//    bit-exact 一致(双路径回归对照)"
// applied to project_forward (simpler verification target than splat_render
// since the output is 4 floats, not 65536 RGBA pixels).
//
// If this smoke fails, the bake is dropping characters / changing
// encoding / wrapping the WGSL incorrectly. The regression catcher is
// intentionally strict: byte-equal, not "1 LSB equivalent".

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

namespace {
constexpr std::uint32_t kNumSplats = 4;

// Run project_forward through the device with a pre-registered shader
// name. Returns the 4 depth floats as a vector for caller comparison.
std::vector<float> run_project_forward(aether::render::GPUDevice& device,
                                        const char* shader_name) {
    using namespace aether::render;

    RenderArgsStorage uniforms = make_identity_camera_args(kNumSplats);
    PackedVec3 means[kNumSplats] = {
        {0.0f, 0.0f, 2.0f},
        {0.0f, 0.0f, 4.0f},
        {0.0f, 0.0f, 6.0f},
        {0.0f, 0.0f, 8.0f},
    };
    PackedVec3 log_scales[kNumSplats] = {{0,0,0},{0,0,0},{0,0,0},{0,0,0}};
    float quats[kNumSplats][4] = {
        {1.0f, 0.0f, 0.0f, 0.0f}, {1.0f, 0.0f, 0.0f, 0.0f},
        {1.0f, 0.0f, 0.0f, 0.0f}, {1.0f, 0.0f, 0.0f, 0.0f},
    };
    float raw_opacities[kNumSplats] = {1.0f, 1.0f, 1.0f, 1.0f};

    auto make_storage = [&](std::size_t bytes, const char* label) {
        GPUBufferDesc desc{};
        desc.size_bytes = bytes;
        desc.storage = GPUStorageMode::kPrivate;
        desc.usage_mask = static_cast<std::uint8_t>(GPUBufferUsage::kStorage);
        desc.label = label;
        return device.create_buffer(desc);
    };
    auto make_staging = [&](std::size_t bytes, const char* label) {
        GPUBufferDesc desc{};
        desc.size_bytes = bytes;
        desc.storage = GPUStorageMode::kShared;
        desc.usage_mask = static_cast<std::uint8_t>(GPUBufferUsage::kStaging);
        desc.label = label;
        return device.create_buffer(desc);
    };

    GPUBufferHandle h_uniforms = make_storage(sizeof(uniforms), "uniforms");
    GPUBufferHandle h_means    = make_storage(sizeof(means),    "means");
    GPUBufferHandle h_quats    = make_storage(sizeof(quats),    "quats");
    GPUBufferHandle h_logsc    = make_storage(sizeof(log_scales), "log_scales");
    GPUBufferHandle h_opac     = make_storage(sizeof(raw_opacities), "opac");
    GPUBufferHandle h_gid_out  = make_storage(kNumSplats * sizeof(std::uint32_t), "gid");
    GPUBufferHandle h_depth_out= make_storage(kNumSplats * sizeof(float), "depth");

    device.update_buffer(h_uniforms, &uniforms, 0, sizeof(uniforms));
    device.update_buffer(h_means,    means,     0, sizeof(means));
    device.update_buffer(h_quats,    quats,     0, sizeof(quats));
    device.update_buffer(h_logsc,    log_scales,0, sizeof(log_scales));
    device.update_buffer(h_opac,     raw_opacities, 0, sizeof(raw_opacities));

    GPUShaderHandle shader = device.load_shader(shader_name, GPUShaderStage::kCompute);
    if (!shader.valid()) return {};
    GPUComputePipelineHandle pipeline = device.create_compute_pipeline(shader);
    if (!pipeline.valid()) return {};

    auto cb = device.create_command_buffer();
    auto* ce = cb->make_compute_encoder();
    ce->set_pipeline(pipeline);
    ce->set_buffer(h_uniforms, 0, 0);
    ce->set_buffer(h_means,    0, 1);
    ce->set_buffer(h_quats,    0, 2);
    ce->set_buffer(h_logsc,    0, 3);
    ce->set_buffer(h_opac,     0, 4);
    ce->set_buffer(h_gid_out,  0, 5);
    ce->set_buffer(h_depth_out,0, 6);
    ce->dispatch((kNumSplats + 255) / 256, 1, 1, 256, 1, 1);
    ce->end_encoding();
    cb->commit();
    cb->wait_until_completed();

    GPUBufferHandle staging = make_staging(kNumSplats * sizeof(float), "staging");
    if (!dawn_copy_buffer_to_buffer(device, h_depth_out, staging,
                                     kNumSplats * sizeof(float))) {
        return {};
    }
    void* mapped = device.map_buffer(staging);
    if (!mapped) return {};
    std::vector<float> result(kNumSplats);
    std::memcpy(result.data(), mapped, kNumSplats * sizeof(float));
    device.unmap_buffer(staging);

    device.destroy_buffer(staging);
    device.destroy_compute_pipeline(pipeline);
    device.destroy_shader(shader);
    device.destroy_buffer(h_depth_out);
    device.destroy_buffer(h_gid_out);
    device.destroy_buffer(h_opac);
    device.destroy_buffer(h_logsc);
    device.destroy_buffer(h_quats);
    device.destroy_buffer(h_means);
    device.destroy_buffer(h_uniforms);
    return result;
}

}  // namespace

int main() {
    using namespace aether::render;

    auto device = create_dawn_gpu_device();
    if (!device) {
        std::fprintf(stderr, "FAIL: device\n");
        return EXIT_FAILURE;
    }

    // Path A: file-loaded WGSL (same as project_forward_via_device sentinel).
    if (!register_wgsl_from_file(*device, "project_forward_from_file",
                                 "aether_cpp/shaders/wgsl/project_forward.wgsl")) {
        std::fprintf(stderr, "FAIL: register_wgsl_from_file\n");
        return EXIT_FAILURE;
    }
    auto depths_file = run_project_forward(*device, "project_forward_from_file");
    if (depths_file.size() != kNumSplats) {
        std::fprintf(stderr, "FAIL: file-path output empty\n");
        return EXIT_FAILURE;
    }

    // Path B: baked WGSL.
    register_baked_wgsl_into_device(*device);
    auto depths_baked = run_project_forward(*device, "project_forward");
    if (depths_baked.size() != kNumSplats) {
        std::fprintf(stderr, "FAIL: baked-path output empty\n");
        return EXIT_FAILURE;
    }

    // Bit-exact comparison.
    std::printf("=== aether_dawn_baked_wgsl_smoke ===\n");
    std::printf("file-loaded  depths: %.6f %.6f %.6f %.6f\n",
                depths_file[0], depths_file[1], depths_file[2], depths_file[3]);
    std::printf("baked        depths: %.6f %.6f %.6f %.6f\n",
                depths_baked[0], depths_baked[1], depths_baked[2], depths_baked[3]);

    if (std::memcmp(depths_file.data(), depths_baked.data(),
                    kNumSplats * sizeof(float)) != 0) {
        std::fprintf(stderr, "FAIL: byte-by-byte mismatch between file and baked outputs\n");
        for (std::uint32_t i = 0; i < kNumSplats; ++i) {
            if (depths_file[i] != depths_baked[i]) {
                std::fprintf(stderr,
                    "  depths[%u] file=%a baked=%a (delta=%.9f)\n",
                    i, depths_file[i], depths_baked[i],
                    depths_file[i] - depths_baked[i]);
            }
        }
        return EXIT_FAILURE;
    }

    std::printf("PASS — baked WGSL produces bit-exact same output as file-loaded WGSL\n");
    return EXIT_SUCCESS;
}
