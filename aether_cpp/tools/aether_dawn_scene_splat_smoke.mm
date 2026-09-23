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

// Zero the IOSurface so a session that renders NOTHING cannot inherit
// the previous session's pixels and pass by accident. render_full's
// colour attachment uses LoadOp::Clear today, but the phase-2 judge
// below is the only thing standing between us and a silent
// use-after-free regression — it must not depend on that staying true.
void zero_iosurface(IOSurfaceRef surface, std::uint32_t w, std::uint32_t h) {
    IOSurfaceLock(surface, 0, nullptr);
    auto* base = static_cast<std::uint8_t*>(IOSurfaceGetBaseAddress(surface));
    const std::size_t row_bytes = IOSurfaceGetBytesPerRow(surface);
    for (std::uint32_t y = 0; y < h; ++y) {
        std::memset(base + y * row_bytes, 0, w * kBytesPerPixel);
    }
    IOSurfaceUnlock(surface, 0, nullptr);
}

// ─── Per-frame measurements, shared by both renderer sessions ──────────
struct FrameStats {
    std::uint32_t opaque_count{0};
    std::uint32_t max_alpha{0};
    std::uint64_t sum_r{0}, sum_g{0}, sum_b{0};
    double        coverage_pct{0.0};
    double        centroid_x{0.0}, centroid_y{0.0};
    std::uint32_t bbox_w{0}, bbox_h{0};
};

// Threshold "non-empty" pixel = alpha >= 4 (very permissive —
// premultiplied splats with alpha < 4/255 may still be visually present
// but we need a clear pass/fail).
FrameStats analyze_pixels(const std::vector<std::uint8_t>& pixels) {
    FrameStats s;
    std::uint64_t sum_x = 0, sum_y = 0;
    std::uint32_t min_x = kWidth, max_x = 0, min_y = kHeight, max_y = 0;
    for (std::uint32_t y = 0; y < kHeight; ++y) {
        for (std::uint32_t x = 0; x < kWidth; ++x) {
            const std::uint8_t* p = pixels.data() + (y * kWidth + x) * 4;
            const std::uint8_t b = p[0], g = p[1], rr = p[2], a = p[3];
            if (a >= 4) {
                ++s.opaque_count;
                s.sum_b += b; s.sum_g += g; s.sum_r += rr;
                sum_x += x;   sum_y += y;
                if (x < min_x) min_x = x;
                if (x > max_x) max_x = x;
                if (y < min_y) min_y = y;
                if (y > max_y) max_y = y;
            }
            if (a > s.max_alpha) s.max_alpha = a;
        }
    }
    s.coverage_pct = 100.0 * static_cast<double>(s.opaque_count) /
                     (static_cast<double>(kWidth) * kHeight);
    if (s.opaque_count > 0) {
        s.centroid_x = static_cast<double>(sum_x) / s.opaque_count;
        s.centroid_y = static_cast<double>(sum_y) / s.opaque_count;
        s.bbox_w = max_x - min_x + 1;
        s.bbox_h = max_y - min_y + 1;
    }
    return s;
}

void print_stats(const char* phase, const FrameStats& s) {
    std::printf("[%s] opaque pixels: %u / %u (%.2f%%), max alpha = %u\n",
                phase, s.opaque_count, kWidth * kHeight, s.coverage_pct,
                s.max_alpha);
    std::printf("[%s] sum RGB = %llu (R=%llu G=%llu B=%llu)\n", phase,
                static_cast<unsigned long long>(s.sum_r + s.sum_g + s.sum_b),
                static_cast<unsigned long long>(s.sum_r),
                static_cast<unsigned long long>(s.sum_g),
                static_cast<unsigned long long>(s.sum_b));
    std::printf("[%s] silhouette: centroid=(%.1f, %.1f) bbox=%ux%u "
                "coverage=%.2f%%\n", phase, s.centroid_x, s.centroid_y,
                s.bbox_w, s.bbox_h, s.coverage_pct);
}

// ─── Judges ────────────────────────────────────────────────────────────
//
// `synthetic` gates the geometry-shape judges: they encode the built-in
// Fibonacci-sphere fixture (centred, viewed down its own axis). A
// caller-supplied PLY has arbitrary geometry, so for that path we can
// only assert "something rendered".
bool judge(const char* phase, const FrameStats& s, bool synthetic, bool sh1) {
    bool ok = true;
    if (s.opaque_count < 16) {
        std::fprintf(stderr,
            "FAIL[%s]: only %u opaque pixels — splats did not render\n",
            phase, s.opaque_count);
        return false;  // every judge below divides by opaque_count
    }
    if (s.max_alpha < 16) {
        std::fprintf(stderr, "FAIL[%s]: max alpha %u — alpha output near zero\n",
                     phase, s.max_alpha);
        ok = false;
    }
    if (s.sum_r + s.sum_g + s.sum_b == 0) {
        std::fprintf(stderr, "FAIL[%s]: zero RGB output across the image\n", phase);
        ok = false;
    }
    if (!synthetic) return ok;

    // ─── Silhouette judge (Phase 6.4f.8) ───────────────────────────────
    //
    // WHY: "opaque_count >= 16" only knows whether ANYTHING rendered. The
    // failure this smoke actually has to catch is a view-convention
    // mismatch, and that family has a partial form: ad28ce94's own commit
    // message describes the pre-hotfix bug as "we accidentally render
    // only the outlier tail behind the camera". A handful of tail splats
    // in a corner clears `>= 16` easily. So assert the SHAPE too.
    //
    // The fixture is 1024 splats on a Fibonacci sphere, centred, viewed
    // down its own axis at 60° FOV with a 1.5× pull-back — it must
    // project to a disc that is centred and roughly as wide as it is
    // tall. Measured 2026-09-23 (macOS/Metal, Dawn): coverage 15.23%,
    // centroid (127.6, 127.7), bbox 112 × 112. The bands below are wide
    // enough to survive rasteriser and LOD-knob drift and still two
    // orders of magnitude away from "a blob in the corner".
    constexpr double kCentroidTolPx  = 16.0;
    constexpr double kCoverageMinPct = 4.0;
    constexpr double kCoverageMaxPct = 60.0;
    constexpr double kAspectTol      = 0.25;   // |w-h| / max(w,h)
    const double img_cx = 0.5 * (kWidth  - 1);
    const double img_cy = 0.5 * (kHeight - 1);

    if (std::fabs(s.centroid_x - img_cx) > kCentroidTolPx ||
        std::fabs(s.centroid_y - img_cy) > kCentroidTolPx) {
        std::fprintf(stderr,
            "FAIL[%s]: rendered centroid (%.1f, %.1f) is more than %.0f px "
            "from the image centre (%.1f, %.1f) — the scene is centred, "
            "so this means the camera/view convention is wrong or only "
            "part of the cloud survived the frustum cull\n",
            phase, s.centroid_x, s.centroid_y, kCentroidTolPx, img_cx, img_cy);
        ok = false;
    }
    if (s.coverage_pct < kCoverageMinPct || s.coverage_pct > kCoverageMaxPct) {
        std::fprintf(stderr,
            "FAIL[%s]: coverage %.2f%% outside [%.1f%%, %.1f%%] — a centred "
            "sphere at this FOV should fill roughly 15%% of the frame\n",
            phase, s.coverage_pct, kCoverageMinPct, kCoverageMaxPct);
        ok = false;
    }
    const double bw = static_cast<double>(s.bbox_w);
    const double bh = static_cast<double>(s.bbox_h);
    const double aspect_err = std::fabs(bw - bh) / (bw > bh ? bw : bh);
    if (aspect_err > kAspectTol) {
        std::fprintf(stderr,
            "FAIL[%s]: opaque bbox %ux%u is not roughly square "
            "(|w-h|/max = %.3f > %.3f) — a sphere must project to a disc\n",
            phase, s.bbox_w, s.bbox_h, aspect_err, kAspectTol);
        ok = false;
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
    if (sh1) {
        if (s.sum_b <= s.sum_r || s.sum_b <= s.sum_g) {
            std::fprintf(stderr,
                "FAIL[%s]: SH-1 expected blue-dominant (R=%llu G=%llu B=%llu)\n",
                phase,
                static_cast<unsigned long long>(s.sum_r),
                static_cast<unsigned long long>(s.sum_g),
                static_cast<unsigned long long>(s.sum_b));
            ok = false;
        } else {
            std::printf("[%s] SH-1 dominance check OK: B=%llu > R=%llu, G=%llu\n",
                        phase,
                        static_cast<unsigned long long>(s.sum_b),
                        static_cast<unsigned long long>(s.sum_r),
                        static_cast<unsigned long long>(s.sum_g));
        }
    }
    if (ok) std::printf("[%s] silhouette judge OK — centred disc\n", phase);
    return ok;
}

// ─── One full renderer lifecycle ───────────────────────────────────────
//
// create → load_ply → get_bounds → render_full ×2 → read pixels →
// destroy. Factored out of main() so the smoke can run it TWICE against
// the same process; see the phase-2 rationale in main().
struct SessionResult {
    bool       ok{false};
    FrameStats stats;
    float      bmin[3]{0.0f, 0.0f, 0.0f};
    float      bmax[3]{0.0f, 0.0f, 0.0f};
};

SessionResult run_session(IOSurfaceRef surface, const std::string& ply_path,
                          const char* phase) {
    SessionResult res;

    AetherSceneRenderer* r = aether_scene_renderer_create(
        const_cast<void*>(reinterpret_cast<const void*>(surface)),
        kWidth, kHeight);
    if (!r) {
        std::fprintf(stderr, "FAIL[%s]: aether_scene_renderer_create\n", phase);
        return res;
    }

    if (!aether_scene_renderer_load_ply(r, ply_path.c_str())) {
        std::fprintf(stderr, "FAIL[%s]: aether_scene_renderer_load_ply\n", phase);
        aether_scene_renderer_destroy(r);
        return res;
    }

    if (!aether_scene_renderer_get_bounds(r, res.bmin, res.bmax)) {
        std::fprintf(stderr, "FAIL[%s]: aether_scene_renderer_get_bounds\n", phase);
        aether_scene_renderer_destroy(r);
        return res;
    }
    std::printf("[%s] bounds: min=(%.3f, %.3f, %.3f) max=(%.3f, %.3f, %.3f)\n",
                phase, res.bmin[0], res.bmin[1], res.bmin[2],
                res.bmax[0], res.bmax[1], res.bmax[2]);
    const float span = std::sqrt(
        (res.bmax[0]-res.bmin[0])*(res.bmax[0]-res.bmin[0]) +
        (res.bmax[1]-res.bmin[1])*(res.bmax[1]-res.bmin[1]) +
        (res.bmax[2]-res.bmin[2])*(res.bmax[2]-res.bmin[2]));
    if (span < 1e-4f) {
        std::fprintf(stderr, "FAIL[%s]: bounds AABB is degenerate (span=%g)\n",
                     phase, span);
        aether_scene_renderer_destroy(r);
        return res;
    }

    // ─── Camera ────────────────────────────────────────────────────────
    //
    // CONTRACT: aether_scene_renderer_render_full takes an OPENGL-
    // convention view matrix — the same thing the Dart caller produces
    // with vector_math.makeViewMatrix, i.e. the camera looks down view
    // -Z and in-front geometry has NEGATIVE view-space z. The renderer
    // converts it to the Brush splat convention itself by left-
    // multiplying with diag(1, -1, -1, 1) (see the "Phase 6.4f hotfix"
    // block in scene_iosurface_renderer.cpp's render_full).
    //
    // Eye sits at world -Z of the scene centre and looks toward +Z,
    // which keeps the SH-1 mode's view-direction expectation exactly as
    // it was originally derived.
    //
    //   f = normalize(center - eye) = (0, 0, 1)
    //   s = normalize(cross(f, up)) = (-1, 0, 0)   [up = +Y]
    //   u = cross(s, f)             = (0, 1, 0)
    //   view (column-major) = [ s.x u.x -f.x 0 | s.y u.y -f.y 0 |
    //                           s.z u.z -f.z 0 | -s·eye -u·eye f·eye 1 ]
    // which is a 180° rotation about Y plus the translation — NOT the
    // identity rotation a Brush-convention fixture would use.
    const float center_x = 0.5f * (res.bmin[0] + res.bmax[0]);
    const float center_y = 0.5f * (res.bmin[1] + res.bmax[1]);
    const float center_z = 0.5f * (res.bmin[2] + res.bmax[2]);
    const float radius = 0.5f * span;
    const float fov_y_rad = 60.0f * 3.14159265f / 180.0f;
    const float distance = (radius / std::sin(fov_y_rad * 0.5f)) * 1.5f;
    // eye = (center_x, center_y, center_z - distance)
    float view[16] = {
        -1.0f, 0.0f,  0.0f, 0.0f,
         0.0f, 1.0f,  0.0f, 0.0f,
         0.0f, 0.0f, -1.0f, 0.0f,
         center_x, -center_y, center_z - distance, 1.0f,
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

    res.stats = analyze_pixels(read_iosurface_pixels(surface, kWidth, kHeight));
    res.ok = true;

    // Destroying the LAST live renderer drops the dawn_singleton
    // refcount to zero, which tears the GPUDevice down. Phase 2 in
    // main() then builds a new one on purpose.
    aether_scene_renderer_destroy(r);
    return res;
}

void print_usage(std::FILE* out) {
    std::fprintf(out,
        "usage: aether_dawn_scene_splat_smoke [--mode=sort|--mode=sh1] [<ply_path>]\n"
        "\n"
        "End-to-end gate for the SHIPPING splat path: PLY ->\n"
        "AetherSceneRenderer (scene_iosurface_renderer.cpp) -> IOSurface.\n"
        "This is the only smoke that compiles and exercises the production\n"
        "render_full() splat branch and its draw call.\n"
        "\n"
        "  --mode=sort   (default) amber Fibonacci sphere; exercises the\n"
        "                5-kernel radix sort and back-to-front draw order.\n"
        "  --mode=sh1    gray sphere with degree-1 SH tuned so the\n"
        "                camera-facing hemisphere must come out\n"
        "                blue-dominant. Catches a flipped SH view-direction.\n"
        "  <ply_path>    render a caller-supplied binary 3DGS PLY instead of\n"
        "                the synthetic fixture. The shape judges (centred\n"
        "                disc, coverage, SH dominance) assume the built-in\n"
        "                geometry, so they are SKIPPED for this path — only\n"
        "                the 'something rendered' judges apply.\n"
        "  -h, --help    print this and exit 0.\n"
        "\n"
        "exit status: 0 = PASS, 1 = a judge failed, 2 = bad usage.\n");
}

}  // namespace

int main(int argc, char* argv[]) {
    // Argument handling is strict on purpose. The previous loop silently
    // ignored anything starting with '-' and treated every other token as
    // a PLY path, so `--help` quietly ran the default mode and a typo'd
    // flag was indistinguishable from a pass.
    std::string ply_path = "/tmp/aether_scene_splat_smoke.ply";
    bool use_synth = true;
    bool synth_with_sh1 = false;
    bool have_positional = false;
    for (int i = 1; i < argc; ++i) {
        const std::string arg = argv[i];
        if (arg == "-h" || arg == "--help") {
            print_usage(stdout);
            return EXIT_SUCCESS;
        } else if (arg == "--mode=sort") {
            synth_with_sh1 = false;                 // default; explicit form
        } else if (arg == "--mode=sh1") {
            synth_with_sh1 = true;
            ply_path = "/tmp/aether_scene_splat_smoke_sh1.ply";
        } else if (!arg.empty() && arg[0] == '-') {
            std::fprintf(stderr, "error: unknown option '%s'\n\n", arg.c_str());
            print_usage(stderr);
            return 2;
        } else if (have_positional) {
            std::fprintf(stderr,
                "error: more than one PLY path given ('%s' after '%s')\n\n",
                arg.c_str(), ply_path.c_str());
            print_usage(stderr);
            return 2;
        } else {
            ply_path = arg;
            use_synth = false;
            have_positional = true;
        }
    }
    if (have_positional && synth_with_sh1) {
        std::fprintf(stderr,
            "error: --mode=sh1 synthesizes its own fixture; it cannot be "
            "combined with a PLY path\n\n");
        print_usage(stderr);
        return 2;
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

    // ─── Phase 1: first renderer ───────────────────────────────────────
    const SessionResult first = run_session(surface, ply_path, "phase1");
    if (!first.ok) { CFRelease(surface); return EXIT_FAILURE; }
    print_stats("phase1", first.stats);
    bool ok = judge("phase1", first.stats, use_synth, synth_with_sh1);

    // ─── Phase 2: device teardown → rebuild → SplatDataCache hit ───────
    //
    // WHY THIS PHASE EXISTS. `SplatData` (scene_iosurface_renderer.cpp)
    // owns GPU buffer handles plus a RAW `GPUDevice*`, and
    // `SplatDataCache` pins up to 3 of them strongly in a
    // process-lifetime static. The device, meanwhile, is refcounted by
    // LIVE RENDERER COUNT: run_session's destroy above dropped it to
    // zero, so the GPUDevice was torn down while the cache kept holding
    // SplatData that points at it.
    //
    // That dangling pointer had two reachable ends:
    //   (a) process exit — ~SplatDataCache → ~SplatData → the VIRTUAL
    //       call device->destroy_buffer(). Measured 2026-09-23: SIGSEGV
    //       in __shared_ptr_emplace<SplatData>::__on_zero_shared(), 10
    //       runs out of 11. Note the fault is the vtable load on the
    //       freed GPUDevice (`ldr x8,[x8,#0x30]; blr x8`) — it dies
    //       before entering destroy_buffer, so this is a plain
    //       use-after-free, NOT a double free: destroy_buffer's own
    //       `buffers_.find(id) == end() → return` and ~DawnGPUDevice's
    //       buffers_.clear() (dawn_gpu_device.cpp:548-558) mean a stale
    //       id could never have reached a second wgpuBufferRelease.
    //       Because the static destructors run BEFORE stdio's atexit
    //       flush, the crash also ate every line of buffered stdout —
    //       the verdict this tool prints was invisible whenever stdout
    //       was a pipe or a file, i.e. always in CI.
    //   (b) right here — create a second renderer (fresh device) and
    //       load the same asset. The cache key is unchanged, so the hit
    //       hands back buffer handles that belong to the DESTROYED
    //       device, and the render binds them on the new one. The new
    //       device has meanwhile reissued those ids to unrelated
    //       buffers, so this surfaces as a Dawn validation error
    //       (measured: [Buffer "splat.global_from_compact_gid"] usage …
    //       includes writable usage and another usage in the same
    //       synchronization scope) — i.e. silently rendering the wrong
    //       buffer on any build without the device error gate.
    //
    // SCOPE — what (b) does and does not prove. It proves the mechanism
    // fires WITHOUT waiting for process exit: any code path that reaches
    // build_splat_scene_from_gaussians, then drops to zero live
    // renderers, then re-enters it with the same key, gets another
    // device's buffers. It does NOT prove the shipping app takes that
    // path — the feed publishes GLB meshes, and whether any shipped work
    // is classified plyGsplat rather than plyMesh was still open when
    // this landed (see docs/SPLAT_DATA_CACHE_DEVICE_UAF_CN.md). Do not
    // cite this phase as "the feed crashes". The reason it is gated
    // anyway is (a): the exit crash blocks the ONLY smoke covering the
    // production splat draw call from ever being trustworthy in CI.
    //
    // Log-reading note: phase 2 prints "build_splat_scene: cache MISS"
    // and that is the FIXED behaviour, not a weakened test — the
    // teardown hook evicts the GPU cache with the device, so the rebuild
    // re-uploads. It should still print "[DECODED CACHE HIT]": the
    // CPU-side decode cache holds no device resources and correctly
    // survives, which is what keeps the re-upload cheap. A phase-2
    // "cache HIT" here means the eviction hook stopped running.
    std::printf("--- phase2: device was torn down; rebuilding + cache hit ---\n");
    zero_iosurface(surface, kWidth, kHeight);
    const SessionResult second = run_session(surface, ply_path, "phase2");
    if (!second.ok) { CFRelease(surface); return EXIT_FAILURE; }
    print_stats("phase2", second.stats);
    ok = judge("phase2", second.stats, use_synth, synth_with_sh1) && ok;

    // The two phases render the identical fixture from the identical
    // camera, so they must agree. Tolerance covers rasteriser
    // nondeterminism in the radix sort's tie-breaking only.
    if (first.stats.opaque_count > 0) {
        const double drift =
            std::fabs(static_cast<double>(second.stats.opaque_count) -
                      static_cast<double>(first.stats.opaque_count)) /
            static_cast<double>(first.stats.opaque_count);
        std::printf("phase1 vs phase2 opaque drift: %.4f%%\n", 100.0 * drift);
        if (drift > 0.02) {
            std::fprintf(stderr,
                "FAIL: phase2 rendered %u opaque pixels vs phase1's %u "
                "(%.2f%% drift) — same fixture, same camera, so this means "
                "the rebuilt device did not get equivalent splat buffers\n",
                second.stats.opaque_count, first.stats.opaque_count,
                100.0 * drift);
            ok = false;
        }
    }

    CFRelease(surface);

    if (!ok) return EXIT_FAILURE;
    std::printf("PASS\n");
    return EXIT_SUCCESS;
}

#else

int main() {
    std::fprintf(stderr, "SKIP: aether_dawn_scene_splat_smoke is Apple-only\n");
    return EXIT_SUCCESS;
}

#endif
