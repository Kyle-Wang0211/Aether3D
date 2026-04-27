// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_POCKETWORLD_SCENE_IOSURFACE_RENDERER_H
#define AETHER_POCKETWORLD_SCENE_IOSURFACE_RENDERER_H

// ─── Phase 6.4b stage 2 — Scene IOSurface renderer (C ABI) ─────────────
//
// Combines GLB mesh (PBR) and splat in a single IOSurface-backed
// renderer. Replaces aether_splat_renderer_* once the Flutter plugin
// migrates to it; the older splat-only renderer stays for FFI smoke
// continuity.
//
// Two-pass render per frame:
//   Pass 1  (mesh):  PBR via mesh_render.wgsl + Filament BRDF.
//                    Loads view + model uniforms, samples 5 PBR textures.
//                    Writes color + depth.
//   Pass 2  (splat): vert+frag splat_render.wgsl over the same color
//                    target, reading the depth from pass 1 (no write).
//                    Splats currently use hardcoded screen-space
//                    coords (same as splat_iosurface_renderer); they
//                    do NOT respond to view/model gestures yet — that
//                    work is locked in PHASE_BACKLOG.md as Phase 6.4f
//                    (Brush full pipeline integration).
//
// Per-frame protocol same as splat-only renderer:
//   BeginAccess → encode 2 render passes → commit + wait → EndAccess
//
// FFI surface (kept compatible with aether_splat_renderer_*):
//   create / destroy / render_full   match the splat-only signatures
//   load_glb                         new — loads a .glb file, replaces
//                                    any prior mesh

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct AetherSceneRenderer AetherSceneRenderer;

/// Create a renderer that writes mesh + splat into the given IOSurface.
/// Mesh defaults to "no mesh" — no GLB loaded — until aether_scene_renderer_load_glb
/// is called. In the no-mesh state, only the splat overlay pass renders
/// (depth buffer is cleared per frame).
///
/// @param iosurface  CFTypeRef cast to void*. See splat renderer header
///                   for IOSurface lifetime rules — same here.
/// @return Opaque renderer handle, or NULL on failure (with diagnostic).
AetherSceneRenderer* aether_scene_renderer_create(
    void* iosurface,
    uint32_t width,
    uint32_t height
);

void aether_scene_renderer_destroy(AetherSceneRenderer* r);

/// Load a .glb file (KhronosGroup glTF-Sample-Models compatible). The
/// previous mesh, if any, is unloaded first.
///
/// @return true on success, false (with diagnostic) on parse / GPU
///         upload / validation failure.
bool aether_scene_renderer_load_glb(AetherSceneRenderer* r, const char* glb_path);

/// Per-frame render. View and model matrices are 16-float column-major
/// arrays (same convention as aether_splat_renderer_render_full).
/// The mesh applies BOTH matrices through its full PBR shader; the
/// splat overlay currently ignores them visually (Phase 6.4f).
void aether_scene_renderer_render_full(
    AetherSceneRenderer* r,
    const float* view_matrix,
    const float* model_matrix
);

#ifdef __cplusplus
}
#endif

#endif  // AETHER_POCKETWORLD_SCENE_IOSURFACE_RENDERER_H
