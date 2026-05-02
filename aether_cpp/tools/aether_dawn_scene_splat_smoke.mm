// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// Phase 6.4f smoke — end-to-end PLY → AetherSceneRenderer → IOSurface.
//
// Verifies the new C ABI surface (load_ply + render_full splat branch):
//   1. Generate a tiny synthetic 3DGS PLY in /tmp (50 splats arranged on
//      a sphere, single colour, identical scale/opacity).
//   2. Create a BGRA8Unorm IOSurface backing texture.
//   3. AetherSceneRenderer create + load_ply + render_full + get_bounds.
//   4. Read IOSurface pixels, assert non-zero opaque region (splats
//      rendered SOMETHING — not just transparent).
//
// What this verifies:
//   - PLY parser → GaussianParams → GPU upload doesn't crash.
//   - The 2 compute pipelines (project_forward, project_visible) compile
//     via Tint and dispatch without GPU validation errors.
//   - splat_render.wgsl renders the projected splats to the IOSurface.
//   - get_bounds returns a non-degenerate AABB.
//   - The IOSurface is left with at least some opaque pixels (rough
//     "splats rendered" check; doesn't validate exact appearance —
//     visual fidelity is a Phase 6.5 cross-validation concern).
//
// What this does NOT verify:
//   - Per-pixel correctness vs reference (gsplat / Brush / MetalSplatter).
//   - Higher-order SH lighting (we use sh_degree=0).
//   - Depth-correct alpha compositing (no sort yet — Phase 6.4f.2).

#if defined(__APPLE__)

#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurface.h>

#include "aether/pocketworld/scene_iosurface_renderer.h"

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

namespace {

constexpr std::uint32_t kWidth = 256;
constexpr std::uint32_t kHeight = 256;
constexpr std::uint32_t kBytesPerPixel = 4;  // BGRA8

void add_int_value(CFMutableDictionaryRef dict, CFStringRef key, std::int32_t value) {
    CFNumberRef number = CFNumberCreate(nullptr, kCFNumberSInt32Type, &value);
    if (!number) return;
    CFDictionaryAddValue(dict, key, number);
    CFRelease(number);
}

IOSurfaceRef create_bgra8_iosurface(std::uint32_t w, std::uint32_t h) {
    CFMutableDictionaryRef dict = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (!dict) return nullptr;
    add_int_value(dict, kIOSurfaceWidth,        static_cast<std::int32_t>(w));
    add_int_value(dict, kIOSurfaceHeight,       static_cast<std::int32_t>(h));
    add_int_value(dict, kIOSurfacePixelFormat,
                  static_cast<std::int32_t>(kCVPixelFormatType_32BGRA));
    add_int_value(dict, kIOSurfaceBytesPerElement,
                  static_cast<std::int32_t>(kBytesPerPixel));
    add_int_value(dict, kIOSurfaceBytesPerRow,
                  static_cast<std::int32_t>(w * kBytesPerPixel));
    IOSurfaceRef surface = IOSurfaceCreate(dict);
    CFRelease(dict);
    return surface;
}

// Write a tiny binary 3DGS PLY at `path`. Layout matches Phase 6.4f's
// expected INRIA convention (x, y, z, f_dc_*, opacity, scale_*, rot_*).
// Splats are arranged on a sphere of radius `r`, all the same colour,
// scale, and opacity.
bool write_synth_ply(const std::string& path,
                     std::uint32_t count,
                     float radius,
                     float color_r, float color_g, float color_b,
                     float scale_linear,
                     float opacity_linear) {
    std::ofstream f(path, std::ios::binary);
    if (!f) return false;

    // Header (binary little-endian).
    f << "ply\n"
      << "format binary_little_endian 1.0\n"
      << "element vertex " << count << "\n"
      << "property float x\n"
      << "property float y\n"
      << "property float z\n"
      << "property float f_dc_0\n"
      << "property float f_dc_1\n"
      << "property float f_dc_2\n"
      << "property float opacity\n"
      << "property float scale_0\n"
      << "property float scale_1\n"
      << "property float scale_2\n"
      << "property float rot_0\n"
      << "property float rot_1\n"
      << "property float rot_2\n"
      << "property float rot_3\n"
      << "end_header\n";

    constexpr float kSH_C0 = 0.28209479177387814f;
    const float dc_r = (color_r - 0.5f) / kSH_C0;
    const float dc_g = (color_g - 0.5f) / kSH_C0;
    const float dc_b = (color_b - 0.5f) / kSH_C0;
    const float log_scale = std::log(scale_linear > 0.0f ? scale_linear : 1e-6f);
    // PLY opacity is pre-sigmoid (raw logit). Caller passes in linear
    // [0,1]; convert.
    float op = opacity_linear;
    if (op < 1e-6f) op = 1e-6f;
    if (op > 1.0f - 1e-6f) op = 1.0f - 1e-6f;
    const float raw_op = std::log(op / (1.0f - op));

    // Distribute splats on a Fibonacci sphere of radius r.
    const float golden = static_cast<float>((1.0 + std::sqrt(5.0)) / 2.0);
    for (std::uint32_t i = 0; i < count; ++i) {
        const float t = static_cast<float>(i) + 0.5f;
        const float phi = std::acos(1.0f - 2.0f * t / static_cast<float>(count));
        const float theta = 2.0f * 3.14159265f * t / golden;
        const float x = radius * std::sin(phi) * std::cos(theta);
        const float y = radius * std::sin(phi) * std::sin(theta);
        const float z = radius * std::cos(phi);

        float row[14] = {
            x, y, z,
            dc_r, dc_g, dc_b,
            raw_op,
            log_scale, log_scale, log_scale,
            // Identity quaternion (PLY ordering w, x, y, z).
            1.0f, 0.0f, 0.0f, 0.0f,
        };
        f.write(reinterpret_cast<const char*>(row), sizeof(row));
    }
    return f.good();
}

// Read raw IOSurface bytes after EndAccess fence. BGRA8 layout.
std::vector<std::uint8_t> read_iosurface_pixels(IOSurfaceRef surface,
                                                  std::uint32_t w, std::uint32_t h) {
    IOSurfaceLock(surface, kIOSurfaceLockReadOnly, nullptr);
    void* base = IOSurfaceGetBaseAddress(surface);
    const std::size_t row_bytes = IOSurfaceGetBytesPerRow(surface);
    std::vector<std::uint8_t> out(w * h * kBytesPerPixel);
    for (std::uint32_t y = 0; y < h; ++y) {
        std::memcpy(out.data() + y * w * kBytesPerPixel,
                    static_cast<const std::uint8_t*>(base) + y * row_bytes,
                    w * kBytesPerPixel);
    }
    IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, nullptr);
    return out;
}

}  // namespace

int main(int argc, char* argv[]) {
    // Allow caller to point at a real PLY file. Default: synth test.
    std::string ply_path = "/tmp/aether_scene_splat_smoke.ply";
    bool use_synth = true;
    if (argc >= 2) {
        ply_path = argv[1];
        use_synth = false;
    }

    if (use_synth) {
        if (!write_synth_ply(ply_path,
                             /*count=*/1024,
                             /*radius=*/1.0f,
                             /*color=*/0.85f, 0.55f, 0.20f,  // amber
                             /*scale=*/0.05f,
                             /*opacity=*/0.85f)) {
            std::fprintf(stderr, "FAIL: write_synth_ply to %s\n", ply_path.c_str());
            return EXIT_FAILURE;
        }
    }
    std::printf("=== aether_dawn_scene_splat_smoke ===\n");
    std::printf("PLY source: %s%s\n", ply_path.c_str(),
                use_synth ? " (synthetic)" : " (caller-supplied)");

    IOSurfaceRef surface = create_bgra8_iosurface(kWidth, kHeight);
    if (!surface) {
        std::fprintf(stderr, "FAIL: IOSurfaceCreate BGRA8\n");
        return EXIT_FAILURE;
    }

    AetherSceneRenderer* r = aether_scene_renderer_create(
        const_cast<void*>(reinterpret_cast<const void*>(surface)),
        kWidth, kHeight);
    if (!r) {
        std::fprintf(stderr, "FAIL: aether_scene_renderer_create\n");
        CFRelease(surface);
        return EXIT_FAILURE;
    }

    if (!aether_scene_renderer_load_ply(r, ply_path.c_str())) {
        std::fprintf(stderr, "FAIL: aether_scene_renderer_load_ply\n");
        aether_scene_renderer_destroy(r);
        CFRelease(surface);
        return EXIT_FAILURE;
    }

    float bmin[3] = {0}, bmax[3] = {0};
    if (!aether_scene_renderer_get_bounds(r, bmin, bmax)) {
        std::fprintf(stderr, "FAIL: aether_scene_renderer_get_bounds\n");
        aether_scene_renderer_destroy(r);
        CFRelease(surface);
        return EXIT_FAILURE;
    }
    std::printf("bounds: min=(%.3f, %.3f, %.3f) max=(%.3f, %.3f, %.3f)\n",
                bmin[0], bmin[1], bmin[2], bmax[0], bmax[1], bmax[2]);
    const float span = std::sqrt(
        (bmax[0]-bmin[0])*(bmax[0]-bmin[0]) +
        (bmax[1]-bmin[1])*(bmax[1]-bmin[1]) +
        (bmax[2]-bmin[2])*(bmax[2]-bmin[2]));
    if (span < 1e-4f) {
        std::fprintf(stderr, "FAIL: bounds AABB is degenerate (span=%g)\n", span);
        aether_scene_renderer_destroy(r);
        CFRelease(surface);
        return EXIT_FAILURE;
    }

    // Camera: pull back so the scene fits in view. Brush convention is
    // "+Z = in front of camera" (view-space z must be > 0.01 to pass
    // project_forward's frustum check). Place the eye at world
    // (center_x, center_y, center_z - distance) — i.e. BEHIND the scene
    // along world -z — so identity-rotation world-to-camera maps the
    // scene center to view (0, 0, +distance).
    //
    // View matrix is column-major. For identity rotation + translation:
    //   view = T(-eye) so world_point gets mapped to (world - eye).
    //   eye = (center_x, center_y, center_z - distance)
    //   →  translation column = -eye = (-center_x, -center_y,
    //                                    distance - center_z)
    const float center_x = 0.5f * (bmin[0] + bmax[0]);
    const float center_y = 0.5f * (bmin[1] + bmax[1]);
    const float center_z = 0.5f * (bmin[2] + bmax[2]);
    const float radius = 0.5f * span;
    const float fov_y_rad = 60.0f * 3.14159265f / 180.0f;
    const float distance = (radius / std::sin(fov_y_rad * 0.5f)) * 1.5f;
    float view[16] = {
        1.0f, 0.0f, 0.0f, 0.0f,
        0.0f, 1.0f, 0.0f, 0.0f,
        0.0f, 0.0f, 1.0f, 0.0f,
        -center_x, -center_y, distance - center_z, 1.0f,
    };
    float model[16] = {
        1.0f, 0.0f, 0.0f, 0.0f,
        0.0f, 1.0f, 0.0f, 0.0f,
        0.0f, 0.0f, 1.0f, 0.0f,
        0.0f, 0.0f, 0.0f, 1.0f,
    };

    // Render twice — first frame primes any lazy state, second is the
    // one we measure. (Catches "first frame is blank because num_visible
    // wasn't reset" type bugs.)
    aether_scene_renderer_render_full(r, view, model);
    aether_scene_renderer_render_full(r, view, model);

    auto pixels = read_iosurface_pixels(surface, kWidth, kHeight);

    // Walk the pixels. We expect SOME pixels to be non-transparent (the
    // splats rendered). Threshold "non-empty" pixel = alpha >= 4 (very
    // permissive — premultiplied splats with alpha < 4/255 may still be
    // visually present but we need a clear pass/fail).
    std::uint32_t opaque_count = 0;
    std::uint32_t max_alpha = 0;
    std::uint64_t sum_rgb = 0;
    for (std::uint32_t y = 0; y < kHeight; ++y) {
        for (std::uint32_t x = 0; x < kWidth; ++x) {
            const std::uint8_t* p = pixels.data() + (y * kWidth + x) * 4;
            const std::uint8_t b = p[0];
            const std::uint8_t g = p[1];
            const std::uint8_t rr = p[2];
            const std::uint8_t a = p[3];
            if (a >= 4) {
                ++opaque_count;
                sum_rgb += static_cast<std::uint64_t>(b) +
                            static_cast<std::uint64_t>(g) +
                            static_cast<std::uint64_t>(rr);
            }
            if (a > max_alpha) max_alpha = a;
        }
    }
    const double opaque_pct = 100.0 * static_cast<double>(opaque_count) /
                                (static_cast<double>(kWidth) * kHeight);
    std::printf("opaque pixels: %u / %u (%.2f%%), max alpha = %u, sum RGB = %llu\n",
                opaque_count, kWidth * kHeight, opaque_pct,
                max_alpha,
                static_cast<unsigned long long>(sum_rgb));

    aether_scene_renderer_destroy(r);
    CFRelease(surface);

    if (opaque_count < 16) {
        std::fprintf(stderr,
            "FAIL: only %u opaque pixels — splats did not render\n",
            opaque_count);
        return EXIT_FAILURE;
    }
    if (max_alpha < 16) {
        std::fprintf(stderr, "FAIL: max alpha %u — alpha output near zero\n",
                     max_alpha);
        return EXIT_FAILURE;
    }
    if (sum_rgb == 0) {
        std::fprintf(stderr, "FAIL: zero RGB output across the image\n");
        return EXIT_FAILURE;
    }

    std::printf("PASS\n");
    return EXIT_SUCCESS;
}

#else

int main() {
    std::fprintf(stderr, "SKIP: aether_dawn_scene_splat_smoke is Apple-only\n");
    return EXIT_SUCCESS;
}

#endif
