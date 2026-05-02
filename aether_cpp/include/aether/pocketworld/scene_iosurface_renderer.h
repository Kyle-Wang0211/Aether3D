// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_POCKETWORLD_SCENE_IOSURFACE_RENDERER_H
#define AETHER_POCKETWORLD_SCENE_IOSURFACE_RENDERER_H

// ─── Phase 6.4b stage 2 — Scene IOSurface renderer (C ABI) ─────────────
//
// Combines GLB mesh (PBR) and splat in a single IOSurface-backed
// renderer. Phase 6.4 cleanup retired the legacy splat-only renderer —
// callers that just need a splat overlay can use this renderer with no
// GLB loaded (no-mesh state = splat overlay alone, depth cleared).
//
// Two-pass render per frame:
//   Pass 1  (mesh):  PBR via mesh_render.wgsl + Filament BRDF.
//                    Loads view + model uniforms, samples 5 PBR textures.
//                    Writes color + depth.
//   Pass 2  (splat): vert+frag splat_render.wgsl over the same color
//                    target, reading the depth from pass 1 (no write).
//                    Splats use hardcoded screen-space coords; they do
//                    NOT respond to view/model gestures yet — that work
//                    is locked in PHASE_BACKLOG.md as Phase 6.4f (Brush
//                    full pipeline integration).
//
// Per-frame protocol:
//   BeginAccess → encode 2 render passes → commit + wait → EndAccess
//
// FFI surface:
//   create / destroy / render_full   per-frame matrices view + model
//   load_glb                         loads a .glb file, replaces any
//                                    prior mesh

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

/// Phase 6.4f: load a 3D Gaussian Splat .ply file (INRIA convention —
/// f_dc_*, scale_*, rot_*, opacity, optional f_rest_* SH coefficients).
/// Replaces any previously loaded splat scene. Independent of the
/// mesh slot; a renderer can hold either a mesh OR a splat scene
/// (or in principle both, for hybrid content), but PocketWorld feeds
/// one-at-a-time.
///
/// Initial 6.4f cut renders sh_degree=0 (DC color only) without GPU
/// depth sort — splats render in atomic-write order from
/// project_forward, producing correct silhouettes but minor transparency
/// artifacts on heavy splat overlap. Higher-order SH and the 5-kernel
/// radix sort are tracked as Phase 6.4f.2 in PHASE_BACKLOG.md.
///
/// @return true on success, false on parse / GPU upload / validation
///         failure (logs to stderr in failure cases).
bool aether_scene_renderer_load_ply(AetherSceneRenderer* r, const char* ply_path);

/// Phase 6.4f: load a Niantic Lightship SPZ-format compressed splat
/// scene (https://github.com/nianticlabs/spz). 24-bit fixed-point
/// positions + gzip compression — typically 8-12× smaller than the
/// equivalent PLY at indistinguishable visual quality.
///
/// @return same contract as load_ply.
bool aether_scene_renderer_load_spz(AetherSceneRenderer* r, const char* spz_path);

/// Phase 6.4f.3.b — Memory-capped variants of load_ply / load_spz.
///
/// `max_splats=0` means no splat-count cap. `max_sh_degree` clamps
/// the loaded SH degree (0 = DC only — saves ~12 B per loaded basis
/// per splat at sh_degree=3, ie ~540 B/splat going from 3→0). For
/// PocketWorld feed thumbnails where the splat fits in <= 256 px the
/// extra SH bands are imperceptible; passing max_sh_degree=0 saves
/// ~25× SH-buffer memory at zero visual cost.
///
/// `max_splats > 0` evicts gaussians via deterministic stride
/// subsample (every k-th gaussian where k = ceil(N/max_splats)), so
/// the same SPZ always reduces to the same coarse representation.
///
/// Returns true on success, false on parse / GPU upload failure.
bool aether_scene_renderer_load_ply_capped(
    AetherSceneRenderer* r,
    const char* ply_path,
    uint32_t max_splats,
    uint8_t max_sh_degree);

bool aether_scene_renderer_load_spz_capped(
    AetherSceneRenderer* r,
    const char* spz_path,
    uint32_t max_splats,
    uint8_t max_sh_degree);

/// Phase 6.4f.4.b — runtime per-splat LOD cull.
///
/// Set the minimum projected 2D bounding-box extent (in pixels) below
/// which a splat is dropped before the visible list is built. 0 (the
/// default) disables the cull and matches pre-6.4f.4 behaviour.
///
/// Combined with the load-time octree subsample (Phase 6.4f.3.d /
/// 6.4f.4.c), this gives a coarse two-level LOD: dense near-camera
/// regions render at full splat density; far-away regions get culled
/// per-splat once their projection drops below the configured pixel
/// threshold. A typical feed-thumbnail value is 0.5–1.0; detail pages
/// should leave this at 0.
///
/// This is *not* the full Octree-GS GPU per-node selection — that
/// would need a select_lod kernel + active_indices binding feeding
/// project_forward. This is the lightweight subset that fits inside
/// project_forward's existing early-exit path.
void aether_scene_renderer_set_lod_extent_min(
    AetherSceneRenderer* r,
    float pixel_extent_min);

/// Per-frame render. View and model matrices are 16-float column-major
/// arrays. The mesh applies BOTH matrices through its full PBR shader;
/// the splat overlay currently ignores them visually (Phase 6.4f).
void aether_scene_renderer_render_full(
    AetherSceneRenderer* r,
    const float* view_matrix,
    const float* model_matrix
);

/// G4: Surface the local-space AABB of the currently loaded mesh so the
/// Flutter caller can drive its model-viewer-style camera fit
/// (`distance = sphereR / sin(fov/2)`). Bounds are computed during
/// load_glb (see glb_loader.cpp computing bounds_min/max from every
/// vertex position). Returns false if no mesh is loaded; in that case
/// out_min/out_max are left untouched.
///
/// @param out_min  3 floats — written with bounds_min.xyz on success.
/// @param out_max  3 floats — written with bounds_max.xyz on success.
bool aether_scene_renderer_get_bounds(
    AetherSceneRenderer* r,
    float* out_min,
    float* out_max
);

#ifdef __cplusplus
}
#endif

#endif  // AETHER_POCKETWORLD_SCENE_IOSURFACE_RENDERER_H
