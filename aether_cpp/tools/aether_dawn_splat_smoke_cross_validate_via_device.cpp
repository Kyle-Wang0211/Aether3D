// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// Phase 6.2.G-K Step 10 — cross_validate via DawnGPUDevice path.
//
// Runs both Brush rasterize.wgsl (compute) and Aether3D splat_render.wgsl
// (vert+frag) on the SAME 4 splats through the production DawnGPUDevice
// API. Asserts the same invariants as the harness cross_validate smoke:
//   (1) center pixel diff ≤ 1 LSB per channel
//   (2) max per-channel diff over image ≤ 2 LSB
//   (3) ≥ 99% of pixels match within 1 LSB
//
// Validates the GPUDevice virtual API can compose all of Steps 1-9 to
// reproduce the Phase 6.3a end-of-session cross-validation result through
// the production path.

#include "aether_dawn_splat_test_data.h"

#include "aether/render/dawn_gpu_device.h"
#include "aether/render/gpu_command.h"
#include "aether/render/gpu_device.h"

#include <algorithm>
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
constexpr std::uint32_t kTileW = 16;
constexpr std::uint32_t kNumTiles = (kImgW / kTileW) * (kImgH / kTileW);

constexpr int kMaxPerChannelDiff = 2;
constexpr int kCenterMaxDiff = 1;
constexpr double kMinPctMatching1Lsb = 99.0;
}

int main() {
    using namespace aether::render;

    auto device = create_dawn_gpu_device();
    if (!device) { std::fprintf(stderr, "FAIL: device\n"); return EXIT_FAILURE; }

    // ─── Shared inputs ─────────────────────────────────────────────────
    RenderArgsStorage uniforms = make_identity_camera_args(kNumSplats, kNumSplats);

    ProjectedSplat splats[kNumSplats] = {
        {128.0f, 128.0f, 0.006061f, 0.0f, 0.006061f,  0.641f, 0.641f, 0.641f, 0.731059f},
        {128.0f, 128.0f, 0.024113f, 0.0f, 0.024113f,  0.641f, 0.641f, 0.641f, 0.731059f},
        {128.0f, 128.0f, 0.053767f, 0.0f, 0.053767f,  0.641f, 0.641f, 0.641f, 0.731059f},
        {128.0f, 128.0f, 0.094401f, 0.0f, 0.094401f,  0.641f, 0.641f, 0.641f, 0.731059f},
    };

    // For Brush rasterize: every tile gets all 4 intersections.
    std::uint32_t compact_gid_from_isect[kNumSplats] = {0, 1, 2, 3};
    std::vector<std::uint32_t> tile_offsets(kNumTiles * 2);
    for (std::uint32_t t = 0; t < kNumTiles; ++t) {
        tile_offsets[t * 2 + 0] = 0;
        tile_offsets[t * 2 + 1] = kNumSplats;
    }

    auto make_storage = [&](std::size_t bytes, const char* label,
                            std::uint8_t extra_usage = 0) {
        GPUBufferDesc desc{};
        desc.size_bytes = bytes;
        desc.storage = GPUStorageMode::kPrivate;
        desc.usage_mask = static_cast<std::uint8_t>(GPUBufferUsage::kStorage)
                        | extra_usage;
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

    // ─── Path 1: Brush rasterize.wgsl (compute) ────────────────────────
    GPUBufferHandle h_uniforms_r = make_storage(sizeof(uniforms), "uniforms_r");
    GPUBufferHandle h_isect      = make_storage(sizeof(compact_gid_from_isect), "isect");
    GPUBufferHandle h_tile_off   = make_storage(tile_offsets.size() * sizeof(std::uint32_t), "tile_off");
    GPUBufferHandle h_proj_r     = make_storage(sizeof(splats), "proj_r");
    const std::size_t out_bytes = static_cast<std::size_t>(kImgW) * kImgH * sizeof(std::uint32_t);
    GPUBufferHandle h_out_compute = make_storage(out_bytes, "out_compute");

    device->update_buffer(h_uniforms_r, &uniforms, 0, sizeof(uniforms));
    device->update_buffer(h_isect, compact_gid_from_isect, 0, sizeof(compact_gid_from_isect));
    device->update_buffer(h_tile_off, tile_offsets.data(), 0, tile_offsets.size() * sizeof(std::uint32_t));
    device->update_buffer(h_proj_r, splats, 0, sizeof(splats));

    if (!register_wgsl_from_file(*device, "rasterize",
                                 "aether_cpp/shaders/wgsl/rasterize.wgsl")) {
        std::fprintf(stderr, "FAIL: register rasterize\n"); return EXIT_FAILURE;
    }
    GPUShaderHandle rast_shader = device->load_shader("rasterize", GPUShaderStage::kCompute);
    GPUComputePipelineHandle rast_pipe = device->create_compute_pipeline(rast_shader);

    {
        auto cb = device->create_command_buffer();
        auto* ce = cb->make_compute_encoder();
        ce->set_pipeline(rast_pipe);
        ce->set_buffer(h_uniforms_r, 0, 0);
        ce->set_buffer(h_isect,      0, 1);
        ce->set_buffer(h_tile_off,   0, 2);
        ce->set_buffer(h_proj_r,     0, 3);
        ce->set_buffer(h_out_compute,0, 4);
        ce->dispatch(kNumTiles, 1, 1, 256, 1, 1);
        ce->end_encoding();
        cb->commit();
        cb->wait_until_completed();
    }

    GPUBufferHandle h_compute_staging = make_staging(out_bytes, "compute_staging");
    if (!dawn_copy_buffer_to_buffer(*device, h_out_compute, h_compute_staging, out_bytes)) {
        std::fprintf(stderr, "FAIL: copy compute → staging\n"); return EXIT_FAILURE;
    }
    void* compute_mapped = device->map_buffer(h_compute_staging);
    if (!compute_mapped) { std::fprintf(stderr, "FAIL: map compute_staging\n"); return EXIT_FAILURE; }
    std::vector<std::uint32_t> compute_packed(kImgW * kImgH);
    std::memcpy(compute_packed.data(), compute_mapped, out_bytes);
    device->unmap_buffer(h_compute_staging);

    // ─── Path 2: Aether3D splat_render.wgsl (vert+frag) ────────────────
    GPUBufferHandle h_uniforms_v = make_storage(sizeof(uniforms), "uniforms_v");
    GPUBufferHandle h_proj_v     = make_storage(sizeof(splats), "proj_v");
    // @binding(2) `order` — back-to-front sort permutation (Phase 6.4f.2).
    // No depth sort here, so identity. Dawn rejects a 2-entry bind group
    // against this 3-binding layout.
    std::uint32_t order[kNumSplats];
    for (std::uint32_t i = 0; i < kNumSplats; ++i) order[i] = i;
    GPUBufferHandle h_order      = make_storage(sizeof(order), "order_v");
    device->update_buffer(h_uniforms_v, &uniforms, 0, sizeof(uniforms));
    device->update_buffer(h_proj_v, splats, 0, sizeof(splats));
    device->update_buffer(h_order, order, 0, sizeof(order));

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
    rt_desc.width = kImgW; rt_desc.height = kImgH;
    rt_desc.sample_count = 1; rt_desc.blending_enabled = true;
    rt_desc.color_attachment_count = 1;
    GPURenderPipelineHandle render_pipe = device->create_render_pipeline(vs, fs, rt_desc);

    GPUTextureDesc tex_desc{};
    tex_desc.width = kImgW; tex_desc.height = kImgH;
    tex_desc.depth = 1; tex_desc.mip_levels = 1;
    tex_desc.format = GPUTextureFormat::kRGBA8Unorm;
    tex_desc.usage_mask = static_cast<std::uint8_t>(GPUTextureUsage::kRenderTarget);
    GPUTextureHandle target = device->create_texture(tex_desc);

    GPURenderPassDesc pass_desc{};
    pass_desc.width = kImgW; pass_desc.height = kImgH;
    pass_desc.color_attachment_count = 1;
    pass_desc.color_attachments[0].texture = target;
    pass_desc.color_attachments[0].load = GPULoadAction::kClear;
    pass_desc.color_attachments[0].store = GPUStoreAction::kStore;

    {
        auto cb = device->create_command_buffer();
        auto* re = cb->make_render_encoder(pass_desc);
        re->set_pipeline(render_pipe);
        re->set_vertex_buffer(h_uniforms_v, 0, 0);
        re->set_vertex_buffer(h_proj_v,     0, 1);
        re->set_vertex_buffer(h_order,      0, 2);
        // §2.2c vertex expansion — see aether_dawn_splat_smoke_render.cpp.
        re->draw_instanced(GPUPrimitiveType::kTriangle, 6 * kNumSplats, 1);
        re->end_encoding();
        cb->commit();
        cb->wait_until_completed();
    }

    auto pixels_render = device->readback_texture(target, kImgW, kImgH, kBpp);
    if (pixels_render.empty()) {
        std::fprintf(stderr, "FAIL: readback_texture\n"); return EXIT_FAILURE;
    }

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
        probe_re->set_pipeline(render_pipe);
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
            probe_px.data(), probe_px.size(), "aether_dawn_splat_smoke_cross_validate_via_device");
        device->destroy_texture(probe_target);
        device->destroy_buffer(h_po);
        device->destroy_buffer(h_ps);
        device->destroy_buffer(h_pu);
        if (!probe_ok) return EXIT_FAILURE;
    }

    // ─── Compare ───────────────────────────────────────────────────────
    auto unpack = [](std::uint32_t p) {
        struct P { std::uint8_t r, g, b, a; };
        return P{ static_cast<std::uint8_t>(p & 0xFF),
                  static_cast<std::uint8_t>((p >> 8)  & 0xFF),
                  static_cast<std::uint8_t>((p >> 16) & 0xFF),
                  static_cast<std::uint8_t>((p >> 24) & 0xFF) };
    };

    int max_dr = 0, max_dg = 0, max_db = 0, max_da = 0;
    std::uint32_t pixels_diff_gt_1 = 0, pixels_diff_gt_2 = 0;
    for (std::uint32_t y = 0; y < kImgH; ++y) {
        for (std::uint32_t x = 0; x < kImgW; ++x) {
            const std::size_t idx = static_cast<std::size_t>(y) * kImgW + x;
            auto a = unpack(compute_packed[idx]);
            std::uint8_t br = pixels_render[idx*4 + 0];
            std::uint8_t bg = pixels_render[idx*4 + 1];
            std::uint8_t bb = pixels_render[idx*4 + 2];
            std::uint8_t ba = pixels_render[idx*4 + 3];
            int dr = std::abs(int(a.r) - int(br));
            int dg = std::abs(int(a.g) - int(bg));
            int db = std::abs(int(a.b) - int(bb));
            int da = std::abs(int(a.a) - int(ba));
            if (dr > max_dr) max_dr = dr;
            if (dg > max_dg) max_dg = dg;
            if (db > max_db) max_db = db;
            if (da > max_da) max_da = da;
            int pix_max = std::max({dr, dg, db, da});
            if (pix_max > 1) ++pixels_diff_gt_1;
            if (pix_max > 2) ++pixels_diff_gt_2;
        }
    }

    auto ca = unpack(compute_packed[(kImgH/2) * kImgW + kImgW/2]);
    const std::size_t ci = ((kImgH/2) * kImgW + kImgW/2) * 4;
    int center_max = std::max({
        std::abs(int(ca.r) - int(pixels_render[ci+0])),
        std::abs(int(ca.g) - int(pixels_render[ci+1])),
        std::abs(int(ca.b) - int(pixels_render[ci+2])),
        std::abs(int(ca.a) - int(pixels_render[ci+3])),
    });

    std::printf("=== aether_dawn_splat_smoke_cross_validate_via_device ===\n");
    std::printf("center: rasterize=(%u,%u,%u,%u) splat_render=(%u,%u,%u,%u) max diff %d\n",
                ca.r, ca.g, ca.b, ca.a,
                pixels_render[ci+0], pixels_render[ci+1],
                pixels_render[ci+2], pixels_render[ci+3], center_max);
    std::printf("max per-channel diff: R=%d G=%d B=%d A=%d\n",
                max_dr, max_dg, max_db, max_da);
    const std::uint32_t total_pix = kImgW * kImgH;
    const double pct_w1 = 100.0 *
        static_cast<double>(total_pix - pixels_diff_gt_1) / total_pix;
    std::printf("pixels matching within 1 LSB: %.4f%% (cap ≥ %.1f%%)\n",
                pct_w1, kMinPctMatching1Lsb);
    std::printf("pixels with diff > 2: %u / %u\n", pixels_diff_gt_2, total_pix);

    if (center_max > kCenterMaxDiff) {
        std::fprintf(stderr, "FAIL: center diff %d > %d\n",
                     center_max, kCenterMaxDiff);
        return EXIT_FAILURE;
    }
    int max_pc = std::max({max_dr, max_dg, max_db, max_da});
    if (max_pc > kMaxPerChannelDiff) {
        std::fprintf(stderr, "FAIL: max per-channel diff %d > %d\n",
                     max_pc, kMaxPerChannelDiff);
        return EXIT_FAILURE;
    }
    if (pct_w1 < kMinPctMatching1Lsb) {
        std::fprintf(stderr, "FAIL: only %.4f%% within 1 LSB\n", pct_w1);
        return EXIT_FAILURE;
    }

    // Cleanup.
    device->destroy_texture(target);
    device->destroy_render_pipeline(render_pipe);
    device->destroy_shader(fs);
    device->destroy_shader(vs);
    device->destroy_buffer(h_order);
    device->destroy_buffer(h_proj_v);
    device->destroy_buffer(h_uniforms_v);
    device->destroy_buffer(h_compute_staging);
    device->destroy_compute_pipeline(rast_pipe);
    device->destroy_shader(rast_shader);
    device->destroy_buffer(h_out_compute);
    device->destroy_buffer(h_proj_r);
    device->destroy_buffer(h_tile_off);
    device->destroy_buffer(h_isect);
    device->destroy_buffer(h_uniforms_r);

    std::printf("PASS — Brush compute and Aether3D vert+frag agree within "
                "%d LSB through DawnGPUDevice production path\n",
                kMaxPerChannelDiff);
    return EXIT_SUCCESS;
}
