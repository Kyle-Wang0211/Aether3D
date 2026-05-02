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
//
// Phase 6.4f.2 added two extra coverage modes:
//   • `--mode=sort` (default) — same Fibonacci-sphere fixture as before,
//     but the renderer now runs the 5-kernel radix sort + back-to-front
//     instance order. Smoke is identical to the original (alpha cutoff,
//     non-empty render).
//   • `--mode=sh1` — synthesizes a sphere with deg-1 SH coefficients
//     designed so the +x hemisphere is RED, +y is GREEN, +z is BLUE.
//     Camera looks along +z; we expect the rendered output to be
//     dominated by blue (the SH evaluator should pull the +z basis when
//     viewdir = -z). This catches the common "SH evaluated with wrong
//     view-direction sign" bug.

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

// Phase 6.4f.2.b/c — write a SH-degree-1 synthetic PLY where each splat's
// degree-1 coefficients are tuned so that:
//   - viewdir along +x → R channel boosted (red dominant)
//   - viewdir along +y → G channel boosted
//   - viewdir along +z → B channel boosted
//
// Standard SH formula (see project_visible.wgsl sh_coeffs_to_color):
//   color = SH_C0 * b0 + 0.4886 * (-y * b1c0 + z * b1c1 - x * b1c2) + …
// Where b1c0/b1c1/b1c2 are the (R,G,B) vectors for the Y_1^{-1}, Y_1^{0},
// Y_1^{+1} basis functions. To make:
//   - viewdir.x > 0 → R↑: set b1c2 = (-K, 0, 0) (the -x*b1c2 term contributes)
//   - viewdir.y > 0 → G↑: set b1c0 = (0, -K, 0) (the -y*b1c0 term)
//   - viewdir.z > 0 → B↑: set b1c1 = (0, 0,  K) (the +z*b1c1 term)
// The DC term is gray (0.5,0.5,0.5) so the deg-1 contribution is the
// dominant color-direction signal. K = 1.0 / 0.4886 ≈ 2.047 makes the
// peak band-1 contribution = ±1 (full saturation).
constexpr float kBand1K = 1.0f / 0.4886025119029199f;
// PLY's f_rest_* layout per channel: f_rest_0..2 = R for basis 0..2,
//                                    f_rest_3..5 = G,
//                                    f_rest_6..8 = B
inline void fill_sh1_directional(float sh1[9]) {
    // R channel: only b1c2 = -K (so viewdir.x positive → +R)
    sh1[0] = 0.0f; sh1[1] = 0.0f; sh1[2] = -kBand1K;
    // G channel: only b1c0 = -K (so viewdir.y positive → +G)
    sh1[3] = -kBand1K; sh1[4] = 0.0f; sh1[5] = 0.0f;
    // B channel: only b1c1 = +K (so viewdir.z positive → +B)
    sh1[6] = 0.0f; sh1[7] = kBand1K; sh1[8] = 0.0f;
}

// Write a tiny binary 3DGS PLY at `path`. Layout matches Phase 6.4f's
// expected INRIA convention (x, y, z, f_dc_*, opacity, scale_*, rot_*).
// Splats are arranged on a sphere of radius `r`, all the same colour,
// scale, and opacity. When `with_sh1` is true, also emits f_rest_0..8
// (degree-1 SH) — same coefficients on every splat per
// fill_sh1_directional.
bool write_synth_ply(const std::string& path,
                     std::uint32_t count,
                     float radius,
                     float color_r, float color_g, float color_b,
                     float scale_linear,
                     float opacity_linear,
                     bool with_sh1 = false) {
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
      << "property float rot_3\n";
    if (with_sh1) {
        for (int i = 0; i < 9; ++i) {
            f << "property float f_rest_" << i << "\n";
        }
    }
    f << "end_header\n";

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
    float sh1[9];
    if (with_sh1) fill_sh1_directional(sh1);
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
        if (with_sh1) {
            f.write(reinterpret_cast<const char*>(sh1), sizeof(sh1));
        }
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
    // Modes:
    //   (no args)               → synthetic Fibonacci sphere, sort path.
    //   <ply_path>              → caller-supplied PLY.
    //   --mode=sort | --mode=sh1 → built-in synth variants.
    //   --mode=sh1 [<out_path>] → emits a deg-1 SH ball; pass an output
    //                             path to keep the temp PLY around.
    std::string ply_path = "/tmp/aether_scene_splat_smoke.ply";
    bool use_synth = true;
    bool synth_with_sh1 = false;
    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "--mode=sort") {
            // default; explicit form for symmetry
            synth_with_sh1 = false;
        } else if (arg == "--mode=sh1") {
            synth_with_sh1 = true;
            ply_path = "/tmp/aether_scene_splat_smoke_sh1.ply";
        } else if (!arg.empty() && arg[0] != '-') {
            ply_path = arg;
            use_synth = false;
        }
    }

    if (use_synth) {
        // SH-1 mode uses neutral DC (gray) so the deg-1 directional
        // signal is visible. Sort mode uses an amber DC.
        const float dc_r = synth_with_sh1 ? 0.50f : 0.85f;
        const float dc_g = synth_with_sh1 ? 0.50f : 0.55f;
        const float dc_b = synth_with_sh1 ? 0.50f : 0.20f;
        if (!write_synth_ply(ply_path,
                             /*count=*/1024,
                             /*radius=*/1.0f,
                             /*color=*/dc_r, dc_g, dc_b,
                             /*scale=*/0.05f,
                             /*opacity=*/0.85f,
                             /*with_sh1=*/synth_with_sh1)) {
            std::fprintf(stderr, "FAIL: write_synth_ply to %s\n", ply_path.c_str());
            return EXIT_FAILURE;
        }
    }
    std::printf("=== aether_dawn_scene_splat_smoke ===\n");
    std::printf("PLY source: %s%s%s\n", ply_path.c_str(),
                use_synth ? " (synthetic)" : " (caller-supplied)",
                synth_with_sh1 ? " [sh1]" : "");

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
    std::uint64_t sum_b = 0, sum_g = 0, sum_r = 0;
    for (std::uint32_t y = 0; y < kHeight; ++y) {
        for (std::uint32_t x = 0; x < kWidth; ++x) {
            const std::uint8_t* p = pixels.data() + (y * kWidth + x) * 4;
            const std::uint8_t b = p[0];
            const std::uint8_t g = p[1];
            const std::uint8_t rr = p[2];
            const std::uint8_t a = p[3];
            if (a >= 4) {
                ++opaque_count;
                sum_b += b;
                sum_g += g;
                sum_r += rr;
            }
            if (a > max_alpha) max_alpha = a;
        }
    }
    const std::uint64_t sum_rgb = sum_b + sum_g + sum_r;
    const double opaque_pct = 100.0 * static_cast<double>(opaque_count) /
                                (static_cast<double>(kWidth) * kHeight);
    std::printf("opaque pixels: %u / %u (%.2f%%), max alpha = %u\n",
                opaque_count, kWidth * kHeight, opaque_pct, max_alpha);
    std::printf("sum RGB = %llu (R=%llu G=%llu B=%llu)\n",
                static_cast<unsigned long long>(sum_rgb),
                static_cast<unsigned long long>(sum_r),
                static_cast<unsigned long long>(sum_g),
                static_cast<unsigned long long>(sum_b));

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

    // SH-1 dominance check: camera is at world (0, 0, -distance) looking
    // along +z. project_visible computes viewdir = normalize(mean -
    // camera_position). The visible side of the sphere has mean.z < 0
    // (closer to camera) so mean - camera ≈ (0,0, mean.z + distance). For
    // points near the +z hemisphere of the sphere, viewdir.z is positive
    // → b1c1 (blue) basis dominates. For points on the front hemisphere
    // facing the camera (−z side of sphere), viewdir is closer to (0,0,
    // distance), making viewdir.z LARGER positive → BLUE strongest. So
    // the rendered image should have B as the dominant channel.
    if (use_synth && synth_with_sh1) {
        if (sum_b <= sum_r || sum_b <= sum_g) {
            std::fprintf(stderr,
                "FAIL: SH-1 expected blue-dominant (R=%llu G=%llu B=%llu)\n",
                static_cast<unsigned long long>(sum_r),
                static_cast<unsigned long long>(sum_g),
                static_cast<unsigned long long>(sum_b));
            return EXIT_FAILURE;
        }
        std::printf("SH-1 dominance check OK: B=%llu > R=%llu, G=%llu\n",
                    static_cast<unsigned long long>(sum_b),
                    static_cast<unsigned long long>(sum_r),
                    static_cast<unsigned long long>(sum_g));
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
