// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_CPP_TOOLS_AETHER_DAWN_SPLAT_TEST_DATA_H
#define AETHER_CPP_TOOLS_AETHER_DAWN_SPLAT_TEST_DATA_H

// ─── Phase 6.3a — shared C++ mirrors of Brush WGSL structs ─────────────
//
// Per-kernel smoke binaries (aether_dawn_splat_smoke_*.cpp) all need
// matching C++ structs to upload test inputs. Putting them here keeps
// the byte-layout contract single-sourced — Brush re-pin that changes
// any struct will cause exactly ONE static_assert to fail, not N.
//
// Naming convention: C++ name = WGSL name unless that misleads about
// kind. RenderUniforms is named RenderArgsStorage in C++ because it's
// a STORAGE buffer (contains atomic<u32>, illegal in uniform blocks);
// the WGSL name stays as Brush wrote it.

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>

namespace aether {
namespace tools {
namespace splat_test_data {

// ─── RenderArgsStorage — WGSL `RenderUniforms` (144 bytes) ──────────────
// Layout offsets per WGSL storage rules:
//   0..64    viewmat (mat4x4f)
//   64..72   focal (vec2f)
//   72..80   img_size (vec2u)
//   80..88   tile_bounds (vec2u)
//   88..96   pixel_center (vec2f)
//   96..112  camera_position (vec4f, 16-aligned)
//   112..116 sh_degree (u32)
//   116..120 num_visible (atomic<u32>)
//   120..124 total_splats (u32)
//   124..128 max_intersects (u32)
//   128..144 background (vec4f, 16-aligned)
struct RenderArgsStorage {
    float viewmat[16];
    float focal[2];
    uint32_t img_size[2];
    uint32_t tile_bounds[2];
    float pixel_center[2];
    float camera_position[4];
    uint32_t sh_degree;
    uint32_t num_visible;     // atomic<u32> in WGSL, layout-equivalent to u32
    uint32_t total_splats;
    uint32_t max_intersects;
    float background[4];
};
static_assert(sizeof(RenderArgsStorage) == 144,
              "RenderArgsStorage byte layout must match WGSL RenderUniforms");

// ─── PackedVec3 — WGSL same name (12 bytes, no padding) ─────────────────
struct PackedVec3 {
    float x, y, z;
};
static_assert(sizeof(PackedVec3) == 12, "PackedVec3 must be 12 bytes");

// ─── ProjectedSplat — WGSL same name (36 bytes, 9 floats) ───────────────
// Output of project_visible.wgsl. Stored in 2D screen-space pos (xy) +
// 2D conic (3 floats; covariance inverse) + premultiplied RGBA.
struct ProjectedSplat {
    float xy_x, xy_y;
    float conic_x, conic_y, conic_z;
    float color_r, color_g, color_b, color_a;
};
static_assert(sizeof(ProjectedSplat) == 36,
              "ProjectedSplat must be 9 * sizeof(float) = 36 bytes");

// ─── Common test setup helpers ──────────────────────────────────────────

/// Identity-view 256×256 camera with N splats configured. SH degree 0.
/// Useful as the baseline RenderArgsStorage for any viewer smoke test.
inline RenderArgsStorage make_identity_camera_args(uint32_t total_splats,
                                                    uint32_t num_visible = 0) {
    RenderArgsStorage u{};
    u.viewmat[0] = 1.0f; u.viewmat[5] = 1.0f;
    u.viewmat[10] = 1.0f; u.viewmat[15] = 1.0f;
    u.focal[0] = 256.0f; u.focal[1] = 256.0f;
    u.img_size[0] = 256; u.img_size[1] = 256;
    u.tile_bounds[0] = 16; u.tile_bounds[1] = 16;
    u.pixel_center[0] = 128.0f; u.pixel_center[1] = 128.0f;
    u.camera_position[3] = 0.0f;
    u.sh_degree = 0;
    u.num_visible = num_visible;
    u.total_splats = total_splats;
    u.max_intersects = 1024;
    u.background[3] = 1.0f;
    return u;
}

// ─── §2.2c coverage probe — one distinct splat per image quadrant ───────
//
// WHY THIS EXISTS. The fixture every splat_render smoke test used before
// 2026-09-23 puts all 4 splats at the SAME centre (128, 128) with the
// same colour and the same α. That fixture is structurally blind to
// "only splat 0 was actually drawn": every splat evaluates to
// α = 0.731·exp(0) at Δ = 0, so compositing splat 0 four times gives the
// same centre pixel (±1 LSB) as compositing splats 0..3 once each.
//
// Measured, not argued (2026-09-23, macOS/Metal, Dawn):
//   restoring draw(6, kNumSplats) under the vertex-expanded shader —
//   which renders splat 0 N times and splats 1..3 never —
//     aether_dawn_splat_smoke_render             PASS  ← silent 3/4 loss
//     aether_dawn_splat_smoke_render_via_device  PASS  ← silent 3/4 loss
//     aether_dawn_splat_smoke_cross_validate     FAIL (115 LSB)
//     aether_dawn_splat_smoke_cross_validate_via_device FAIL (115 LSB)
//   The two cross-validators only caught it because they hold a second
//   oracle (Brush's compute rasterizer); the two standalone renders had
//   no way to notice at all.
//
// THE FIX. This probe is a second fixture with the blindness removed by
// construction: 4 splats at 4 DISTINCT positions carrying 4 DISTINCT
// colours, with every position asserted by value.
//   - splat k never drawn      ⇒ quadrant k stays cleared black  ⇒ FAIL
//   - splat k drawn N times    ⇒ quadrant k saturates to 255     ⇒ FAIL
//   - point id / corner id swapped in vs_main ⇒ wrong geometry   ⇒ FAIL
// It is cheap (one extra 256² render pass) and it is a positive test:
// it asserts what must be on screen, not the absence of an error string.
//
// Geometry: conic 0.02 ⇒ σ = 1/√0.02 = 7.07 px ⇒ the 3σ quad is 21.2 px
// half-width. The four centres are 128 px apart, so no two quads touch
// and each peak is attributable to exactly one splat; (128, 128) sits in
// the gap and must stay black.
//
// Values: α = 0.8 and channel = 1.0 or 0.0 are exact in RGBA8Unorm
// (0.8 × 255 = 204.0 exactly, no rounding ambiguity), so the peaks below
// are written as the ideal Δ = 0 value (rgb·α, α) = 204. The fragment is
// actually shaded at the pixel CENTRE, i.e. Δ = (0.5, 0.5), which costs
// exp(-0.005) ≈ 0.995 ⇒ 203 in practice. kProbeTolerance = 3 covers that
// half-pixel offset; it is nowhere near the 204-LSB gap between "drawn"
// and "not drawn", or the 51-LSB gap between "drawn once" and "drawn
// four times", which are the failures this probe exists to catch.

constexpr uint32_t kProbeSplats    = 4;
constexpr uint32_t kProbeImgW      = 256;
constexpr uint32_t kProbeImgH      = 256;
constexpr float    kProbeAlpha     = 0.8f;
constexpr float    kProbeConic     = 0.02f;
constexpr int      kProbeTolerance = 3;   // LSB

/// Expected RGBA8 peak for one probe splat.
struct ProbePoint {
    uint32_t x, y;
    uint8_t  r, g, b, a;
};

/// Fill `out` with the 4 probe splats (quadrant centres, primary colours).
inline void make_coverage_probe_splats(ProjectedSplat out[kProbeSplats]) {
    const float c = kProbeConic;
    const float a = kProbeAlpha;
    out[0] = { 64.0f,  64.0f, c, 0.0f, c, 1.0f, 0.0f, 0.0f, a};  // red
    out[1] = {192.0f,  64.0f, c, 0.0f, c, 0.0f, 1.0f, 0.0f, a};  // green
    out[2] = { 64.0f, 192.0f, c, 0.0f, c, 0.0f, 0.0f, 1.0f, a};  // blue
    out[3] = {192.0f, 192.0f, c, 0.0f, c, 1.0f, 1.0f, 1.0f, a};  // white
}

/// The 4 peaks `make_coverage_probe_splats` must produce, in the same order.
inline const ProbePoint* coverage_probe_points() {
    static const ProbePoint pts[kProbeSplats] = {
        { 64,  64, 204,   0,   0, 204},
        {192,  64,   0, 204,   0, 204},
        { 64, 192,   0,   0, 204, 204},
        {192, 192, 204, 204, 204, 204},
    };
    return pts;
}

/// Verify a 256×256 tight RGBA8 render of the probe fixture. Prints every
/// probe peak (pass or fail) to stdout and the reason to stderr; returns
/// true only if all 4 splats drew their own peak AND the gap between them
/// stayed black. `label` names the calling tool in the output.
inline bool verify_coverage_probe(const uint8_t* pixels, size_t pixel_bytes,
                                  const char* label) {
    const size_t expect = static_cast<size_t>(kProbeImgW) * kProbeImgH * 4u;
    if (pixels == nullptr || pixel_bytes != expect) {
        std::fprintf(stderr,
            "FAIL [%s coverage probe]: readback %zu bytes, expected %zu\n",
            label, pixel_bytes, expect);
        return false;
    }
    auto at = [&](uint32_t x, uint32_t y) {
        return pixels + (static_cast<size_t>(y) * kProbeImgW + x) * 4u;
    };

    bool ok = true;
    std::printf("--- %s coverage probe (4 splats, 4 quadrants) ---\n", label);
    const ProbePoint* pts = coverage_probe_points();
    for (uint32_t k = 0; k < kProbeSplats; ++k) {
        const ProbePoint& p = pts[k];
        const uint8_t* g = at(p.x, p.y);
        const int d[4] = {
            std::abs(int(g[0]) - int(p.r)), std::abs(int(g[1]) - int(p.g)),
            std::abs(int(g[2]) - int(p.b)), std::abs(int(g[3]) - int(p.a)),
        };
        const int worst = std::max({d[0], d[1], d[2], d[3]});
        const bool hit = worst <= kProbeTolerance;
        std::printf("  splat %u @ (%3u,%3u): got (%3u,%3u,%3u,%3u) "
                    "want (%3u,%3u,%3u,%3u) Δ=%d %s\n",
                    k, p.x, p.y, g[0], g[1], g[2], g[3],
                    p.r, p.g, p.b, p.a, worst, hit ? "ok" : "MISS");
        if (!hit) {
            ok = false;
            const bool black = (g[0] | g[1] | g[2] | g[3]) == 0;
            std::fprintf(stderr,
                "FAIL [%s coverage probe]: splat %u %s. Under the vertex-"
                "expanded splat_render.wgsl this is what draw(6, N) instead "
                "of draw(6*N, 1) looks like — only point 0 is rendered.\n",
                label, k,
                black ? "never reached the framebuffer"
                      : "drew the wrong colour/alpha (over- or under-draw)");
        }
    }

    // The four 21 px quads cannot reach the image centre; anything there
    // means a quad was sized or positioned wrong.
    const uint8_t* gap = at(kProbeImgW / 2, kProbeImgH / 2);
    const bool gap_black = (gap[0] | gap[1] | gap[2] | gap[3]) == 0;
    std::printf("  gap   @ (%3u,%3u): got (%3u,%3u,%3u,%3u) want (0,0,0,0) %s\n",
                kProbeImgW / 2, kProbeImgH / 2,
                gap[0], gap[1], gap[2], gap[3], gap_black ? "ok" : "BLEED");
    if (!gap_black) {
        ok = false;
        std::fprintf(stderr,
            "FAIL [%s coverage probe]: inter-quad gap is not black — quad "
            "radius or corner offset is wrong\n", label);
    }
    if (ok) std::printf("  coverage probe PASS — all 4 points rendered\n");
    return ok;
}

}  // namespace splat_test_data
}  // namespace tools
}  // namespace aether

#endif  // AETHER_CPP_TOOLS_AETHER_DAWN_SPLAT_TEST_DATA_H
