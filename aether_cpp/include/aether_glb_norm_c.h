// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// aether_glb_norm — client-side GLB normalizer.
//
// Goal: any GLB the user imports (Polycam / KIRI / Sketchfab download /
// hand-modeled / our own pipeline output) loads in <1 s on iOS /
// Android / HarmonyOS / Web. Today most third-party photogrammetry
// GLBs ship with 30-60 separate primitives × materials × atlases —
// each material costs Filament/Three.js a separate shader compile,
// and Filament's startup time on iPhone is dominated by these per-
// material compiles (5-9 s observed on a 64-prim scan).
//
// What this library does, given any input GLB:
//   1. Parse via cgltf, decode all baseColor PNGs via stb_image.
//   2. Pack the per-prim charts into a single power-of-2 atlas using
//      stb_rect_pack with chart-mean background + 8 px edge dilation
//      (mirrors aether_cpp/src/glb_norm/atlas_merger.cpp; algorithm
//      ported verbatim from server-side worker_object_slam3r_surface_v1
//      /pipeline/atlas_merger.py, the reference implementation).
//   3. If face count > target_face_count, run meshoptimizer's
//      simplify_quadric_decimation to bring it down.
//   4. Emit a single-prim, single-material GLB with explicit
//      metallicFactor=0 (else strict viewers default to 1.0 → black).
//
// Cross-platform: pure C++17, no platform deps. Vendored single-header
// libs (cgltf, stb_image, stb_image_write, stb_rect_pack) plus
// meshoptimizer (a small C++ library). Builds via the existing aether_cpp
// CMake into the same per-arch static lib that ships to iOS / Android /
// HarmonyOS, and via Emscripten to .wasm for the web client.
//
// Memory: caller owns the input bytes; the library streams its work
// through internal buffers and writes the output bytes into a caller-
// provided `aether_glb_norm_buffer_t`. The caller frees with
// aether_glb_norm_buffer_free(). This avoids heap-allocator mismatches
// across the FFI boundary.

#ifndef AETHER_GLB_NORM_C_H
#define AETHER_GLB_NORM_C_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ─── Result codes ───────────────────────────────────────────────────
// Stable across versions — keep adding new codes at the end, never
// renumber. The Dart FFI layer maps these to Dart enums.
typedef enum aether_glb_norm_result {
    AETHER_GLB_NORM_OK = 0,
    AETHER_GLB_NORM_ERR_INVALID_GLB = 1,
    AETHER_GLB_NORM_ERR_NO_MATERIALS = 2,
    AETHER_GLB_NORM_ERR_NO_TEXTURES = 3,
    AETHER_GLB_NORM_ERR_PNG_DECODE = 4,
    AETHER_GLB_NORM_ERR_PACKING_FAILED = 5,
    AETHER_GLB_NORM_ERR_PNG_ENCODE = 6,
    AETHER_GLB_NORM_ERR_OUT_OF_MEMORY = 7,
    AETHER_GLB_NORM_ERR_CANCELLED = 8,
    AETHER_GLB_NORM_ERR_UNSUPPORTED = 9,
    AETHER_GLB_NORM_ERR_INTERNAL = 10,
} aether_glb_norm_result_t;

// ─── Input config ──────────────────────────────────────────────────
typedef struct aether_glb_norm_options {
    // Target atlas side in pixels. 0 = auto-pick smallest power-of-2
    // that holds the per-prim charts at ~70% utilization, capped at
    // `max_atlas_size`. Tested values: 1024, 2048, 4096, 8192, 16384.
    int target_atlas_size;

    // Hard ceiling on the output atlas. iOS 14+ guarantees 8K texture
    // support; 16K is safe on iPhone 12+ / Android with Vulkan-class
    // GPU but not universal — default 8K avoids per-device surprises.
    int max_atlas_size;

    // Mesh decimation target. 0 = no decimation. Otherwise the output
    // mesh is simplified to at most this many triangles via
    // meshoptimizer's quadric-error metric. Recommended: 500_000
    // (visually lossless at 4K texture per Sketchfab/80.lv guidance).
    uint32_t target_face_count;

    // 1 = include the original 4K-or-larger atlas if user opts in.
    // 0 = always downscale to fit `max_atlas_size`. Default 0.
    int allow_oversize_textures;
} aether_glb_norm_options_t;

// Sane defaults — pick smallest pow2, cap at 8K, decimate to 500K
// faces. Safe for every supported platform.
void aether_glb_norm_options_default(aether_glb_norm_options_t* out);

// ─── Output buffer (caller frees) ───────────────────────────────────
// Filled by aether_glb_norm_run() on AETHER_GLB_NORM_OK. Always pair
// with aether_glb_norm_buffer_free() to avoid heap-mismatch leaks
// across the FFI boundary.
typedef struct aether_glb_norm_buffer {
    uint8_t* data;
    size_t size;
} aether_glb_norm_buffer_t;

void aether_glb_norm_buffer_free(aether_glb_norm_buffer_t* buf);

// ─── Optional progress callback ─────────────────────────────────────
// `fraction` is monotonically non-decreasing, 0..1. `phase_label` is
// a short ASCII description of the current step ("parsing",
// "packing atlas", "decimating mesh", "encoding glb"). Returning a
// non-zero value cancels the operation; the run then returns
// AETHER_GLB_NORM_ERR_CANCELLED and the output buffer is empty.
//
// Called from the worker thread that runs aether_glb_norm_run() —
// the Dart FFI layer is responsible for marshalling onto the UI
// thread (typically via a SendPort / Isolate).
typedef int (*aether_glb_norm_progress_fn)(float fraction,
                                           const char* phase_label,
                                           void* user_data);

// ─── Stats (filled on success, optional) ────────────────────────────
typedef struct aether_glb_norm_stats {
    uint32_t input_primitive_count;
    uint32_t input_material_count;
    uint32_t input_face_count;
    uint32_t output_primitive_count;     // always 1 on success
    uint32_t output_material_count;      // always 1 on success
    uint32_t output_face_count;
    int      output_atlas_size;
    float    elapsed_seconds;
} aether_glb_norm_stats_t;

// ─── Main entry point ───────────────────────────────────────────────
// Synchronous; runs on the calling thread. Caller is expected to invoke
// from a worker isolate / std::thread / GCD background queue, not the
// UI thread. The default options yield a sensible result for any GLB.
//
// On success: `out_buffer.data` contains a freshly allocated buffer
// holding the normalized GLB bytes; `out_stats` (if non-null) reports
// what changed.
//
// On error: `out_buffer.data == NULL && out_buffer.size == 0`.
// `out_stats` is filled with whatever was learned before the failure
// so callers can surface useful diagnostics.
aether_glb_norm_result_t aether_glb_norm_run(
    const uint8_t* input_glb_bytes,
    size_t input_glb_size,
    const aether_glb_norm_options_t* options,
    aether_glb_norm_progress_fn progress_cb,    // may be NULL
    void* progress_user_data,                   // may be NULL
    aether_glb_norm_buffer_t* out_buffer,
    aether_glb_norm_stats_t* out_stats);        // may be NULL

// Convenience for code that just wants a string for the result code.
// The returned C string lives in static storage; do not free it.
const char* aether_glb_norm_result_str(aether_glb_norm_result_t code);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // AETHER_GLB_NORM_C_H
