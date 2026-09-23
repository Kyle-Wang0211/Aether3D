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
using aether::tools::splat_test_data::make_coverage_probe_splats;
using aether::tools::splat_test_data::verify_coverage_probe;
using aether::tools::splat_test_data::kProbeSplats;

namespace {
constexpr std::uint32_t kImgW = 256;
constexpr std::uint32_t kImgH = 256;
constexpr std::uint32_t kBpp = 4;
constexpr std::uint32_t kNumSplats = 4;
static_assert(kNumSplats == kProbeSplats,
              "the coverage probe reuses this tool's `order` array");
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

    // @binding(2) `order` — the back-to-front sort permutation added by
    // Phase 6.4f.2. No depth sort here, so the identity permutation renders
    // the splats in array order. (Without this third binding Dawn rejects
    // the bind group: "Number of entries (2) did not match ... (3)".)
    std::uint32_t order[kNumSplats];
    for (std::uint32_t i = 0; i < kNumSplats; ++i) order[i] = i;

    GPUBufferHandle h_uniforms = make_storage(sizeof(uniforms), "uniforms");
    GPUBufferHandle h_splats   = make_storage(sizeof(splats),   "splats");
    GPUBufferHandle h_order    = make_storage(sizeof(order),    "order");
    if (!h_uniforms.valid() || !h_splats.valid() || !h_order.valid()) {
        std::fprintf(stderr, "FAIL: create_buffer\n");
        return EXIT_FAILURE;
    }
    device->update_buffer(h_uniforms, &uniforms, 0, sizeof(uniforms));
    device->update_buffer(h_splats,   splats,    0, sizeof(splats));
    device->update_buffer(h_order,    order,     0, sizeof(order));

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
    re->set_vertex_buffer(h_order,    0, 2);

    // §2.2c vertex expansion — see aether_dawn_splat_smoke_render.cpp.
    re->draw_instanced(GPUPrimitiveType::kTriangle,
                       /*vertex_count=*/6 * kNumSplats, /*instance_count=*/1);
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

    // ─── §2.2c coverage probe — every point must reach the framebuffer ──
    // The concentric fixture above cannot tell "4 splats drawn once each"
    // from "splat 0 drawn 4 times". Re-run the same pipeline on the
    // non-concentric probe fixture and assert all 4 points by position
    // AND colour. See make_coverage_probe_splats() in
    // aether_dawn_splat_test_data.h for the measured motivation.
    {
        ProjectedSplat probe_splats[kProbeSplats];
        make_coverage_probe_splats(probe_splats);
        RenderArgsStorage probe_u =
            make_identity_camera_args(kProbeSplats, kProbeSplats);

        GPUBufferHandle h_pu = make_storage(sizeof(probe_u),      "probe_uniforms");
        GPUBufferHandle h_ps = make_storage(sizeof(probe_splats), "probe_splats");
        GPUBufferHandle h_po = make_storage(sizeof(order),        "probe_order");
        if (!h_pu.valid() || !h_ps.valid() || !h_po.valid()) {
            std::fprintf(stderr, "FAIL: probe create_buffer\n");
            return EXIT_FAILURE;
        }
        device->update_buffer(h_pu, &probe_u,     0, sizeof(probe_u));
        device->update_buffer(h_ps, probe_splats, 0, sizeof(probe_splats));
        device->update_buffer(h_po, order,        0, sizeof(order));

        GPUTextureDesc probe_tex{};
        probe_tex.width = kImgW; probe_tex.height = kImgH;
        probe_tex.depth = 1; probe_tex.mip_levels = 1;
        probe_tex.format = GPUTextureFormat::kRGBA8Unorm;
        probe_tex.usage_mask =
            static_cast<std::uint8_t>(GPUTextureUsage::kRenderTarget);
        probe_tex.label = "splat_coverage_probe_target";
        GPUTextureHandle probe_target = device->create_texture(probe_tex);
        if (!probe_target.valid()) {
            std::fprintf(stderr, "FAIL: probe target\n"); return EXIT_FAILURE;
        }

        GPURenderPassDesc probe_pass{};
        probe_pass.width = kImgW; probe_pass.height = kImgH;
        probe_pass.sample_count = 1;
        probe_pass.color_attachment_count = 1;
        probe_pass.color_attachments[0].texture = probe_target;
        probe_pass.color_attachments[0].load  = GPULoadAction::kClear;
        probe_pass.color_attachments[0].store = GPUStoreAction::kStore;
        probe_pass.color_attachments[0].clear_color[0] = 0.0f;
        probe_pass.color_attachments[0].clear_color[1] = 0.0f;
        probe_pass.color_attachments[0].clear_color[2] = 0.0f;
        probe_pass.color_attachments[0].clear_color[3] = 0.0f;

        auto probe_cb = device->create_command_buffer();
        auto* probe_re = probe_cb->make_render_encoder(probe_pass);
        if (!probe_re) {
            std::fprintf(stderr, "FAIL: probe render encoder\n");
            return EXIT_FAILURE;
        }
        probe_re->set_pipeline(pipeline);
        probe_re->set_vertex_buffer(h_pu, 0, 0);
        probe_re->set_vertex_buffer(h_ps, 0, 1);
        probe_re->set_vertex_buffer(h_po, 0, 2);
        probe_re->draw_instanced(GPUPrimitiveType::kTriangle,
                                 /*vertex_count=*/6 * kProbeSplats,
                                 /*instance_count=*/1);
        probe_re->end_encoding();
        probe_cb->commit();
        probe_cb->wait_until_completed();

        auto probe_px = device->readback_texture(probe_target, kImgW, kImgH, kBpp);
        const bool probe_ok = verify_coverage_probe(
            probe_px.data(), probe_px.size(), "aether_dawn_splat_smoke_render_via_device");
        device->destroy_texture(probe_target);
        device->destroy_buffer(h_po);
        device->destroy_buffer(h_ps);
        device->destroy_buffer(h_pu);
        if (!probe_ok) return EXIT_FAILURE;
    }

    device->destroy_texture(target);
    device->destroy_render_pipeline(pipeline);
    device->destroy_shader(fs);
    device->destroy_shader(vs);
    device->destroy_buffer(h_order);
    device->destroy_buffer(h_splats);
    device->destroy_buffer(h_uniforms);
    std::printf("teardown clean\n");

    std::printf("PASS\n");
    return EXIT_SUCCESS;
}
