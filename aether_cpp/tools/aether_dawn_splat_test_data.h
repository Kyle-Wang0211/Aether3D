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

#include <cstdint>

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

}  // namespace splat_test_data
}  // namespace tools
}  // namespace aether

#endif  // AETHER_CPP_TOOLS_AETHER_DAWN_SPLAT_TEST_DATA_H
