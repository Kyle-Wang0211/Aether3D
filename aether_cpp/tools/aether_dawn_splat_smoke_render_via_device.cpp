// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// Phase 6.2.G-K Step 10 — splat_render.wgsl via DawnGPUDevice path.
//
// Same test as aether_dawn_splat_smoke_render (the harness version), but
// routed through the production DawnGPUDevice + GPUDevice virtual API.
// Validates the full render-pass path:
//   - register_wgsl with separate vs/fs entry points (Step 2)
//   - load_shader for vertex + fragment stages
//   - create_render_pipeline with premultiplied alpha (Step 4)
//   - create_texture for render target (Step 5)
//   - DawnRenderEncoder via make_render_encoder (Steps 7-8)
//   - readback_texture (Step 9) — 256-byte row alignment + unpadding
//
// Expected output (matches harness smoke 4): center pixel non-black,
// corner pixel zero, Gaussian falloff.

#include "aether_dawn_splat_test_data.h"

#include "aether/render/dawn_gpu_device.h"
#include "aether/render/gpu_command.h"
#include "aether/render/gpu_device.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

using aether::tools::splat_test_data::RenderArgsStorage;
using aether::tools::splat_test_data::ProjectedSplat;
using aether::tools::splat_test_data::make_identity_camera_args;

namespace {
constexpr std::uint32_t kImgW = 256;
constexpr std::uint32_t kImgH = 256;
constexpr std::uint32_t kBpp = 4;
constexpr std::uint32_t kNumSplats = 4;
}

int main() {
    using namespace aether::render;

    auto device = create_dawn_gpu_device();
    if (!device) {
        std::fprintf(stderr, "FAIL: create_dawn_gpu_device\n");
        return EXIT_FAILURE;
    }

    // ─── Inputs (same as harness smoke 4) ──────────────────────────────
    RenderArgsStorage uniforms = make_identity_camera_args(kNumSplats, kNumSplats);

    ProjectedSplat splats[kNumSplats] = {
        {128.0f, 128.0f, 0.006061f, 0.0f, 0.006061f,  0.641f, 0.641f, 0.641f, 0.731059f},
        {128.0f, 128.0f, 0.024113f, 0.0f, 0.024113f,  0.641f, 0.641f, 0.641f, 0.731059f},
        {128.0f, 128.0f, 0.053767f, 0.0f, 0.053767f,  0.641f, 0.641f, 0.641f, 0.731059f},
        {128.0f, 128.0f, 0.094401f, 0.0f, 0.094401f,  0.641f, 0.641f, 0.641f, 0.731059f},
    };

    // ─── Buffers ───────────────────────────────────────────────────────
    auto make_storage = [&](std::size_t bytes, const char* label) {
        GPUBufferDesc desc{};
        desc.size_bytes = bytes;
        desc.storage = GPUStorageMode::kPrivate;
        desc.usage_mask = static_cast<std::uint8_t>(GPUBufferUsage::kStorage);
        desc.label = label;
        return device->create_buffer(desc);
    };

    GPUBufferHandle h_uniforms = make_storage(sizeof(uniforms), "uniforms");
    GPUBufferHandle h_splats   = make_storage(sizeof(splats),   "splats");
    if (!h_uniforms.valid() || !h_splats.valid()) {
        std::fprintf(stderr, "FAIL: create_buffer\n");
        return EXIT_FAILURE;
    }
    device->update_buffer(h_uniforms, &uniforms, 0, sizeof(uniforms));
    device->update_buffer(h_splats,   splats,    0, sizeof(splats));

    // ─── Shaders + render pipeline ─────────────────────────────────────
    if (!register_wgsl_from_file(*device, "splat_render_vs",
                                 "aether_cpp/shaders/wgsl/splat_render.wgsl",
                                 "vs_main")) {
        std::fprintf(stderr, "FAIL: register vs\n"); return EXIT_FAILURE;
    }
    if (!register_wgsl_from_file(*device, "splat_render_fs",
                                 "aether_cpp/shaders/wgsl/splat_render.wgsl",
                                 "fs_main")) {
        std::fprintf(stderr, "FAIL: register fs\n"); return EXIT_FAILURE;
    }
    GPUShaderHandle vs = device->load_shader("splat_render_vs", GPUShaderStage::kVertex);
    GPUShaderHandle fs = device->load_shader("splat_render_fs", GPUShaderStage::kFragment);

    GPURenderTargetDesc rt_desc{};
    rt_desc.color_format = GPUTextureFormat::kRGBA8Unorm;
    rt_desc.depth_format = GPUTextureFormat::kInvalid;
    rt_desc.width = kImgW;
    rt_desc.height = kImgH;
    rt_desc.sample_count = 1;
    rt_desc.blending_enabled = true;
    rt_desc.color_attachment_count = 1;

    GPURenderPipelineHandle pipeline = device->create_render_pipeline(vs, fs, rt_desc);
    if (!pipeline.valid()) {
        std::fprintf(stderr, "FAIL: pipeline\n"); return EXIT_FAILURE;
    }

    // ─── Render target ─────────────────────────────────────────────────
    GPUTextureDesc tex_desc{};
    tex_desc.width = kImgW;
    tex_desc.height = kImgH;
    tex_desc.depth = 1;
    tex_desc.mip_levels = 1;
    tex_desc.format = GPUTextureFormat::kRGBA8Unorm;
    tex_desc.usage_mask = static_cast<std::uint8_t>(GPUTextureUsage::kRenderTarget);
    tex_desc.label = "splat_render_target";
    GPUTextureHandle target = device->create_texture(tex_desc);
    if (!target.valid()) {
        std::fprintf(stderr, "FAIL: target\n"); return EXIT_FAILURE;
    }

    // ─── Encode + dispatch ─────────────────────────────────────────────
    GPURenderPassDesc pass_desc{};
    pass_desc.width = kImgW;
    pass_desc.height = kImgH;
    pass_desc.sample_count = 1;
    pass_desc.color_attachment_count = 1;
    pass_desc.color_attachments[0].texture = target;
    pass_desc.color_attachments[0].load = GPULoadAction::kClear;
    pass_desc.color_attachments[0].store = GPUStoreAction::kStore;
    pass_desc.color_attachments[0].clear_color[0] = 0.0f;
    pass_desc.color_attachments[0].clear_color[1] = 0.0f;
    pass_desc.color_attachments[0].clear_color[2] = 0.0f;
    pass_desc.color_attachments[0].clear_color[3] = 0.0f;

    auto cb = device->create_command_buffer();
    auto* re = cb->make_render_encoder(pass_desc);
    if (!re) { std::fprintf(stderr, "FAIL: render encoder\n"); return EXIT_FAILURE; }

    re->set_pipeline(pipeline);
    re->set_vertex_buffer(h_uniforms, 0, 0);
    re->set_vertex_buffer(h_splats,   0, 1);

    re->draw_instanced(GPUPrimitiveType::kTriangle,
                       /*vertex_count=*/6, /*instance_count=*/kNumSplats);
    re->end_encoding();
    cb->commit();
    cb->wait_until_completed();

    // ─── Readback + verify ─────────────────────────────────────────────
    auto pixels = device->readback_texture(target, kImgW, kImgH, kBpp);
    if (pixels.size() != static_cast<std::size_t>(kImgW) * kImgH * kBpp) {
        std::fprintf(stderr, "FAIL: readback size %zu\n", pixels.size());
        return EXIT_FAILURE;
    }

    auto pixel_at = [&](std::uint32_t x, std::uint32_t y) {
        const std::size_t off =
            (static_cast<std::size_t>(y) * kImgW + x) * kBpp;
        struct P { std::uint8_t r, g, b, a; };
        return P{pixels[off+0], pixels[off+1], pixels[off+2], pixels[off+3]};
    };

    auto center = pixel_at(128, 128);
    auto corner = pixel_at(0, 0);

    std::printf("=== aether_dawn_splat_smoke_render_via_device ===\n");
    std::printf("center (128,128): r=%u g=%u b=%u a=%u\n",
                center.r, center.g, center.b, center.a);
    std::printf("corner (0,0):     r=%u g=%u b=%u a=%u\n",
                corner.r, corner.g, corner.b, corner.a);

    if (center.r < 100 || center.g < 100 || center.b < 100 || center.a < 200) {
        std::fprintf(stderr,
            "FAIL: center pixel too dim — Gaussian eval / blend broken\n");
        return EXIT_FAILURE;
    }
    if (corner.r != 0 || corner.g != 0 || corner.b != 0 || corner.a != 0) {
        std::fprintf(stderr,
            "FAIL: corner pixel non-zero — quad bounds or discard broken\n");
        return EXIT_FAILURE;
    }

    // Compare with harness smoke 4 result: center=(162,162,162,254). The
    // production-path pipeline uses the same WGSL through the same Tint
    // path, so result should match within 1 LSB FP rounding.
    if (std::abs(int(center.r) - 162) > 1 ||
        std::abs(int(center.g) - 162) > 1 ||
        std::abs(int(center.b) - 162) > 1 ||
        std::abs(int(center.a) - 254) > 1) {
        std::fprintf(stderr,
            "FAIL: center pixel doesn't match harness smoke 4 "
            "(162,162,162,254) within 1 LSB\n");
        return EXIT_FAILURE;
    }
    std::printf("center pixel matches harness smoke 4 within 1 LSB\n");

    device->destroy_texture(target);
    device->destroy_render_pipeline(pipeline);
    device->destroy_shader(fs);
    device->destroy_shader(vs);
    device->destroy_buffer(h_splats);
    device->destroy_buffer(h_uniforms);
    std::printf("teardown clean\n");

    std::printf("PASS\n");
    return EXIT_SUCCESS;
}
