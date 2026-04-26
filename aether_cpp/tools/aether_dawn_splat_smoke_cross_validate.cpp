// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// Phase 6.3a + 6.5 prelude — cross-validate Brush compute rasterizer vs
// Aether3D vert+frag splat_render on identical inputs.
//
// Runs both pipelines on the SAME 4 ProjectedSplats:
//   1. Brush rasterize.wgsl  (compute → packed u32 RGBA8)
//   2. splat_render.wgsl     (vert+frag → RGBA8Unorm texture)
//
// Compares pixel-by-pixel and asserts:
//   (1) Center pixel differs by ≤ 1 LSB on every channel  — STRICT
//   (2) Total summed |Δch| across image is bounded         — drift catcher
//   (3) Max per-pixel diff doesn't exceed K_MAX            — sanity ceiling
//
// Why this matters for Phase 6:
//   - This is the regression-test prelude for Phase 6.5 cross-val vs
//     MetalSplatter. Same comparison structure (assert pixel diff ≤
//     threshold) applied to a different oracle.
//   - Catches Brush re-pin / naga_oil version drift / Tint optimizer
//     change at the smoke level, not the integration level.
//   - Locks in the agreement: "within Aether3D, the training compute
//     path and the viewer vert+frag path produce equivalent images."
//     If this ever breaks, training and viewer have diverged → bug.
//
// Why pixels can differ at quad edges:
//   splat_render's quad is sized to 3-sigma of the conic; pixels just
//   beyond that get no fragment (cleared to 0). Brush rasterize iterates
//   every pixel in covered tiles regardless, evaluating Gaussian + α
//   threshold. At ~3-4 sigma, α drops below 1/255 in both — but FP
//   rounding can make one path discard while the other writes α=1.
//   The (2) and (3) bounds tolerate this without false-positiving.

#include "aether_dawn_splat_test_data.h"
#include "dawn_kernel_harness.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

namespace {

using aether::tools::splat_test_data::RenderArgsStorage;
using aether::tools::splat_test_data::ProjectedSplat;
using aether::tools::splat_test_data::make_identity_camera_args;

constexpr uint32_t kImgW = 256;
constexpr uint32_t kImgH = 256;
constexpr uint32_t kTileW = 16;
constexpr uint32_t kNumSplats = 4;
constexpr uint32_t kNumTiles = (kImgW / kTileW) * (kImgH / kTileW);  // 256

// Strict assertion thresholds. Three nested invariants:
//   1. center pixel diff ≤ 1   — Gaussian peak must agree within FP rounding
//   2. max per-channel diff ≤ 2 — image-wide ceiling
//   3. ≥ 99% of pixels diff ≤ 1 — proportional drift detector. Robust to
//                                  image content vs absolute Σ|Δch|, which
//                                  scales with covered area.
constexpr int kMaxPerChannelDiff = 2;
constexpr int kCenterMaxDiff     = 1;
constexpr double kMinPctMatchingWithin1Lsb = 99.0;  // %

std::string read_wgsl(const std::string& p) {
    std::ifstream in(p);
    if (!in) return {};
    std::ostringstream ss; ss << in.rdbuf(); return ss.str();
}

struct Pixel { uint8_t r, g, b, a; };

Pixel unpack_u32_rgba(uint32_t p) {
    return { static_cast<uint8_t>(p & 0xFF),
             static_cast<uint8_t>((p >> 8)  & 0xFF),
             static_cast<uint8_t>((p >> 16) & 0xFF),
             static_cast<uint8_t>((p >> 24) & 0xFF) };
}

}  // namespace

int main(int /*argc*/, char* argv[]) {
    using namespace aether::tools;

    std::string rast_path   = "aether_cpp/shaders/wgsl/rasterize.wgsl";
    std::string render_path = "aether_cpp/shaders/wgsl/splat_render.wgsl";
    if (argv && argv[1]) rast_path   = argv[1];
    if (argv && argv[1] && argv[2]) render_path = argv[2];
    std::string rast_wgsl   = read_wgsl(rast_path);
    std::string render_wgsl = read_wgsl(render_path);
    if (rast_wgsl.empty() || render_wgsl.empty()) {
        std::cerr << "Failed to read WGSL\n"; return 1;
    }

    DawnKernelHarness h;
    if (!h.init()) return 1;

    // ─── Shared inputs ─────────────────────────────────────────────────
    RenderArgsStorage u = make_identity_camera_args(kNumSplats, kNumSplats);

    ProjectedSplat splats[kNumSplats] = {
        {128.0f, 128.0f, 0.006061f, 0.0f, 0.006061f,  0.641f, 0.641f, 0.641f, 0.731059f},
        {128.0f, 128.0f, 0.024113f, 0.0f, 0.024113f,  0.641f, 0.641f, 0.641f, 0.731059f},
        {128.0f, 128.0f, 0.053767f, 0.0f, 0.053767f,  0.641f, 0.641f, 0.641f, 0.731059f},
        {128.0f, 128.0f, 0.094401f, 0.0f, 0.094401f,  0.641f, 0.641f, 0.641f, 0.731059f},
    };

    // ─── Path 1: Brush rasterize.wgsl (compute) ───────────────────────
    // For fair comparison, ALL 256 tiles get all 4 intersections so both
    // paths process the same image area. This is more work than the
    // standard rasterize smoke but eliminates the "per-tile coverage"
    // axis from the diff.
    uint32_t compact_gid_from_isect[kNumSplats] = {0, 1, 2, 3};
    std::vector<uint32_t> tile_offsets(kNumTiles * 2);
    for (uint32_t t = 0; t < kNumTiles; ++t) {
        tile_offsets[t * 2 + 0] = 0;
        tile_offsets[t * 2 + 1] = kNumSplats;
    }

    auto buf_uniforms_r = h.upload(&u, sizeof(u), wgpu::BufferUsage::Storage);
    auto buf_isect_r = h.upload(compact_gid_from_isect, sizeof(compact_gid_from_isect),
        wgpu::BufferUsage::Storage);
    auto buf_tile_offsets = h.upload(tile_offsets.data(), tile_offsets.size() * sizeof(uint32_t),
        wgpu::BufferUsage::Storage);
    auto buf_projected_r = h.upload(splats, sizeof(splats), wgpu::BufferUsage::Storage);

    const size_t out_bytes_compute = kImgW * kImgH * sizeof(uint32_t);
    auto buf_out_compute = h.alloc(out_bytes_compute,
        wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);

    auto pipe_rast = h.load_compute(rast_wgsl, "main");
    if (pipe_rast == nullptr) { std::cerr << "rasterize compile failed\n"; return 1; }
    h.dispatch(pipe_rast,
               { buf_uniforms_r, buf_isect_r, buf_tile_offsets, buf_projected_r, buf_out_compute },
               kNumTiles, 1, 1);

    auto staging_compute = h.alloc_staging_for_readback(out_bytes_compute);
    h.copy_to_staging(buf_out_compute, staging_compute, out_bytes_compute);
    auto bytes_compute = h.readback(staging_compute, out_bytes_compute);
    std::vector<uint32_t> compute_packed(kImgW * kImgH);
    std::memcpy(compute_packed.data(), bytes_compute.data(), out_bytes_compute);

    // ─── Path 2: Aether3D splat_render.wgsl (vert+frag) ────────────────
    auto buf_uniforms_v = h.upload(&u, sizeof(u), wgpu::BufferUsage::Storage);
    auto buf_projected_v = h.upload(splats, sizeof(splats), wgpu::BufferUsage::Storage);
    auto target = h.alloc_render_target(kImgW, kImgH, wgpu::TextureFormat::RGBA8Unorm);

    auto pipe_render = h.load_render_pipeline(render_wgsl, "vs_main", "fs_main",
                                               wgpu::TextureFormat::RGBA8Unorm);
    if (pipe_render == nullptr) { std::cerr << "splat_render compile failed\n"; return 1; }
    h.dispatch_render_pass(pipe_render, target,
                           { buf_uniforms_v, buf_projected_v },
                           /*vertex_count=*/6, /*instance_count=*/kNumSplats);

    auto pixels_render = h.readback_texture(target, kImgW, kImgH, /*bpp=*/4);

    // ─── Compare pixel-by-pixel ────────────────────────────────────────
    int max_dr = 0, max_dg = 0, max_db = 0, max_da = 0;
    uint64_t sum_diff = 0;
    uint32_t pixels_diff_gt_1 = 0;
    uint32_t pixels_diff_gt_2 = 0;
    uint32_t worst_x = 0, worst_y = 0;
    int worst_max = 0;

    for (uint32_t y = 0; y < kImgH; ++y) {
        for (uint32_t x = 0; x < kImgW; ++x) {
            const size_t idx = static_cast<size_t>(y) * kImgW + x;
            Pixel a = unpack_u32_rgba(compute_packed[idx]);
            Pixel b = {
                pixels_render[idx * 4 + 0],
                pixels_render[idx * 4 + 1],
                pixels_render[idx * 4 + 2],
                pixels_render[idx * 4 + 3],
            };
            int dr = std::abs(int(a.r) - int(b.r));
            int dg = std::abs(int(a.g) - int(b.g));
            int db = std::abs(int(a.b) - int(b.b));
            int da = std::abs(int(a.a) - int(b.a));
            if (dr > max_dr) max_dr = dr;
            if (dg > max_dg) max_dg = dg;
            if (db > max_db) max_db = db;
            if (da > max_da) max_da = da;
            int pix_max = std::max({dr, dg, db, da});
            if (pix_max > worst_max) {
                worst_max = pix_max;
                worst_x = x; worst_y = y;
            }
            if (pix_max > 1) ++pixels_diff_gt_1;
            if (pix_max > 2) ++pixels_diff_gt_2;
            sum_diff += static_cast<uint64_t>(dr + dg + db + da);
        }
    }

    // ─── Verification ─────────────────────────────────────────────────
    std::cout << "=== aether_dawn_splat_smoke_cross_validate ===\n";
    std::cout << "image " << kImgW << "x" << kImgH << ", " << kNumSplats
              << " splats, all 256 tiles fully populated\n";

    // (1) Center pixel must agree closely.
    Pixel ca = unpack_u32_rgba(compute_packed[kImgH/2 * kImgW + kImgW/2]);
    Pixel cb = {
        pixels_render[(kImgH/2 * kImgW + kImgW/2) * 4 + 0],
        pixels_render[(kImgH/2 * kImgW + kImgW/2) * 4 + 1],
        pixels_render[(kImgH/2 * kImgW + kImgW/2) * 4 + 2],
        pixels_render[(kImgH/2 * kImgW + kImgW/2) * 4 + 3],
    };
    std::cout << "center pixel:\n";
    std::cout << "  rasterize    : (" << int(ca.r) << ", " << int(ca.g) << ", "
              << int(ca.b) << ", " << int(ca.a) << ")\n";
    std::cout << "  splat_render : (" << int(cb.r) << ", " << int(cb.g) << ", "
              << int(cb.b) << ", " << int(cb.a) << ")\n";
    int center_max = std::max({std::abs(int(ca.r)-int(cb.r)),
                               std::abs(int(ca.g)-int(cb.g)),
                               std::abs(int(ca.b)-int(cb.b)),
                               std::abs(int(ca.a)-int(cb.a))});
    std::cout << "  max channel diff: " << center_max << '\n';
    if (center_max > kCenterMaxDiff) {
        std::cerr << "FAIL: center pixel diff " << center_max
                  << " > " << kCenterMaxDiff << " — Gaussian eval drifted\n";
        return 1;
    }

    // (2) Image-wide statistics.
    std::cout << "image-wide max diff per channel: R=" << max_dr
              << " G=" << max_dg << " B=" << max_db << " A=" << max_da << '\n';
    std::cout << "worst pixel: (" << worst_x << "," << worst_y
              << ") max channel diff " << worst_max << '\n';
    std::cout << "pixels with any channel diff > 1: " << pixels_diff_gt_1
              << " / " << (kImgW * kImgH) << '\n';
    std::cout << "pixels with any channel diff > 2: " << pixels_diff_gt_2
              << " / " << (kImgW * kImgH) << '\n';
    const uint32_t total_pix = kImgW * kImgH;
    const double pct_within_1 =
        100.0 * static_cast<double>(total_pix - pixels_diff_gt_1) / total_pix;
    std::cout << "% of pixels matching within 1 LSB: "
              << pct_within_1 << "% (cap ≥ " << kMinPctMatchingWithin1Lsb << "%)\n";
    std::cout << "(informational) Σ|Δch| over image: " << sum_diff << '\n';

    // (3) Strict per-channel ceiling.
    int max_per_channel = std::max({max_dr, max_dg, max_db, max_da});
    if (max_per_channel > kMaxPerChannelDiff) {
        std::cerr << "FAIL: max per-channel diff " << max_per_channel
                  << " > " << kMaxPerChannelDiff << '\n';
        return 1;
    }

    // (4) Proportional drift catcher.
    if (pct_within_1 < kMinPctMatchingWithin1Lsb) {
        std::cerr << "FAIL: only " << pct_within_1
                  << "% of pixels match within 1 LSB (need ≥ "
                  << kMinPctMatchingWithin1Lsb << "%)\n";
        return 1;
    }

    std::cout << "PASS — Brush compute and Aether3D vert+frag agree within "
              << kMaxPerChannelDiff << " LSB across the entire image, "
              << pct_within_1 << "% match within 1 LSB\n";
    return 0;
}
