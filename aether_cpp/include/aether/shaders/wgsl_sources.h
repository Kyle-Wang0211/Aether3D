// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_SHADERS_WGSL_SOURCES_H
#define AETHER_SHADERS_WGSL_SOURCES_H

// ─── Phase 6.4a — WGSL extern declarations ─────────────────────────────
//
// Source of truth: aether_cpp/shaders/wgsl/*.wgsl (15 files: 14 Brush
// kernels + 1 Aether3D-original splat_render).
//
// Build-time generated definitions: ${CMAKE_BINARY_DIR}/generated/aether/
// shaders/<name>_wgsl.cpp, produced by aether_cpp/scripts/bake_one_wgsl.cmake
// (one .cpp per .wgsl, regenerated whenever the source .wgsl changes via
// CMake DEPENDS).
//
// Why bake (CMake) and not bundle resources / hand-maintained constexpr:
//   - Single source of truth: .wgsl files only; .cpp is build product
//   - Zero runtime filesystem dependency in production binary
//   - Cross-platform consistency: 5-platform bundle path divergence is
//     eliminated (no Bundle.main.url() / AssetManager / fetch() forks)
//   - Industry standard (Unity / Unreal / Bevy / id Tech do the same)
//
// Adding a new .wgsl file:
//   1. Drop the file in shaders/wgsl/
//   2. Add extern here (manual)
//   3. Add register_wgsl_source() call in register_baked_wgsl_into_device
//      (dawn_gpu_device.cpp)
//   CMake's file(GLOB ...) auto-discovers the file at next reconfigure.
//   Linker error if extern is missing AFTER cmake reconfigure (loud
//   failure path — silent missing baked source is impossible).
//
// All sources are null-terminated C strings (R"(...)" raw string literal
// from the bake script). Pointer is stable for process lifetime; do not
// free.

namespace aether {
namespace shaders {

extern const char splat_render_wgsl[];
extern const char mesh_render_wgsl[];
extern const char project_forward_wgsl[];
extern const char project_visible_wgsl[];
extern const char project_backwards_wgsl[];
extern const char map_gaussian_to_intersects_wgsl[];
extern const char rasterize_wgsl[];
extern const char rasterize_backwards_wgsl[];
extern const char sort_count_wgsl[];
extern const char sort_reduce_wgsl[];
extern const char sort_scan_wgsl[];
extern const char sort_scan_add_wgsl[];
extern const char sort_scatter_wgsl[];
extern const char prefix_sum_scan_wgsl[];
extern const char prefix_sum_scan_sums_wgsl[];
extern const char prefix_sum_add_scanned_sums_wgsl[];

}  // namespace shaders
}  // namespace aether

#endif  // AETHER_SHADERS_WGSL_SOURCES_H
