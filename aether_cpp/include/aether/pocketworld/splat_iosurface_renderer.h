// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_POCKETWORLD_SPLAT_IOSURFACE_RENDERER_H
#define AETHER_POCKETWORLD_SPLAT_IOSURFACE_RENDERER_H

// ─── Phase 6.4a — IOSurface-backed splat renderer (C ABI) ──────────────
//
// Coarse-grained C ABI used by the PocketWorld Flutter plugin to render
// the 4-splat Aether3D vert+frag pipeline directly into a Flutter-shared
// IOSurface. ZERO copies between GPU and Flutter compositor — Dawn writes
// the IOSurface bytes that Flutter's Texture widget then samples.
//
// Strategy B (chosen 2026-04-26): single coarse FFI per frame instead of
// exposing every GPUDevice virtual through FFI. GPU logic stays in C++
// (already proven 20/20 PASS); Dart/Swift just call render() per frame.
//
// Two-stage rollout per Phase 6.4a / 6.4a' decision:
//   Stage 1 (this file initially): aether_splat_renderer_render(handle, t)
//                                  — time-driven fixed orbit camera
//   Stage 2 (6.4a'): aether_splat_renderer_render_full(handle, view[16], model[16])
//                                  — caller-supplied matrices, FFI doesn't
//                                    change again until Phase 7
//
// Lifecycle:
//   create  — singleton DawnGPUDevice + per-renderer IOSurface texture +
//             uniforms + projected-splat buffer + render pipeline
//   render  — per-frame: BeginAccess → encode pass → commit → wait →
//             EndAccess. The fence pair is wrapped inside render() — the
//             Swift caller never has to manage Begin/End separately
//             (RAII-style discipline preserved across the C ABI).
//   destroy — release all GPU resources for this renderer; if it was the
//             last renderer, the singleton DawnGPUDevice is also released.
//
// Failure modes (all return NULL handle / void):
//   - Singleton DawnGPUDevice creation failed (no Dawn adapter, etc.)
//   - SharedTextureMemoryIOSurface feature unavailable (non-Apple adapter
//     or Dawn build mismatch)
//   - IOSurface format incompatible with Dawn's expectations
//   - WGSL pipeline creation failed (would have aborted via
//     SetUncapturedErrorCallback before reaching us, but defensive check)
// All failures log a diagnostic to stderr — silent failure is impossible
// per the harness contract (Phase 6.3a code-review rule).

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct AetherSplatRenderer AetherSplatRenderer;

/// Create a new renderer that writes to the given IOSurface.
///
/// @param iosurface  CFTypeRef cast to void* — the caller (typically Swift
///                   side) is responsible for keeping the IOSurface alive
///                   for the lifetime of this renderer. The renderer
///                   imports the IOSurface via Dawn's
///                   SharedTextureMemoryIOSurface feature; CFRetain is
///                   handled internally.
/// @param width      IOSurface width in pixels. Must match the IOSurface's
///                   actual width (caller-supplied for sanity checking).
/// @param height     IOSurface height. Same constraint.
///
/// @return Opaque renderer handle, or NULL on any failure (with diagnostic
///         logged to stderr).
AetherSplatRenderer* aether_splat_renderer_create(
    void* iosurface,
    uint32_t width,
    uint32_t height
);

/// Destroy a renderer + release its GPU resources. If this was the last
/// renderer, the singleton DawnGPUDevice is also released. Safe to pass
/// NULL (no-op).
void aether_splat_renderer_destroy(AetherSplatRenderer* r);

/// Phase 6.4a stage 1 (deprecated by stage 2 below) — fixed scene.
///
/// Internally forwards to aether_splat_renderer_render_full with
/// identity view / identity model matrices. t_seconds is recorded but
/// ignored (the WGSL viewer does not currently consume the view matrix
/// — splat positions are pre-projected screen coordinates from the
/// cross_validate baseline).
///
/// Kept for ABI continuity across Phase 6.4a → 6.4a' transition; new
/// callers should use render_full with caller-supplied matrices.
void aether_splat_renderer_render(AetherSplatRenderer* r, double t_seconds);

/// Phase 6.4a' — full-matrix FFI.
///
/// Caller supplies the view + model matrices (16 floats each, column-
/// major; matching glm / GLSL convention). The C++ side memcpy's the
/// bytes into the uniforms buffer's `viewmat` field and dispatches the
/// render pass. No internal time-derivation, no hardcoded camera
/// assumptions.
///
/// Note on visual: the current splat_render.wgsl reads ProjectedSplat
/// values that are already in screen space, so the view matrix is
/// uploaded but does not yet affect the visible output. Phase 6.4c
/// will either:
///   (a) extend splat_render.wgsl to apply view matrix to per-splat
///       world-space positions, or
///   (b) run the full Brush project_forward → project_visible chain
///       inside this function before calling splat_render.
/// Either way, the FFI shape locked here doesn't change.
///
/// @param view_matrix   16-float column-major view matrix (camera).
/// @param model_matrix  16-float column-major model matrix (object).
///                      Currently unused; reserved for Phase 6.4c
///                      object transform support.
void aether_splat_renderer_render_full(
    AetherSplatRenderer* r,
    const float* view_matrix,
    const float* model_matrix
);

#ifdef __cplusplus
}
#endif

#endif  // AETHER_POCKETWORLD_SPLAT_IOSURFACE_RENDERER_H
