// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_POCKETWORLD_GLB_LOADER_H
#define AETHER_POCKETWORLD_GLB_LOADER_H

#ifdef __cplusplus

// ─── Phase 6.4b — GLB mesh loader (cgltf + stb_image) ──────────────────
//
// Loads a .glb file into GPU resources via DawnGPUDevice. Output is
// suitable for direct binding into mesh_render.wgsl's PBR pipeline.
//
// Vendored deps:
//   third_party/cgltf/cgltf.h       (MIT, v1.14, jkuhlmann)
//   third_party/stb/stb_image.h     (MIT/public-domain, v2.30, Sean Barrett)
//
// Test inputs: KhronosGroup/glTF-Sample-Models (decision pin 20). The
// loader does NOT attempt to handle every glTF extension — it targets
// the subset KhronosGroup samples use:
//   - PBR Metallic-Roughness materials (no specular-glossiness)
//   - Triangle topology (no points / lines / triangle strips)
//   - Indexed primitives (uint16 / uint32)
//   - Position + Normal + UV0 + Tangent vertex attributes
//   - PNG / JPEG textures embedded in the GLB (decoded by stb_image)
//
// Failure modes (all return std::nullopt + log diagnostic):
//   - file open / parse error
//   - unsupported topology / accessor type
//   - missing required attribute (POSITION, NORMAL — UV0 / TANGENT
//     fall back to defaults if absent)
//   - texture decode failure
//   - GPU buffer / texture allocation failure
//
// Decision pin 10 (zero silent failure): every failure path logs to
// stderr before returning std::nullopt. Caller treats nullopt as a
// hard error (Flutter UI shows GLB_LOAD_FAILED).

#include "aether/render/gpu_device.h"

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

namespace aether {
namespace pocketworld {

// Pull GPU types into pocketworld scope so the header reads cleanly
// without `render::` qualifiers everywhere. The render:: namespace
// remains the canonical location.
using ::aether::render::GPUBufferHandle;
using ::aether::render::GPUTextureHandle;
using ::aether::render::GPUDevice;

// ─── Material (matches mesh_render.wgsl PbrFactors uniform layout) ─────

struct PbrMaterial {
    GPUTextureHandle base_color_tex;          // RGBA8Unorm sRGB-encoded
    GPUTextureHandle metallic_roughness_tex;  // RGBA8Unorm: G=roughness, B=metallic
    GPUTextureHandle normal_tex;              // RGBA8Unorm tangent-space [-1, 1] mapped to [0, 1]
    GPUTextureHandle occlusion_tex;           // RGBA8Unorm: R=AO
    GPUTextureHandle emissive_tex;            // RGBA8Unorm sRGB-encoded
    float base_color_factor[4];               // multiplied with sampled base_color
    float metallic_factor;                    // multiplied with sampled metallic
    float roughness_factor;                   // multiplied with sampled roughness
    float emissive_factor[3];                 // multiplied with sampled emissive
    float occlusion_strength;                 // ambient occlusion intensity
};

// ─── Geometry (one per glTF primitive) ─────────────────────────────────

struct MeshVertex {
    float position[3];
    float normal[3];
    float uv[2];
    float tangent[4];  // tangent.w is bitangent sign per glTF convention
};
static_assert(sizeof(MeshVertex) == 48,
              "MeshVertex must be 12 floats = 48 bytes (matches mesh_render.wgsl layout)");

struct MeshGeometry {
    GPUBufferHandle vertex_buffer;   // interleaved MeshVertex array
    GPUBufferHandle index_buffer;    // uint32 indices (cgltf normalizes uint16 → uint32 if needed)
    std::uint32_t vertex_count;
    std::uint32_t index_count;
    std::uint32_t material_index;    // index into LoadedMesh::materials
};

// ─── Loaded scene root ─────────────────────────────────────────────────

struct LoadedMesh {
    std::vector<MeshGeometry> primitives;
    std::vector<PbrMaterial> materials;
    // Axis-aligned bounding box in model space (computed across all
    // primitives). Used by callers to fit camera distance / clipping.
    float bounds_min[3];
    float bounds_max[3];
};

/// Parse `.glb_path` into GPU resources owned by `device`. Returns
/// std::nullopt on any failure (logs diagnostic).
std::optional<LoadedMesh> load_glb_mesh(GPUDevice& device,
                                         const std::string& glb_path) noexcept;

/// Release all GPU resources owned by `mesh`. Safe to call on a moved-
/// from / partially-constructed LoadedMesh (handles are checked for
/// validity individually).
void unload_glb_mesh(GPUDevice& device, LoadedMesh& mesh) noexcept;

}  // namespace pocketworld
}  // namespace aether

#endif  // __cplusplus
#endif  // AETHER_POCKETWORLD_GLB_LOADER_H
