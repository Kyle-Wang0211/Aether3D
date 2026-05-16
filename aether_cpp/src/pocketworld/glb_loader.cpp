// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/pocketworld/glb_loader.h"

// ─── Single-header library implementations ────────────────────────────
// Both must be in exactly one TU. Define the IMPL macros here and
// include the headers; the rest of the codebase pulls function
// declarations only.

#define CGLTF_IMPLEMENTATION
#include "cgltf.h"

#define STB_IMAGE_IMPLEMENTATION
// Disable bmp / gif / hdr / pic / pnm — glTF only uses png / jpeg.
// Smaller .text segment + faster compile.
#define STBI_NO_BMP
#define STBI_NO_GIF
#define STBI_NO_HDR
#define STBI_NO_PIC
#define STBI_NO_PNM
#define STBI_NO_TGA
#define STBI_NO_PSD
#include "stb_image.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <limits>
#include <utility>
#include <vector>

namespace aether {
namespace pocketworld {

using namespace ::aether::render;  // GPU* types live here

namespace {

inline void glb_log(const char* fmt, ...) {
    va_list args;
    va_start(args, fmt);
    std::fprintf(stderr, "[Aether3D][glb_loader] ");
    std::vfprintf(stderr, fmt, args);
    std::fprintf(stderr, "\n");
    va_end(args);
}

// ─── Vertex attribute reader: cgltf accessor → MeshVertex member ───────
//
// glTF accessors describe a typed view over a buffer view (binary data
// section). cgltf_accessor_read_float decodes one element by index into
// a float[component_count] buffer regardless of underlying storage
// (uint8 normalized, uint16 normalized, float, …).

bool read_attribute_to_floats(const cgltf_accessor* acc,
                               std::size_t element_idx,
                               float* out, std::size_t out_count) {
    if (!acc) return false;
    return cgltf_accessor_read_float(acc, element_idx, out, out_count);
}

// Read up to N indices as uint32. cgltf normalizes uint16 → uint32 via
// cgltf_accessor_read_uint.
std::vector<std::uint32_t> read_indices(const cgltf_accessor* acc) {
    std::vector<std::uint32_t> out;
    if (!acc) return out;
    out.resize(acc->count);
    for (std::size_t i = 0; i < acc->count; ++i) {
        cgltf_uint v = 0;
        cgltf_accessor_read_uint(acc, i, &v, 1);
        out[i] = static_cast<std::uint32_t>(v);
    }
    return out;
}

// ─── Texture loading (stb_image decode + GPU upload) ───────────────────
//
// glTF embeds PNG / JPEG bytes; cgltf gives us the buffer + offset +
// length. We hand those to stbi_load_from_memory which decodes to
// 4-channel RGBA8 (forced via desired_channels=4 — even if the source
// is RGB, we get an alpha=255 channel so the GPU layout is uniform).
//
// Failure modes log + return invalid handle. update_texture pads
// bytes-per-row if width * 4 isn't 256-aligned (Dawn requires
// 256-byte alignment for queue.writeTexture; we already pad here on
// the source side so the GPU upload sees aligned rows).

GPUTextureHandle load_texture_from_image(GPUDevice& device,
                                          const cgltf_texture* tex,
                                          const cgltf_data* /*data*/,
                                          const char* label) {
    if (!tex || !tex->image) return GPUTextureHandle{0};
    const cgltf_image* img = tex->image;

    // Resolve image source: either inline buffer view or external URI.
    // KhronosGroup samples we target use inline buffer views.
    int w = 0, h = 0, comp = 0;
    stbi_uc* pixels = nullptr;
    if (img->buffer_view) {
        const cgltf_buffer_view* bv = img->buffer_view;
        const std::uint8_t* src = static_cast<const std::uint8_t*>(bv->buffer->data) + bv->offset;
        pixels = stbi_load_from_memory(src, static_cast<int>(bv->size),
                                        &w, &h, &comp,
                                        /*desired_channels=*/4);
    } else if (img->uri) {
        // External URI — not in scope for KhronosGroup samples we test
        // against. Fall back to nullptr.
        glb_log("texture '%s': external URI '%.32s' not supported "
                "(use embedded buffer view in GLB); skipping",
                label ? label : "?", img->uri);
        return GPUTextureHandle{0};
    }
    if (!pixels) {
        glb_log("texture '%s': stbi_load_from_memory failed: %s",
                label ? label : "?", stbi_failure_reason());
        return GPUTextureHandle{0};
    }

    // Upload to GPU. update_texture wants raw RGBA8 with row stride =
    // width * 4 (tight packed); our DawnGPUDevice handles 256-byte
    // padding internally where needed.
    GPUTextureDesc desc{};
    desc.width = static_cast<std::uint32_t>(w);
    desc.height = static_cast<std::uint32_t>(h);
    desc.depth = 1;
    desc.mip_levels = 1;
    desc.format = GPUTextureFormat::kRGBA8Unorm;
    desc.usage_mask = static_cast<std::uint8_t>(GPUTextureUsage::kShaderRead);
    desc.label = label;

    GPUTextureHandle handle = device.create_texture(desc);
    if (!handle.valid()) {
        glb_log("texture '%s': create_texture failed (w=%d h=%d)",
                label ? label : "?", w, h);
        stbi_image_free(pixels);
        return GPUTextureHandle{0};
    }
    device.update_texture(handle, pixels,
                          static_cast<std::uint32_t>(w),
                          static_cast<std::uint32_t>(h),
                          static_cast<std::uint32_t>(w) * 4u);
    stbi_image_free(pixels);
    return handle;
}

}  // namespace

std::optional<LoadedMesh> load_glb_mesh(GPUDevice& device,
                                         const std::string& glb_path) noexcept {
    cgltf_options options{};
    cgltf_data* data = nullptr;

    cgltf_result r = cgltf_parse_file(&options, glb_path.c_str(), &data);
    if (r != cgltf_result_success) {
        glb_log("cgltf_parse_file failed: '%s' status=%d",
                glb_path.c_str(), static_cast<int>(r));
        return std::nullopt;
    }
    // load_buffers: resolves the binary chunk for GLBs (the .bin body)
    // OR external .bin files for split glTFs. Required before reading
    // any accessor.
    r = cgltf_load_buffers(&options, data, glb_path.c_str());
    if (r != cgltf_result_success) {
        glb_log("cgltf_load_buffers failed: '%s' status=%d",
                glb_path.c_str(), static_cast<int>(r));
        cgltf_free(data);
        return std::nullopt;
    }
    // Validate per cgltf's spec checks. catches weird issues like
    // mismatched accessor counts before we try to read them.
    r = cgltf_validate(data);
    if (r != cgltf_result_success) {
        glb_log("cgltf_validate failed: '%s' status=%d",
                glb_path.c_str(), static_cast<int>(r));
        cgltf_free(data);
        return std::nullopt;
    }

    LoadedMesh mesh;
    mesh.bounds_min[0] = mesh.bounds_min[1] = mesh.bounds_min[2] =
        std::numeric_limits<float>::max();
    mesh.bounds_max[0] = mesh.bounds_max[1] = mesh.bounds_max[2] =
        std::numeric_limits<float>::lowest();

    // ─── Materials ────────────────────────────────────────────────────
    // KhronosGroup PBR-Metallic-Roughness materials. Texture handles
    // default to invalid (0) when the glTF material doesn't reference
    // a particular texture (mesh_render.wgsl handles invalid handles
    // by treating them as constant white).
    mesh.materials.reserve(data->materials_count);
    for (std::size_t mi = 0; mi < data->materials_count; ++mi) {
        const cgltf_material& m = data->materials[mi];
        PbrMaterial pm{};
        if (m.has_pbr_metallic_roughness) {
            const auto& pbr = m.pbr_metallic_roughness;
            pm.base_color_factor[0] = pbr.base_color_factor[0];
            pm.base_color_factor[1] = pbr.base_color_factor[1];
            pm.base_color_factor[2] = pbr.base_color_factor[2];
            pm.base_color_factor[3] = pbr.base_color_factor[3];
            pm.metallic_factor  = pbr.metallic_factor;
            pm.roughness_factor = pbr.roughness_factor;
            if (pbr.base_color_texture.texture) {
                pm.base_color_tex = load_texture_from_image(
                    device, pbr.base_color_texture.texture, data, "base_color");
            }
            if (pbr.metallic_roughness_texture.texture) {
                pm.metallic_roughness_tex = load_texture_from_image(
                    device, pbr.metallic_roughness_texture.texture, data,
                    "metallic_roughness");
            }
        } else {
            pm.base_color_factor[0] = 1; pm.base_color_factor[1] = 1;
            pm.base_color_factor[2] = 1; pm.base_color_factor[3] = 1;
            pm.metallic_factor = 0;
            pm.roughness_factor = 1;
        }
        if (m.normal_texture.texture) {
            pm.normal_tex = load_texture_from_image(
                device, m.normal_texture.texture, data, "normal");
        }
        if (m.occlusion_texture.texture) {
            pm.occlusion_tex = load_texture_from_image(
                device, m.occlusion_texture.texture, data, "occlusion");
            pm.occlusion_strength = m.occlusion_texture.scale;
        } else {
            pm.occlusion_strength = 1.0f;
        }
        if (m.emissive_texture.texture) {
            pm.emissive_tex = load_texture_from_image(
                device, m.emissive_texture.texture, data, "emissive");
        }
        pm.emissive_factor[0] = m.emissive_factor[0];
        pm.emissive_factor[1] = m.emissive_factor[1];
        pm.emissive_factor[2] = m.emissive_factor[2];
        mesh.materials.push_back(pm);
    }

    // ─── Geometry ─────────────────────────────────────────────────────
    // Walk the scene/node hierarchy (NOT data->meshes directly). glTF
    // places each mesh inside a node with a world transform; some
    // sample assets (e.g. Khronos DamagedHelmet) rely on the root
    // node's rotation to convert from their original Maya/Sketchfab
    // Z-up coordinate system into glTF's canonical Y-up. Rendering the
    // raw mesh.primitive vertex data without that transform makes the
    // helmet appear lying on its side. Other samples (e.g. ToyCar)
    // bake unit-conversion scale into the node — without it the model
    // arrives at sphereR≈540 instead of 1.
    //
    // For each node with a mesh, ask cgltf for the full world
    // transform (parent chain folded in), then apply it to each
    // vertex's position + normal + tangent before GPU upload. The
    // shader pipeline still receives a single flat LoadedMesh; node
    // hierarchy is invisible past this loader.
    //
    // Collect (cgltf_node*, mesh*) pairs first so we can still iterate
    // each primitive in source order.
    using NodeMeshPair = std::pair<const cgltf_node*, const cgltf_mesh*>;
    std::vector<NodeMeshPair> draw_list;
    std::function<void(const cgltf_node*)> walk_node;
    walk_node = [&](const cgltf_node* node) {
        if (!node) return;
        if (node->mesh) {
            draw_list.emplace_back(node, node->mesh);
        }
        for (cgltf_size c = 0; c < node->children_count; ++c) {
            walk_node(node->children[c]);
        }
    };
    if (data->scenes_count > 0) {
        const cgltf_scene* scene = data->scene
            ? data->scene
            : &data->scenes[0];
        for (cgltf_size n = 0; n < scene->nodes_count; ++n) {
            walk_node(scene->nodes[n]);
        }
    } else {
        // glTF without a default scene — fall back to enumerating every
        // mesh and rendering it at identity (the legacy behaviour).
        // Rare in practice; Khronos samples all have scenes.
        for (cgltf_size i = 0; i < data->nodes_count; ++i) {
            walk_node(&data->nodes[i]);
        }
    }
    // If even the node walk found nothing (unrigged mesh-only glTFs do
    // exist), fall back to direct mesh enumeration with identity
    // transform.
    if (draw_list.empty()) {
        for (cgltf_size i = 0; i < data->meshes_count; ++i) {
            draw_list.emplace_back(nullptr, &data->meshes[i]);
        }
    }

    // Helper: 4x4 column-major matrix-vector multiply (point: w=1).
    auto transform_point = [](const float m[16], float x, float y, float z,
                              float* out_x, float* out_y, float* out_z) {
        // M is column-major: m[c*4 + r] = M[r][c].
        *out_x = m[0]*x + m[4]*y + m[8]*z  + m[12];
        *out_y = m[1]*x + m[5]*y + m[9]*z  + m[13];
        *out_z = m[2]*x + m[6]*y + m[10]*z + m[14];
    };
    // Helper: transform a direction vector (w=0) through the matrix's
    // upper-3x3. For rotation+uniform-scale this is the right thing for
    // normals / tangents; for non-uniform scale a true inverse-
    // transpose would be more correct, but every glTF sample we ship
    // today uses uniform scale.
    auto transform_dir = [](const float m[16], float x, float y, float z,
                            float* out_x, float* out_y, float* out_z) {
        *out_x = m[0]*x + m[4]*y + m[8]*z;
        *out_y = m[1]*x + m[5]*y + m[9]*z;
        *out_z = m[2]*x + m[6]*y + m[10]*z;
        const float len2 = (*out_x)*(*out_x) + (*out_y)*(*out_y) + (*out_z)*(*out_z);
        if (len2 > 1e-12f) {
            const float inv = 1.0f / std::sqrt(len2);
            *out_x *= inv; *out_y *= inv; *out_z *= inv;
        }
    };

    for (std::size_t di = 0; di < draw_list.size(); ++di) {
        const cgltf_node* node = draw_list[di].first;
        const cgltf_mesh& gltf_mesh = *draw_list[di].second;
        // World transform: identity when no node (fallback path) or
        // pulled from cgltf when we have one. cgltf_node_transform_world
        // folds in every ancestor, so this is the actual world-space
        // basis the vertex should land in.
        float xform[16];
        if (node) {
            cgltf_node_transform_world(node, xform);
        } else {
            std::memset(xform, 0, sizeof(xform));
            xform[0] = xform[5] = xform[10] = xform[15] = 1.0f;
        }
        const std::size_t mi = static_cast<std::size_t>(
            (&gltf_mesh) - data->meshes);
        for (std::size_t pi = 0; pi < gltf_mesh.primitives_count; ++pi) {
            const cgltf_primitive& prim = gltf_mesh.primitives[pi];
            if (prim.type != cgltf_primitive_type_triangles) {
                glb_log("primitive %zu/%zu: non-triangle topology %d skipped",
                        mi, pi, static_cast<int>(prim.type));
                continue;
            }

            // ─── Filter contact-shadow planes (2026-05-02) ──────────────
            //
            // Khronos PBR samples (ToyCar, Lantern, AntiqueCamera, etc.)
            // bake a flat quad UNDER the model whose material has
            //   alphaMode = BLEND
            //   baseColorFactor.rgb = (0, 0, 0)
            //   baseColorFactor.alpha (or texture alpha) encodes the
            //     shadow strength
            // The intended use is "draw on top of a ground/table mesh
            // and provide a soft drop shadow." PocketWorld renders one
            // model on a transparent IOSurface (no ground beneath), so
            // these planes draw as a free-floating black blob over the
            // white card background — visually broken without context.
            //
            // Heuristic: ANY primitive whose material has BLEND alpha
            // mode AND a near-black baseColorFactor.rgb is by-design a
            // shadow plane. Skip the GPU upload entirely.
            //
            // SAFE for legit translucent content (glass canopy, sheer
            // fabric, etc.) — those have baseColorFactor.rgb close to
            // (1,1,1) and the alpha comes from a real texture. The
            // black-factor heuristic only matches deliberate "shadow
            // material" authoring.
            //
            // NOT applied to splat content (PLY/SPZ go through a
            // different loader entirely).
            if (prim.material && prim.material->alpha_mode == cgltf_alpha_mode_blend) {
                const auto& bcf = prim.material->pbr_metallic_roughness.base_color_factor;
                const float brightness = bcf[0] + bcf[1] + bcf[2];
                if (brightness < 0.3f) {
                    glb_log("primitive %zu/%zu: contact-shadow plane filtered "
                            "(material '%s' alphaMode=BLEND, baseColorFactor="
                            "(%.2f,%.2f,%.2f), brightness=%.2f < 0.3)",
                            mi, pi,
                            prim.material->name ? prim.material->name : "?",
                            bcf[0], bcf[1], bcf[2], brightness);
                    continue;
                }
            }

            // Resolve the 4 attributes we need.
            const cgltf_accessor* acc_pos = nullptr;
            const cgltf_accessor* acc_nrm = nullptr;
            const cgltf_accessor* acc_uv  = nullptr;
            const cgltf_accessor* acc_tan = nullptr;
            for (std::size_t ai = 0; ai < prim.attributes_count; ++ai) {
                const cgltf_attribute& attr = prim.attributes[ai];
                switch (attr.type) {
                    case cgltf_attribute_type_position: acc_pos = attr.data; break;
                    case cgltf_attribute_type_normal:   acc_nrm = attr.data; break;
                    case cgltf_attribute_type_texcoord:
                        if (attr.index == 0) acc_uv = attr.data;
                        break;
                    case cgltf_attribute_type_tangent:  acc_tan = attr.data; break;
                    default: break;
                }
            }
            if (!acc_pos || !acc_nrm) {
                glb_log("primitive %zu/%zu: missing POSITION or NORMAL — skipped",
                        mi, pi);
                continue;
            }

            const std::size_t vcount = acc_pos->count;
            std::vector<MeshVertex> vertices(vcount);
            for (std::size_t i = 0; i < vcount; ++i) {
                MeshVertex& v = vertices[i];
                float raw_pos[3];
                float raw_nrm[3];
                read_attribute_to_floats(acc_pos, i, raw_pos, 3);
                read_attribute_to_floats(acc_nrm, i, raw_nrm, 3);
                // Bake the node's world transform into vertex data so
                // the shader pipeline sees one flat mesh in world
                // space. See the draw_list construction comment above
                // for the rationale; without this DamagedHelmet renders
                // sideways and ToyCar arrives at a 540-unit radius.
                transform_point(xform,
                                raw_pos[0], raw_pos[1], raw_pos[2],
                                &v.position[0], &v.position[1], &v.position[2]);
                transform_dir(xform,
                              raw_nrm[0], raw_nrm[1], raw_nrm[2],
                              &v.normal[0], &v.normal[1], &v.normal[2]);
                if (acc_uv) {
                    read_attribute_to_floats(acc_uv, i, v.uv, 2);
                } else {
                    v.uv[0] = 0; v.uv[1] = 0;
                }
                if (acc_tan) {
                    float raw_tan[4];
                    read_attribute_to_floats(acc_tan, i, raw_tan, 4);
                    transform_dir(xform,
                                  raw_tan[0], raw_tan[1], raw_tan[2],
                                  &v.tangent[0], &v.tangent[1], &v.tangent[2]);
                    v.tangent[3] = raw_tan[3];  // bitangent sign — preserved.
                } else {
                    // Default tangent: along world-X with bitangent-sign +1.
                    // This is wrong for normal-mapped surfaces but only
                    // matters where the material has normal_tex; the
                    // shader handles missing tangent-space gracefully
                    // (falls back to face-normal lighting).
                    v.tangent[0] = 1; v.tangent[1] = 0; v.tangent[2] = 0;
                    v.tangent[3] = 1;
                }
                // Update bounds in world space (post-transform).
                for (int j = 0; j < 3; ++j) {
                    if (v.position[j] < mesh.bounds_min[j]) mesh.bounds_min[j] = v.position[j];
                    if (v.position[j] > mesh.bounds_max[j]) mesh.bounds_max[j] = v.position[j];
                }
            }

            // Indices.
            std::vector<std::uint32_t> indices = read_indices(prim.indices);
            if (indices.empty()) {
                // Non-indexed primitive — generate trivial 0..N indices.
                indices.resize(vcount);
                for (std::size_t i = 0; i < vcount; ++i) indices[i] = static_cast<std::uint32_t>(i);
            }

            // GPU upload.
            GPUBufferDesc vb_desc{};
            vb_desc.size_bytes = vertices.size() * sizeof(MeshVertex);
            vb_desc.storage = GPUStorageMode::kPrivate;
            vb_desc.usage_mask = static_cast<std::uint8_t>(GPUBufferUsage::kVertex)
                               | static_cast<std::uint8_t>(GPUBufferUsage::kStorage);
            vb_desc.label = "glb_mesh.vertex_buffer";

            GPUBufferDesc ib_desc{};
            ib_desc.size_bytes = indices.size() * sizeof(std::uint32_t);
            ib_desc.storage = GPUStorageMode::kPrivate;
            ib_desc.usage_mask = static_cast<std::uint8_t>(GPUBufferUsage::kIndex);
            ib_desc.label = "glb_mesh.index_buffer";

            MeshGeometry geom{};
            geom.vertex_buffer = device.create_buffer(vb_desc);
            geom.index_buffer  = device.create_buffer(ib_desc);
            if (!geom.vertex_buffer.valid() || !geom.index_buffer.valid()) {
                glb_log("primitive %zu/%zu: create_buffer failed", mi, pi);
                if (geom.vertex_buffer.valid()) device.destroy_buffer(geom.vertex_buffer);
                if (geom.index_buffer.valid())  device.destroy_buffer(geom.index_buffer);
                continue;
            }
            device.update_buffer(geom.vertex_buffer, vertices.data(), 0,
                                  vertices.size() * sizeof(MeshVertex));
            device.update_buffer(geom.index_buffer, indices.data(), 0,
                                  indices.size() * sizeof(std::uint32_t));
            geom.vertex_count = static_cast<std::uint32_t>(vertices.size());
            geom.index_count = static_cast<std::uint32_t>(indices.size());
            geom.material_index = prim.material
                ? static_cast<std::uint32_t>(prim.material - data->materials)
                : 0u;
            mesh.primitives.push_back(geom);
        }
    }

    cgltf_free(data);

    if (mesh.primitives.empty()) {
        glb_log("'%s' loaded but produced 0 renderable primitives",
                glb_path.c_str());
        return std::nullopt;
    }
    return mesh;
}

void unload_glb_mesh(GPUDevice& device, LoadedMesh& mesh) noexcept {
    for (auto& prim : mesh.primitives) {
        if (prim.vertex_buffer.valid()) device.destroy_buffer(prim.vertex_buffer);
        if (prim.index_buffer.valid())  device.destroy_buffer(prim.index_buffer);
    }
    mesh.primitives.clear();
    for (auto& mat : mesh.materials) {
        if (mat.base_color_tex.valid())         device.destroy_texture(mat.base_color_tex);
        if (mat.metallic_roughness_tex.valid()) device.destroy_texture(mat.metallic_roughness_tex);
        if (mat.normal_tex.valid())             device.destroy_texture(mat.normal_tex);
        if (mat.occlusion_tex.valid())          device.destroy_texture(mat.occlusion_tex);
        if (mat.emissive_tex.valid())           device.destroy_texture(mat.emissive_tex);
    }
    mesh.materials.clear();
}

}  // namespace pocketworld
}  // namespace aether
