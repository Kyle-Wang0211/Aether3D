// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// Phase 6.3a Step 4 v3 smoke test — splat_render.wgsl on Dawn.
//
// Final viewer kernel — 4 ProjectedSplats (output of project_visible) →
// vertex+fragment + instanced quads → 256×256 RGBA8 framebuffer. Verifies
// the vertex+fragment path that REPLACES Brush's compute rasterizer for
// the viewer flow (Brush rasterize.wgsl is retained for training; see
// PHASE6_PLAN.md v3 §3).
//
// Test data: 4 splats all centered at (128, 128) with z²-scaled conics
// (0.006, 0.024, 0.054, 0.094) and rgba=(0.641, 0.641, 0.641, 0.731).
// This is exactly the project_visible smoke output, so the chain
//   project_forward → project_visible → splat_render
// is exercised end-to-end (with manual hand-off through the C++ struct
// rather than a compute pass; full chain comes in 6.2.G-K).
//
// What this verifies:
//   1. splat_render.wgsl compiles via Tint
//   2. 2-buffer @group(0) bind layout valid for render pipeline
//   3. Vertex shader pulls ProjectedSplat by instance_index
//   4. Fragment shader Gaussian eval doesn't produce NaN
//   5. Premultiplied-alpha blending (One/OneMinusSrcAlpha) composes 4
//      overlapping splats without overflow
//   6. Center pixel is non-black (Gaussian peak), corner pixel is black
//   7. copyTextureToBuffer + 256-byte row alignment + unpadding all work
//
// This is the FIRST end-to-end RGBA8 framebuffer test in the harness;
// it also de-risks the IOSurface bridge (harness uses plain Dawn
// textures; the IOSurface zero-copy path reuses the same pipeline +
// readback contract once DawnGPUDevice (6.2.G) wraps render-pass API).

#include "aether_dawn_splat_test_data.h"
#include "dawn_kernel_harness.h"

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

constexpr uint32_t kNumSplats = 4;
constexpr uint32_t kImgW = 256;
constexpr uint32_t kImgH = 256;
constexpr uint32_t kBpp = 4;  // RGBA8Unorm
constexpr uint32_t kCenterX = 128;
constexpr uint32_t kCenterY = 128;

std::string read_wgsl_file(const std::string& path) {
    std::ifstream in(path);
    if (!in) {
        std::cerr << "Failed to open WGSL: " << path << '\n';
        return {};
    }
    std::ostringstream ss;
    ss << in.rdbuf();
    return ss.str();
}

// Read pixel (x,y) from RGBA8Unorm tight-packed bytes.
struct Pixel { uint8_t r, g, b, a; };
Pixel pixel_at(const std::vector<uint8_t>& px, uint32_t x, uint32_t y) {
    const size_t off = (static_cast<size_t>(y) * kImgW + x) * kBpp;
    return { px[off + 0], px[off + 1], px[off + 2], px[off + 3] };
}

}  // namespace

int main(int /*argc*/, char* argv[]) {
    using namespace aether::tools;

    std::string wgsl_path = "aether_cpp/shaders/wgsl/splat_render.wgsl";
    if (argv && argv[1]) wgsl_path = argv[1];
    std::string wgsl = read_wgsl_file(wgsl_path);
    if (wgsl.empty()) return EXIT_FAILURE;

    DawnKernelHarness h;
    if (!h.init()) {
        std::cerr << "DawnKernelHarness::init failed\n";
        return EXIT_FAILURE;
    }

    // ─── Inputs ────────────────────────────────────────────────────────
    RenderArgsStorage u = make_identity_camera_args(kNumSplats,
                                                     /*num_visible=*/kNumSplats);

    // 4 ProjectedSplat values matching project_visible smoke output:
    // xy=(128, 128) on optical axis, conic z² scale, mid-gray rgba.
    ProjectedSplat splats[kNumSplats] = {
        {128.0f, 128.0f, 0.006061f, 0.0f, 0.006061f,  0.641f, 0.641f, 0.641f, 0.731059f},
        {128.0f, 128.0f, 0.024113f, 0.0f, 0.024113f,  0.641f, 0.641f, 0.641f, 0.731059f},
        {128.0f, 128.0f, 0.053767f, 0.0f, 0.053767f,  0.641f, 0.641f, 0.641f, 0.731059f},
        {128.0f, 128.0f, 0.094401f, 0.0f, 0.094401f,  0.641f, 0.641f, 0.641f, 0.731059f},
    };

    // ─── Upload + alloc ────────────────────────────────────────────────
    auto buf_uniforms = h.upload(&u, sizeof(u),
        wgpu::BufferUsage::Storage);
    auto buf_splats = h.upload(splats, sizeof(splats),
        wgpu::BufferUsage::Storage);

    auto target = h.alloc_render_target(kImgW, kImgH,
                                         wgpu::TextureFormat::RGBA8Unorm);

    // ─── Compile + draw ───────────────────────────────────────────────
    auto pipeline = h.load_render_pipeline(wgsl, "vs_main", "fs_main",
                                            wgpu::TextureFormat::RGBA8Unorm);
    if (pipeline == nullptr) {
        std::cerr << "load_render_pipeline returned null\n";
        return EXIT_FAILURE;
    }

    // 6 vertices per quad × kNumSplats instances.
    h.dispatch_render_pass(pipeline, target,
                            { buf_uniforms, buf_splats },
                            /*vertex_count=*/6,
                            /*instance_count=*/kNumSplats);

    // ─── Readback ─────────────────────────────────────────────────────
    auto pixels = h.readback_texture(target, kImgW, kImgH, kBpp);
    if (pixels.size() != static_cast<size_t>(kImgW) * kImgH * kBpp) {
        std::cerr << "Readback texture size mismatch: got " << pixels.size()
                  << ", expected " << (kImgW * kImgH * kBpp) << '\n';
        return EXIT_FAILURE;
    }

    // ─── Verification ─────────────────────────────────────────────────
    std::cout << "=== aether_dawn_splat_smoke_render ===\n";
    std::cout << "WGSL: " << wgsl_path << '\n';
    std::cout << "WGSL bytes: " << wgsl.size() << '\n';
    std::cout << "framebuffer: " << kImgW << "x" << kImgH << " RGBA8Unorm\n";
    std::cout << "instances: " << kNumSplats << " splats at ("
              << kCenterX << ", " << kCenterY << ")\n";

    // (1) Center pixel must be non-black: at Δ=0 every splat contributes
    //     α = 0.731 × exp(0) = 0.731. 4-way One/OneMinusSrcAlpha compose:
    //       a = 0.731 + 0.731·0.269 + 0.731·0.072 + 0.731·0.019 ≈ 0.995
    //       rgb = 0.469 × similar ≈ 0.638
    //     → roughly (163, 163, 163, 254) in 0-255 space.
    Pixel center = pixel_at(pixels, kCenterX, kCenterY);
    std::cout << "center (" << kCenterX << "," << kCenterY << "): "
              << "r=" << int(center.r) << " g=" << int(center.g)
              << " b=" << int(center.b) << " a=" << int(center.a) << '\n';
    if (center.r < 100 || center.g < 100 || center.b < 100 || center.a < 200) {
        std::cerr << "FAIL: center pixel too dim — Gaussian eval / blend broken\n";
        return EXIT_FAILURE;
    }
    if (center.r > 200 || center.g > 200 || center.b > 200) {
        std::cerr << "FAIL: center pixel oversaturated — likely double-premultiply\n";
        return EXIT_FAILURE;
    }

    // (2) Far corner must be black: Δ ≈ (-128, -128), σ ≫ 0 → α ≈ 0,
    //     fragment discarded → cleared (0,0,0,0).
    Pixel corner = pixel_at(pixels, 0, 0);
    std::cout << "corner (0,0): "
              << "r=" << int(corner.r) << " g=" << int(corner.g)
              << " b=" << int(corner.b) << " a=" << int(corner.a) << '\n';
    if (corner.r != 0 || corner.g != 0 || corner.b != 0 || corner.a != 0) {
        std::cerr << "FAIL: corner pixel non-zero — quad bounds or discard broken\n";
        return EXIT_FAILURE;
    }

    // (3) No NaN/Inf in any pixel. RGBA8Unorm bytes can't BE NaN/Inf,
    //     but we can detect "nothing got rendered" (all zero) which
    //     means the dispatch silently produced no fragments (a NaN
    //     in clip-space coords would discard the whole triangle).
    uint64_t nonzero = 0;
    for (uint8_t b : pixels) {
        if (b != 0) ++nonzero;
    }
    std::cout << "non-zero bytes: " << nonzero << " / " << pixels.size() << '\n';
    if (nonzero == 0) {
        std::cerr << "FAIL: framebuffer entirely zero — vertex shader likely "
                     "produced NaN clip-space coords (whole triangles culled)\n";
        return EXIT_FAILURE;
    }

    // (4) Gaussian falloff: a ring of pixels at radius ~30px from center
    //     (between 3-sigma of splat 4 and splat 1) should have decreasing
    //     intensity vs center. Sample (128+30, 128) — splat 1 dominant,
    //     splats 2-4 already discarded.
    Pixel mid = pixel_at(pixels, kCenterX + 30, kCenterY);
    std::cout << "mid (158,128): "
              << "r=" << int(mid.r) << " g=" << int(mid.g)
              << " b=" << int(mid.b) << " a=" << int(mid.a) << '\n';
    if (mid.a >= center.a) {
        std::cerr << "FAIL: Gaussian falloff inverted — center should be brightest\n";
        return EXIT_FAILURE;
    }

    std::cout << "PASS\n";
    return EXIT_SUCCESS;
}
