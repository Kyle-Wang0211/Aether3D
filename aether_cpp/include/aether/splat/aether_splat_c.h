// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// C API for 3D Gaussian Splatting render engine.
// Swift/Kotlin/ArkTS bridge via CAetherNativeBridge module.

#ifndef AETHER_CPP_SPLAT_C_H
#define AETHER_CPP_SPLAT_C_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ═══════════════════════════════════════════════════════════════════════
// Opaque Types
// ═══════════════════════════════════════════════════════════════════════

typedef struct aether_splat_engine aether_splat_engine_t;

// ═══════════════════════════════════════════════════════════════════════
// Data Structures (POD, C-compatible)
// ═══════════════════════════════════════════════════════════════════════

/// Configuration for the splat render engine.
typedef struct aether_splat_config {
    size_t   max_splats;              // Max Gaussians on GPU (default: 500000)
    uint32_t sort_precision_bits;     // Radix sort key bits (default: 16)
    float    max_screen_radius;       // Max splat screen radius (default: 1024)
    size_t   triple_buffer_count;     // Frame-in-flight count (default: 3)
} aether_splat_config_t;

/// Per-frame camera state.
typedef struct aether_splat_camera {
    float    view[16];       // column-major 4x4 view matrix
    float    proj[16];       // column-major 4x4 projection matrix
    float    fx, fy;         // focal length (pixels)
    float    cx, cy;         // principal point (pixels)
    uint32_t vp_width;       // viewport width
    uint32_t vp_height;      // viewport height
    uint32_t render_splat_limit; // 0 = unlimited, otherwise render at most this many splats
} aether_splat_camera_t;

/// Gaussian parameters (uncompressed, 92 bytes).
typedef struct aether_gaussian_params {
    float position[3];   // world-space xyz
    float color[3];      // linear RGB [0,1] = SH band 0 (DC)
    float opacity;       // linear opacity [0,1]
    float scale[3];      // xyz scale (positive)
    float rotation[4];   // quaternion (w, x, y, z), normalized
    float sh1[9];        // SH degree-1 coefficients (3 bands × 3 RGB channels)
                         // Zeroed for DC-only data
} aether_gaussian_params_t;

/// Render statistics.
typedef struct aether_splat_stats {
    size_t total_splats;
    size_t visible_splats;
    uint32_t sort_mode; /* 0=none, 1=CPU stable sort, 2=GPU sort, 3=HTGS core/tail */
    float  sort_time_ms;
    float  render_time_ms;
} aether_splat_stats_t;

// ═══════════════════════════════════════════════════════════════════════
// Engine Lifecycle
// ═══════════════════════════════════════════════════════════════════════

/// Get default configuration.
/// Returns 0 on success.
int aether_splat_default_config(aether_splat_config_t* out_config);

/// Create a splat render engine.
/// The gpu_device_ptr is an opaque pointer to a platform-specific GPUDevice.
/// Returns 0 on success, sets *out_engine.
int aether_splat_engine_create(void* gpu_device_ptr,
                                const aether_splat_config_t* config,
                                aether_splat_engine_t** out_engine);

/// Destroy a splat render engine.
void aether_splat_engine_destroy(aether_splat_engine_t* engine);

// ═══════════════════════════════════════════════════════════════════════
// Data Loading
// ═══════════════════════════════════════════════════════════════════════

/// Load Gaussians from a PLY file.
/// Returns 0 on success.
int aether_splat_load_ply(aether_splat_engine_t* engine,
                           const char* path);

/// Load Gaussians from compressed SPZ data.
/// Returns 0 on success.
int aether_splat_load_spz(aether_splat_engine_t* engine,
                           const uint8_t* data,
                           size_t size);

/// Load Gaussians from a pre-parsed array.
/// Returns 0 on success.
int aether_splat_load_gaussians(aether_splat_engine_t* engine,
                                 const aether_gaussian_params_t* params,
                                 size_t count);

// ═══════════════════════════════════════════════════════════════════════
// Incremental Update (Spark pushSplat API)
// ═══════════════════════════════════════════════════════════════════════

/// Push Gaussians incrementally (safe to call from background thread).
/// Data is staged and uploaded at next begin_frame().
int aether_splat_push(aether_splat_engine_t* engine,
                       const aether_gaussian_params_t* params,
                       size_t count);

/// D3: Push Gaussians with per-splat region IDs for progressive reveal.
/// region_ids[i] = temporal region index for params[i], uint8 per splat.
/// Used by "破镜重圆" progressive reveal rendering.
int aether_splat_push_with_regions(aether_splat_engine_t* engine,
                                    const aether_gaussian_params_t* params,
                                    const uint8_t* region_ids,
                                    size_t count);

/// D3: Set per-region fade alphas for progressive reveal rendering.
/// fade_alphas[i] = alpha for region i, range [0,1].
/// count must be <= 32 (kMaxRegions).
void aether_splat_set_region_fade_alphas(aether_splat_engine_t* engine,
                                          const float* fade_alphas,
                                          size_t count);

/// Clear all splats.
void aether_splat_clear(aether_splat_engine_t* engine);

// ═══════════════════════════════════════════════════════════════════════
// Per-Frame Rendering
// ═══════════════════════════════════════════════════════════════════════
// Call sequence per frame:
//   1. aether_splat_begin_frame()
//   2. aether_splat_update_camera()
//   3. aether_splat_encode_sort()       — with platform command buffer
//   4. aether_splat_encode_render()     — with platform command buffer
//   5. aether_splat_end_frame()

/// Begin a new frame.
void aether_splat_begin_frame(aether_splat_engine_t* engine);

/// Set camera state for this frame.
void aether_splat_update_camera(aether_splat_engine_t* engine,
                                 const aether_splat_camera_t* camera);

/// Encode GPU sort pass.
/// cmd_buffer_ptr is an opaque pointer to the platform command buffer.
void aether_splat_encode_sort(aether_splat_engine_t* engine,
                               void* cmd_buffer_ptr);

/// Encode GPU render pass (offscreen — creates own textures).
/// cmd_buffer_ptr is an opaque pointer to the platform command buffer.
/// render_target_ptr is an opaque pointer to the render target descriptor (GPURenderTargetDesc*).
void aether_splat_encode_render(aether_splat_engine_t* engine,
                                 void* cmd_buffer_ptr,
                                 void* render_target_ptr);

/// Encode GPU render pass using a platform-native render pass descriptor.
/// On Metal: render_pass_desc_ptr is MTLRenderPassDescriptor* via Unmanaged.toOpaque().
/// Renders directly into the MTKView's drawable (no offscreen textures created).
void aether_splat_encode_render_native(aether_splat_engine_t* engine,
                                        void* cmd_buffer_ptr,
                                        void* render_pass_desc_ptr);

/// End frame. Returns render stats.
void aether_splat_end_frame(aether_splat_engine_t* engine,
                             aether_splat_stats_t* out_stats);

// ═══════════════════════════════════════════════════════════════════════
// Queries
// ═══════════════════════════════════════════════════════════════════════

/// Get current splat count.
size_t aether_splat_count(const aether_splat_engine_t* engine);

/// Get bounding sphere of loaded Gaussians.
/// center[3] receives xyz centroid, *radius receives max distance from centroid.
/// Returns 0 on success, -1 if no data loaded.
int aether_splat_get_bounds(const aether_splat_engine_t* engine,
                             float center[3], float* radius);

/// Check if engine is initialized with data.
int aether_splat_is_initialized(const aether_splat_engine_t* engine);

/// Get pointer to the CPU-side PackedSplat array (16 bytes per element).
/// Valid until next push/clear/load call. Returns NULL if empty.
const void* aether_splat_get_packed_data(const aether_splat_engine_t* engine);

/// Get number of packed splats in the CPU buffer.
size_t aether_splat_get_packed_count(const aether_splat_engine_t* engine);

/// Get pointer to the CPU-side SH degree-1 coefficient buffer.
/// Layout matches float4[packed_count * 3] (R/G/B channels, xyz used).
/// Valid until next push/clear/load call. Returns NULL if empty.
const void* aether_splat_get_sh_data(const aether_splat_engine_t* engine);

/// Get number of floats in the CPU-side SH buffer.
size_t aether_splat_get_sh_float_count(const aether_splat_engine_t* engine);

// ═══════════════════════════════════════════════════════════════════════
// Utility Functions
// ═══════════════════════════════════════════════════════════════════════

/// Load a PLY file and return the Gaussian count (without creating an engine).
/// Useful for inspection/validation.
int aether_splat_ply_vertex_count(const char* path, size_t* out_count);

/// Pack a single GaussianParams into 16-byte PackedSplat.
/// out_packed must point to 16 bytes.
void aether_splat_pack(const aether_gaussian_params_t* params,
                        uint8_t out_packed[16]);

/// Unpack a 16-byte PackedSplat into GaussianParams.
void aether_splat_unpack(const uint8_t packed[16],
                          aether_gaussian_params_t* out_params);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // AETHER_CPP_SPLAT_C_H
