// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

// ─── Phase 6.4b stage 2 — IOSurface scene renderer (mesh + splat) ──────
//
// Two-pass IOSurface renderer:
//   Pass 1: GLB mesh (PBR via mesh_render.wgsl, Filament BRDF) — writes
//           color + depth. Skipped when no mesh is loaded.
//   Pass 2: splat overlay (vert+frag splat_render.wgsl) — reads depth
//           from pass 1 (no write), composes over mesh color via
//           premultiplied alpha. Hardcoded screen-space splat scene
//           (Phase 6.4f tracks the upgrade to Brush full pipeline).
//
// Why fully Dawn-direct (vs going through the GPUDevice virtual
// encoder API):
//   - Multi-pass with shared depth buffer needs explicit pass authoring
//     (the existing make_render_encoder spawns one pass at a time)
//   - Sampler binding has no virtual API entry yet
//   - Texture binding in the encoder is currently a stub
//   - Vertex buffer layout in render pipeline creation is not exposed
//
// Adding all of those to the virtual API would expand its surface
// substantially for a single use case. The GPUDevice abstraction stays
// stable; this TU uses the Dawn-specific accessors (wgpu_device,
// get_texture, etc.) the device exposes for exactly this purpose.
//
// What this renderer DOES NOT do (locked as Phase 6.4f in
// PHASE_BACKLOG.md):
//   - Make splats world-space gesture-responsive. The splats remain at
//     the hardcoded (128, 128) screen position pinned by
//     splat_render.wgsl. Mesh DOES respond to view+model gestures.

#if defined(AETHER_ENABLE_DAWN)

#include "aether/pocketworld/scene_iosurface_renderer.h"
#include "aether/pocketworld/glb_loader.h"
#include "aether/render/dawn_gpu_device.h"
#include "aether/render/gpu_device.h"
#include "aether/render/gpu_resource.h"
#include "aether/shaders/wgsl_sources.h"
#include "aether/splat/packed_splats.h"
#include "aether/splat/ply_loader.h"
#include "aether/splat/spz_decoder.h"

#include "../render/dawn_gpu_device_internal.h"
#include "dawn_device_singleton.h"

#include <webgpu/webgpu.h>

#if defined(__APPLE__)
#include <CoreVideo/CoreVideo.h>
#include <TargetConditionals.h>
#if TARGET_OS_IPHONE
#include <IOSurface/IOSurfaceRef.h>
#elif __has_include(<IOSurface/IOSurface.h>)
#include <IOSurface/IOSurface.h>
#else
#include <IOSurface/IOSurfaceRef.h>
#endif
#endif

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <sys/stat.h>
#include <unordered_map>
#include <vector>

namespace {

using ::aether::pocketworld::LoadedMesh;
using ::aether::pocketworld::PbrMaterial;
using ::aether::render::GPUBufferDesc;
using ::aether::render::GPUBufferHandle;
using ::aether::render::GPUBufferUsage;
using ::aether::render::GPUDevice;
using ::aether::render::GPUShaderHandle;
using ::aether::render::GPUStorageMode;
using ::aether::render::GPUTextureDesc;
using ::aether::render::GPUTextureFormat;
using ::aether::render::GPUTextureHandle;
using ::aether::render::GPUTextureUsage;

inline void scene_log(const char* fmt, ...) {
    va_list args;
    va_start(args, fmt);
    std::fprintf(stderr, "[Aether3D][scene_renderer] ");
    std::vfprintf(stderr, fmt, args);
    std::fprintf(stderr, "\n");
    va_end(args);
}

// ─── Internal Dawn accessors (declared in dawn_gpu_device_internal.h) ──
//
// Production-path: device.backend() == kDawn always. The internal
// accessors return nullptr if it isn't, which we treat as a hard
// configuration bug (caller already checked), so we don't propagate
// further beyond a debug log.

namespace dawn_int = ::aether::render::internal;

bool is_dawn(GPUDevice* d) noexcept {
    return d && d->backend() == ::aether::render::GraphicsBackend::kDawn;
}

const char* gpu_texture_format_name(GPUTextureFormat format) {
    switch (format) {
        case GPUTextureFormat::kBGRA8Unorm: return "BGRA8Unorm";
        case GPUTextureFormat::kRGBA16Float: return "RGBA16Float";
        case GPUTextureFormat::kRGBA8Unorm: return "RGBA8Unorm";
        case GPUTextureFormat::kDepth32Float: return "Depth32Float";
        case GPUTextureFormat::kDepth32Float_Stencil8: return "Depth32Float_Stencil8";
        case GPUTextureFormat::kInvalid: return "Invalid";
        default: return "Other";
    }
}

WGPUTextureFormat to_wgpu_color_format(GPUTextureFormat format) {
    switch (format) {
        case GPUTextureFormat::kBGRA8Unorm: return WGPUTextureFormat_BGRA8Unorm;
        case GPUTextureFormat::kRGBA16Float: return WGPUTextureFormat_RGBA16Float;
        default: return WGPUTextureFormat_Undefined;
    }
}

#if defined(__APPLE__)
const char* iosurface_pixel_format_name(OSType format) {
    switch (format) {
        case kCVPixelFormatType_32BGRA: return "kCVPixelFormatType_32BGRA";
        case kCVPixelFormatType_64RGBAHalf: return "kCVPixelFormatType_64RGBAHalf";
        default: return "unsupported";
    }
}

std::optional<GPUTextureFormat> detect_iosurface_color_format(void* iosurface,
                                                              std::uint32_t width,
                                                              std::uint32_t height) {
    auto surface = static_cast<IOSurfaceRef>(iosurface);
    if (!surface) {
        scene_log("create: IOSurfaceRef cast failed");
        return std::nullopt;
    }

    const std::uint32_t actual_width = static_cast<std::uint32_t>(IOSurfaceGetWidth(surface));
    const std::uint32_t actual_height = static_cast<std::uint32_t>(IOSurfaceGetHeight(surface));
    if (actual_width != width || actual_height != height) {
        scene_log("create: IOSurface dim mismatch actual=(%u,%u) requested=(%u,%u)",
                  actual_width, actual_height, width, height);
        return std::nullopt;
    }

    const OSType pixel_format = IOSurfaceGetPixelFormat(surface);
    switch (pixel_format) {
        case kCVPixelFormatType_32BGRA:
            return GPUTextureFormat::kBGRA8Unorm;
        case kCVPixelFormatType_64RGBAHalf:
            return GPUTextureFormat::kRGBA16Float;
        default:
            scene_log("create: unsupported IOSurface pixel format 0x%08x (%s)",
                      static_cast<unsigned int>(pixel_format),
                      iosurface_pixel_format_name(pixel_format));
            return std::nullopt;
    }
}
#endif

// ─── Splat scene runtime ──────────────────────────────────────────────
//
// Phase 6.4f (2026-05-02): the previous "kBaselineSplats" 4-splat
// hardcoded fixture from Phase 6.3a's cross-validation harness was
// removed here. It rendered as a fixed grey blob at screen-space
// (128, 128) on every card regardless of camera state — pure debug
// content, never production. The real splat path is now driven by
// PLY/SPZ uploads through aether_scene_renderer_load_ply / load_spz,
// orchestrated through Brush's 8-kernel compute chain (project_forward
// → project_visible → map_gaussian_to_intersects → sort_count → reduce
// → scan → scan_add → scatter → splat_render).
//
// Architecture reference: ArthurBrussee/brush
// (crates/brush-render/src/render.rs) is the pattern this orchestration
// follows verbatim. PLY/SPZ parser code is vendored from
// nianticlabs/spz (src/cc/load-spz.* + splat-types.h).

struct ProjectedSplatLayout {
    float xy_x, xy_y;
    float conic_x, conic_y, conic_z;
    float color_r, color_g, color_b, color_a;
};
static_assert(sizeof(ProjectedSplatLayout) == 36, "matches WGSL ProjectedSplat");

struct RenderArgsStorage {
    float    viewmat[16];
    float    focal[2];
    uint32_t img_size[2];
    uint32_t tile_bounds[2];
    float    pixel_center[2];
    float    camera_position[4];
    uint32_t sh_degree;
    uint32_t num_visible;
    uint32_t total_splats;
    uint32_t max_intersects;
    float    background[4];
};
static_assert(sizeof(RenderArgsStorage) == 144, "matches WGSL RenderUniforms");

// Initial RenderUniforms shape with no splats loaded. Phase 6.4f's
// load_ply / load_spz path overwrites this with the loaded scene's
// counts + actual viewmat each frame.
RenderArgsStorage make_empty_uniforms(std::uint32_t w, std::uint32_t h) {
    RenderArgsStorage u{};
    u.viewmat[0] = 1.0f; u.viewmat[5] = 1.0f;
    u.viewmat[10] = 1.0f; u.viewmat[15] = 1.0f;
    u.focal[0] = static_cast<float>(w);
    u.focal[1] = static_cast<float>(h);
    u.img_size[0] = w;
    u.img_size[1] = h;
    u.tile_bounds[0] = w / 16; u.tile_bounds[1] = h / 16;
    u.pixel_center[0] = static_cast<float>(w) / 2.0f;
    u.pixel_center[1] = static_cast<float>(h) / 2.0f;
    u.sh_degree = 0;
    u.num_visible = 0;
    u.total_splats = 0;
    u.max_intersects = 1024;
    u.background[3] = 1.0f;
    return u;
}

// ─── Mesh-pipeline uniform structs (match mesh_render.wgsl) ────────────

struct CameraUniforms {        // size 80 bytes, aligned 16
    float view_proj[16];
    float camera_pos[4];
};
struct ModelTransform {        // size 128 bytes
    float model[16];
    float normal_mat[16];
};
struct LightUniforms {         // size 48 bytes
    float direction[4];
    float color[4];
    float intensity;
    float _pad[3];
};
struct PbrFactorsUniforms {    // size 48 bytes
    float base_color[4];
    float metallic_roughness[2];
    float occlusion_strength;
    float _pad;
    float emissive[3];
    float _pad2;
};

// ─── 4×4 matrix helpers ────────────────────────────────────────────────
//
// Column-major (matches Float32List from Dart's vector_math).
// We avoid pulling glm to keep aether3d_core dep-light.

void mat4_mul(float out[16], const float a[16], const float b[16]) {
    for (int c = 0; c < 4; ++c) {
        for (int r = 0; r < 4; ++r) {
            float sum = 0;
            for (int k = 0; k < 4; ++k) {
                sum += a[k * 4 + r] * b[c * 4 + k];
            }
            out[c * 4 + r] = sum;
        }
    }
}

void mat4_perspective(float out[16], float fovy_rad, float aspect,
                       float near, float far) {
    const float f = 1.0f / std::tan(fovy_rad * 0.5f);
    std::memset(out, 0, sizeof(float) * 16);
    out[0]  = f / aspect;
    out[5]  = f;
    out[10] = far / (near - far);
    out[11] = -1.0f;
    out[14] = (near * far) / (near - far);
}

void mat4_inverse_3x3_transpose(float out[16], const float m[16]) {
    // For uniform-scale model matrices the inverse-transpose of the
    // upper-left 3x3 equals the rotation part. For simplicity (and
    // because our model matrices are translate + rotate + uniform-scale)
    // we compute it properly via cofactors. mat3 inverse-transpose.
    const float a = m[0], b = m[1], c = m[2];
    const float d = m[4], e = m[5], f = m[6];
    const float g = m[8], h = m[9], i = m[10];
    const float A =  (e * i - f * h);
    const float B = -(d * i - f * g);
    const float C =  (d * h - e * g);
    const float D = -(b * i - c * h);
    const float E =  (a * i - c * g);
    const float F = -(a * h - b * g);
    const float G =  (b * f - c * e);
    const float H = -(a * f - c * d);
    const float I =  (a * e - b * d);
    const float det = a * A + b * B + c * C;
    const float inv_det = (det != 0.0f) ? (1.0f / det) : 0.0f;
    std::memset(out, 0, sizeof(float) * 16);
    out[0]  = A * inv_det;
    out[1]  = B * inv_det;
    out[2]  = C * inv_det;
    out[4]  = D * inv_det;
    out[5]  = E * inv_det;
    out[6]  = F * inv_det;
    out[8]  = G * inv_det;
    out[9]  = H * inv_det;
    out[10] = I * inv_det;
    out[15] = 1.0f;
}

// ─── 1x1 fallback texture creation ─────────────────────────────────────
//
// glTF materials may omit any subset of the 5 PBR textures. Instead of
// branching the WGSL on "binding present" (which would require multiple
// pipelines), we always bind 5 textures + 1 sampler, using small 1x1
// constant-value textures for missing slots. Filament + glTF reference
// renderers do the same.

GPUTextureHandle create_1x1_texture(GPUDevice& device,
                                     std::uint8_t r, std::uint8_t g,
                                     std::uint8_t b, std::uint8_t a,
                                     const char* label) {
    GPUTextureDesc desc{};
    desc.width = 1;
    desc.height = 1;
    desc.depth = 1;
    desc.mip_levels = 1;
    desc.format = GPUTextureFormat::kRGBA8Unorm;
    desc.usage_mask = static_cast<std::uint8_t>(GPUTextureUsage::kShaderRead);
    desc.label = label;
    GPUTextureHandle h = device.create_texture(desc);
    if (!h.valid()) return GPUTextureHandle{0};
    const std::uint8_t pixel[4] = {r, g, b, a};
    device.update_texture(h, pixel, 1, 1, /*bytes_per_row=*/4);
    return h;
}

// ─── Mesh render pipeline + bind group layout (Dawn-direct) ────────────

// Build the bind group layout for mesh_render.wgsl. 10 entries:
//   0: uniform Camera           (vertex + fragment)
//   1: uniform ModelTransform   (vertex)
//   2: uniform Light            (fragment)
//   3: uniform PbrFactors       (fragment)
//   4: texture base_color       (fragment, float, 2D)
//   5: sampler pbr_sampler      (fragment, filtering)
//   6: texture mr               (fragment)
//   7: texture normal           (fragment)
//   8: texture occlusion        (fragment)
//   9: texture emissive         (fragment)
//
// We let Dawn auto-derive this layout from the WGSL during pipeline
// creation (passing nullptr for the explicit layout). Same convention
// as splat_render.

// Build the explicit BindGroupLayout for mesh_render.wgsl. Mirrors the
// 10 `@group(0) @binding(N)` declarations in the shader and the 10
// entries built in encode_mesh_pass. Visibility flags follow the
// shader's actual usage:
//   • binding 0 (camera)      — vertex (view_proj) + fragment (camera_pos)
//   • binding 1 (model_xform) — vertex (model + normal_mat)
//   • binding 2 (light)       — fragment (lit-mode BRDF; unused in
//                               unlit but kept so the layout is stable
//                               across modes)
//   • binding 3 (pbr_factors) — fragment (base color factor, etc.)
//   • bindings 4,6,7,8,9      — fragment textures
//   • binding 5 (sampler)     — fragment
WGPUBindGroupLayout create_mesh_bind_group_layout(WGPUDevice wd) {
    WGPUBindGroupLayoutEntry entries[10] = {};

    auto fill_uniform = [](WGPUBindGroupLayoutEntry& e,
                           uint32_t binding,
                           WGPUShaderStage visibility) {
        e.binding = binding;
        e.visibility = visibility;
        e.buffer.type = WGPUBufferBindingType_Uniform;
        e.buffer.hasDynamicOffset = WGPU_FALSE;
        e.buffer.minBindingSize = 0;
    };
    auto fill_texture = [](WGPUBindGroupLayoutEntry& e, uint32_t binding) {
        e.binding = binding;
        e.visibility = WGPUShaderStage_Fragment;
        e.texture.sampleType = WGPUTextureSampleType_Float;
        e.texture.viewDimension = WGPUTextureViewDimension_2D;
        e.texture.multisampled = WGPU_FALSE;
    };
    auto fill_sampler = [](WGPUBindGroupLayoutEntry& e, uint32_t binding) {
        e.binding = binding;
        e.visibility = WGPUShaderStage_Fragment;
        e.sampler.type = WGPUSamplerBindingType_Filtering;
    };

    fill_uniform(entries[0], 0,
                 WGPUShaderStage_Vertex | WGPUShaderStage_Fragment);
    fill_uniform(entries[1], 1, WGPUShaderStage_Vertex);
    fill_uniform(entries[2], 2, WGPUShaderStage_Fragment);
    fill_uniform(entries[3], 3, WGPUShaderStage_Fragment);
    fill_texture(entries[4], 4);
    fill_sampler(entries[5], 5);
    fill_texture(entries[6], 6);
    fill_texture(entries[7], 7);
    fill_texture(entries[8], 8);
    fill_texture(entries[9], 9);

    WGPUBindGroupLayoutDescriptor desc = WGPU_BIND_GROUP_LAYOUT_DESCRIPTOR_INIT;
    desc.entryCount = 10;
    desc.entries = entries;
    return wgpuDeviceCreateBindGroupLayout(wd, &desc);
}

WGPURenderPipeline create_mesh_pipeline(WGPUDevice wd,
                                         WGPUShaderModule vs,
                                         WGPUShaderModule fs,
                                         WGPUTextureFormat color_format,
                                         WGPUPipelineLayout pipeline_layout) {
    // ─── Vertex buffer layout (matches glb_loader::MeshVertex 48 bytes) ───
    static const WGPUVertexAttribute kAttrs[4] = {
        // position
        { /*nextInChain*/ nullptr,
          /*format*/ WGPUVertexFormat_Float32x3,
          /*offset*/ 0,
          /*shaderLocation*/ 0 },
        // normal
        { nullptr, WGPUVertexFormat_Float32x3, 12, 1 },
        // uv
        { nullptr, WGPUVertexFormat_Float32x2, 24, 2 },
        // tangent
        { nullptr, WGPUVertexFormat_Float32x4, 32, 3 },
    };
    WGPUVertexBufferLayout vbl = WGPU_VERTEX_BUFFER_LAYOUT_INIT;
    vbl.arrayStride = 48;
    vbl.stepMode = WGPUVertexStepMode_Vertex;
    vbl.attributeCount = 4;
    vbl.attributes = kAttrs;

    WGPUVertexState vertex = WGPU_VERTEX_STATE_INIT;
    vertex.module = vs;
    vertex.entryPoint = WGPUStringView{"vs_main", WGPU_STRLEN};
    vertex.bufferCount = 1;
    vertex.buffers = &vbl;

    // ─── Color target + blend (premultiplied alpha) ────────────────────
    // Premultiplied "over" blend so glTF materials with alphaMode=BLEND
    // (e.g. Khronos ToyCar's contact shadow plane, Corset's ground
    // plane) composite correctly on top of opaque draws below them.
    // Without this, translucent fragments OVERWRITE the framebuffer
    // RGB outright — the user's "ToyCar 下方一坨纯黑 puddle" + chess
    // board upper-left dark blob were exactly this: shadow planes
    // with rgb=black and alpha=variable rendering as opaque-looking
    // black blobs because alpha was carried through but RGB wasn't
    // mixed.
    //
    // Pipeline math: dst = src.rgb * 1 + dst.rgb * (1 - src.a)
    //                       (premul rgb)
    // Shader cooperation: fragment outputs `vec4f(rgb * a, a)` so the
    // src.rgb above already has alpha pre-baked in.
    //
    // For opaque draws (a=1), this reduces to straight overwrite:
    // dst = src*1 + dst*0 = src — same as no-blend.
    WGPUBlendState blend = WGPU_BLEND_STATE_INIT;
    blend.color.operation = WGPUBlendOperation_Add;
    blend.color.srcFactor = WGPUBlendFactor_One;
    blend.color.dstFactor = WGPUBlendFactor_OneMinusSrcAlpha;
    blend.alpha.operation = WGPUBlendOperation_Add;
    blend.alpha.srcFactor = WGPUBlendFactor_One;
    blend.alpha.dstFactor = WGPUBlendFactor_OneMinusSrcAlpha;

    WGPUColorTargetState color_target = WGPU_COLOR_TARGET_STATE_INIT;
    color_target.format = color_format;
    color_target.writeMask = WGPUColorWriteMask_All;
    color_target.blend = &blend;

    WGPUFragmentState fragment = WGPU_FRAGMENT_STATE_INIT;
    fragment.module = fs;
    fragment.entryPoint = WGPUStringView{"fs_main", WGPU_STRLEN};
    fragment.targetCount = 1;
    fragment.targets = &color_target;

    // ─── Depth-stencil: write depth, less-or-equal compare ─────────────
    WGPUDepthStencilState depth = WGPU_DEPTH_STENCIL_STATE_INIT;
    depth.format = WGPUTextureFormat_Depth32Float;
    depth.depthWriteEnabled = WGPUOptionalBool_True;
    depth.depthCompare = WGPUCompareFunction_LessEqual;

    WGPURenderPipelineDescriptor desc = WGPU_RENDER_PIPELINE_DESCRIPTOR_INIT;
    desc.layout = pipeline_layout;  // explicit layout (vs auto)
    desc.vertex = vertex;
    desc.fragment = &fragment;
    desc.primitive.topology = WGPUPrimitiveTopology_TriangleList;
    desc.primitive.cullMode = WGPUCullMode_Back;
    // glTF convention: counter-clockwise = front face.
    desc.primitive.frontFace = WGPUFrontFace_CCW;
    desc.depthStencil = &depth;
    desc.multisample.count = 1;
    desc.multisample.mask = 0xFFFFFFFFu;

    return wgpuDeviceCreateRenderPipeline(wd, &desc);
}

// Splat overlay pipeline — premultiplied alpha blend, no depth write
// but with depth-test enabled (read from pass 1) + no depth write.
WGPURenderPipeline create_splat_overlay_pipeline(WGPUDevice wd,
                                                  WGPUShaderModule vs,
                                                  WGPUShaderModule fs,
                                                  WGPUTextureFormat color_format) {
    WGPUBlendState blend = WGPU_BLEND_STATE_INIT;
    blend.color.operation = WGPUBlendOperation_Add;
    blend.color.srcFactor = WGPUBlendFactor_One;
    blend.color.dstFactor = WGPUBlendFactor_OneMinusSrcAlpha;
    blend.alpha.operation = WGPUBlendOperation_Add;
    blend.alpha.srcFactor = WGPUBlendFactor_One;
    blend.alpha.dstFactor = WGPUBlendFactor_OneMinusSrcAlpha;

    WGPUColorTargetState color_target = WGPU_COLOR_TARGET_STATE_INIT;
    color_target.format = color_format;
    color_target.blend = &blend;
    color_target.writeMask = WGPUColorWriteMask_All;

    WGPUFragmentState fragment = WGPU_FRAGMENT_STATE_INIT;
    fragment.module = fs;
    fragment.entryPoint = WGPUStringView{"fs_main", WGPU_STRLEN};
    fragment.targetCount = 1;
    fragment.targets = &color_target;

    WGPUVertexState vertex = WGPU_VERTEX_STATE_INIT;
    vertex.module = vs;
    vertex.entryPoint = WGPUStringView{"vs_main", WGPU_STRLEN};
    vertex.bufferCount = 0;  // splat_render reads from storage, no vertex buffer

    // Depth: read-only test (so splats hidden behind mesh are clipped).
    WGPUDepthStencilState depth = WGPU_DEPTH_STENCIL_STATE_INIT;
    depth.format = WGPUTextureFormat_Depth32Float;
    depth.depthWriteEnabled = WGPUOptionalBool_False;
    depth.depthCompare = WGPUCompareFunction_LessEqual;

    WGPURenderPipelineDescriptor desc = WGPU_RENDER_PIPELINE_DESCRIPTOR_INIT;
    desc.vertex = vertex;
    desc.fragment = &fragment;
    desc.primitive.topology = WGPUPrimitiveTopology_TriangleList;
    desc.primitive.cullMode = WGPUCullMode_None;
    desc.primitive.frontFace = WGPUFrontFace_CCW;
    desc.depthStencil = &depth;
    desc.multisample.count = 1;
    desc.multisample.mask = 0xFFFFFFFFu;

    return wgpuDeviceCreateRenderPipeline(wd, &desc);
}

// ─── Default sampler ───────────────────────────────────────────────────
WGPUSampler create_default_sampler(WGPUDevice wd) {
    WGPUSamplerDescriptor s = WGPU_SAMPLER_DESCRIPTOR_INIT;
    s.addressModeU = WGPUAddressMode_Repeat;
    s.addressModeV = WGPUAddressMode_Repeat;
    s.addressModeW = WGPUAddressMode_Repeat;
    s.magFilter = WGPUFilterMode_Linear;
    s.minFilter = WGPUFilterMode_Linear;
    s.mipmapFilter = WGPUMipmapFilterMode_Linear;
    s.lodMinClamp = 0;
    s.lodMaxClamp = 1.0f;  // single mip
    s.compare = WGPUCompareFunction_Undefined;
    s.maxAnisotropy = 1;
    return wgpuDeviceCreateSampler(wd, &s);
}

}  // namespace (close the original anon namespace before SplatScene block)

// ═══════════════════════════════════════════════════════════════════════
// Phase 6.4f — SplatScene (Brush 8-kernel GPU splat pipeline)
// ═══════════════════════════════════════════════════════════════════════
//
// Holds parsed PLY/SPZ data on the GPU plus the compute pipelines that
// orchestrate Brush's project_forward → project_visible → splat_render
// chain. The full Brush pipeline includes 5 sort kernels +
// map_gaussian_to_intersects between project_visible and the rasterizer
// (back-to-front depth ordering for correct alpha compositing under tile
// binning). This first cut runs the 2 projection kernels + the
// vert+frag splat_render path WITHOUT the depth sort — splats render
// in atomic-write order from project_forward, which produces correct
// silhouettes but minor transparency artifacts on overlapping splats.
// The sort chain is a follow-up commit (PHASE_BACKLOG.md Phase 6.4f.2).
//
// Bind layouts must match the WGSL generated from
// shaders/wgsl/_brush_raw/* through scripts/wgsl_preprocess (Path G).
// If naga-oil regenerates shaders with different binding orders, this
// file's bind groups will go out of sync — check WGSL bindings vs the
// builders below if validation errors mention "binding count mismatch".

namespace {

// SH_C0 = 1/(2*sqrt(pi)) — DC band coefficient. PLY's f_dc_* values are
// stored as raw SH coefficients; aether::splat::load_ply already
// unpacks them to linear RGB via `c = sh0 * SH_C0 + 0.5`. To feed the
// project_visible kernel (which re-applies that formula) we need to
// undo the unpack: `sh0 = (c - 0.5) / SH_C0`.
constexpr float kSH_C0 = 0.28209479177387814f;
constexpr float kInvSH_C0 = 1.0f / kSH_C0;

// Number of SH coefficients per channel for a given degree.
// degree 0 → 1 (DC), 1 → 4, 2 → 9, 3 → 16. For PocketWorld scenes we
// currently load DC-only (degree 0); higher orders are a follow-up.
inline std::uint32_t sh_coeff_count(std::uint32_t degree) noexcept {
    return (degree + 1u) * (degree + 1u);
}

// ─── Phase 6.4f.3.c — refcount-shared splat data ───────────────────────
//
// The packed_splats_buf + coeffs_non_dc_buf hold every splat's
// position/rotation/scale/color/opacity/SH-non-DC. Those bytes are
// *load-time invariant*: once we've packed the file, multiple cards
// rendering the same scene (feed thumbnail + detail-page modal,
// repeated cards in a viewport) want to share the same GPU bytes
// rather than re-packing and re-uploading.
//
// `SplatData` owns the GPU buffers and a back-pointer to the device so
// the destructor can free them when the last reference goes away.
// `SplatScene` holds a `shared_ptr<SplatData>` plus per-renderer state
// (bind groups bound to a specific renderer's uniforms_buf, sort
// scratch buffers — those CANNOT be shared because their contents
// are per-frame dynamic).
//
// `SplatDataCache` is a process-wide weak_ptr cache keyed on
// "path|max_splats|max_sh_degree". When a renderer asks to load a
// scene that's already in flight elsewhere, it gets back the existing
// `shared_ptr` and skips the entire pack-and-upload phase. The cache
// uses weak_ptrs so freed scenes auto-evict; a periodic dead-entry
// sweep keeps the table from growing unbounded.
struct SplatData {
    ::aether::render::GPUDevice* device{nullptr};
    GPUBufferHandle packed_splats_buf;
    GPUBufferHandle coeffs_non_dc_buf;
    std::uint32_t num_splats{0};
    std::uint32_t sh_degree{0};
    float bounds_min[3]{0.0f, 0.0f, 0.0f};
    float bounds_max[3]{0.0f, 0.0f, 0.0f};

    SplatData() = default;
    SplatData(const SplatData&) = delete;
    SplatData& operator=(const SplatData&) = delete;
    ~SplatData() {
        if (device) {
            if (coeffs_non_dc_buf.valid()) device->destroy_buffer(coeffs_non_dc_buf);
            if (packed_splats_buf.valid()) device->destroy_buffer(packed_splats_buf);
        }
    }
};

class SplatDataCache {
public:
    std::shared_ptr<SplatData> get(const std::string& key) {
        std::lock_guard<std::mutex> lk(mu_);
        auto it = entries_.find(key);
        if (it == entries_.end()) return nullptr;
        if (auto sp = it->second.lock()) return sp;
        entries_.erase(it);
        return nullptr;
    }
    void put(const std::string& key, std::shared_ptr<SplatData> data) {
        std::lock_guard<std::mutex> lk(mu_);
        entries_[key] = data;
        // Sweep expired weak refs when the table grows; cheap O(N) walk
        // amortized across loads. 64 is arbitrary — picked so the sweep
        // runs once per ~screen of cards, not on every reload.
        if (entries_.size() > 64u) {
            for (auto i = entries_.begin(); i != entries_.end();) {
                if (i->second.expired()) i = entries_.erase(i);
                else ++i;
            }
        }
    }
    static SplatDataCache& instance() {
        static SplatDataCache s;
        return s;
    }
private:
    std::mutex mu_;
    std::unordered_map<std::string, std::weak_ptr<SplatData>> entries_;
};

struct SplatScene {
    std::shared_ptr<SplatData> data;      // shared GPU data buffers (Phase 6.4f.3.c)
    std::uint32_t num_splats{0};          // mirror of data->num_splats
    std::uint32_t sh_degree{0};           // mirror of data->sh_degree
    float bounds_min[3]{0.0f, 0.0f, 0.0f};
    float bounds_max[3]{0.0f, 0.0f, 0.0f};

    // ─── Phase 6.4f.3.a — packed 16-byte splat buffer ──────────────────
    // Mirrored from `data->packed_splats_buf` so the bind-group / encode
    // paths don't need to dereference `data` on every access. Same handle
    // value, but the lifetime is owned by `data`.
    GPUBufferHandle packed_splats_buf;
    GPUBufferHandle coeffs_non_dc_buf;

    // Per-frame intermediate (written by project_forward, read by project_visible).
    GPUBufferHandle global_from_compact_gid_buf;  // u32[N]
    GPUBufferHandle depths_buf;                   // f32[N]
    // projected_splats_buf reuses AetherSceneRenderer::splats_buf — sized
    // to N * sizeof(ProjectedSplat) at load time, written by
    // project_visible, read by splat_render.

    // ─── Phase 6.4f.2.a — depth-sort buffers (5-kernel radix sort) ─────
    //
    // Per-splat back-to-front sort. After project_visible writes
    // ProjectedSplat[N_visible], sort_prep_depth seeds:
    //     keys[i]   = ~bitcast<u32>(depths[i])  for i < num_visible
    //                 = 0xFFFFFFFFu              otherwise
    //     values[i] = i (compact_gid)
    // Then 8 passes (4 bits × 8 = 32-bit key) of
    //     count → reduce → scan → scan_add → scatter
    // ping-pong between (keys/values) and (keys_alt/values_alt). The
    // last (8th) pass writes to keys/values, so the final ascending
    // sort reads splats[values[ii]] for back-to-front order.
    GPUBufferHandle sort_keys_buf;
    GPUBufferHandle sort_keys_alt_buf;
    GPUBufferHandle sort_values_buf;
    GPUBufferHandle sort_values_alt_buf;
    GPUBufferHandle sort_counts_buf;             // u32[16 * num_blocks]
    GPUBufferHandle sort_reduced_buf;            // u32[16 * num_reduce_groups]
    GPUBufferHandle sort_num_keys_arr_buf;       // u32[1] = num_visible
    GPUBufferHandle sort_config_bufs[8];         // 8 × u32{shift = pass*4}

    std::uint32_t sort_num_blocks{0};            // ceil(num_splats / 1024)
    std::uint32_t sort_num_reduce_groups{0};     // ceil(num_blocks / 1024)

    // Compute pipelines (built once on first load).
    WGPUComputePipeline project_forward_pipe{nullptr};
    WGPUComputePipeline project_visible_pipe{nullptr};
    WGPUComputePipeline sort_prep_pipe{nullptr};
    WGPUComputePipeline sort_count_pipe{nullptr};
    WGPUComputePipeline sort_reduce_pipe{nullptr};
    WGPUComputePipeline sort_scan_pipe{nullptr};
    WGPUComputePipeline sort_scan_add_pipe{nullptr};
    WGPUComputePipeline sort_scatter_pipe{nullptr};
    WGPUBindGroupLayout project_forward_bgl{nullptr};
    WGPUBindGroupLayout project_visible_bgl{nullptr};
    WGPUBindGroupLayout sort_prep_bgl{nullptr};
    WGPUBindGroupLayout sort_count_bgl{nullptr};
    WGPUBindGroupLayout sort_reduce_bgl{nullptr};
    WGPUBindGroupLayout sort_scan_bgl{nullptr};
    WGPUBindGroupLayout sort_scan_add_bgl{nullptr};
    WGPUBindGroupLayout sort_scatter_bgl{nullptr};
    WGPUPipelineLayout project_forward_layout{nullptr};
    WGPUPipelineLayout project_visible_layout{nullptr};
    WGPUPipelineLayout sort_prep_layout{nullptr};
    WGPUPipelineLayout sort_count_layout{nullptr};
    WGPUPipelineLayout sort_reduce_layout{nullptr};
    WGPUPipelineLayout sort_scan_layout{nullptr};
    WGPUPipelineLayout sort_scan_add_layout{nullptr};
    WGPUPipelineLayout sort_scatter_layout{nullptr};

    // Bind groups (rebuilt at load — buffer handles are stable for the
    // lifetime of the SplatScene; the underlying contents change but
    // WGPUBindGroup references the buffer handle, not its data).
    WGPUBindGroup project_forward_bg{nullptr};
    WGPUBindGroup project_visible_bg{nullptr};
    WGPUBindGroup splat_render_bg{nullptr};
    WGPUBindGroup sort_prep_bg{nullptr};
    WGPUBindGroup sort_count_bgs[8]{};       // index = pass; alternates src=keys/keys_alt
    WGPUBindGroup sort_reduce_bg{nullptr};
    WGPUBindGroup sort_scan_bg{nullptr};
    WGPUBindGroup sort_scan_add_bg{nullptr};
    WGPUBindGroup sort_scatter_bgs[8]{};     // index = pass; alternates src/out
};

// ─── BindGroupLayout builders for the 2 compute kernels ────────────────
//
// project_forward.wgsl bind group (Phase 6.4f.3.a — packed format):
//   0: storage,read_write RenderUniforms (atomic num_visible)
//   1: storage,read       packed_splats (vec4<u32>[N] = 16 B/splat)
//   2: storage,read_write global_from_compact_gid
//   3: storage,read_write depths
WGPUBindGroupLayout create_project_forward_bgl(WGPUDevice wd) {
    WGPUBindGroupLayoutEntry entries[4] = {};
    auto fill = [](WGPUBindGroupLayoutEntry& e, uint32_t binding,
                   WGPUBufferBindingType type) {
        e.binding = binding;
        e.visibility = WGPUShaderStage_Compute;
        e.buffer.type = type;
        e.buffer.hasDynamicOffset = WGPU_FALSE;
        e.buffer.minBindingSize = 0;
    };
    fill(entries[0], 0, WGPUBufferBindingType_Storage);            // uniforms (atomic)
    fill(entries[1], 1, WGPUBufferBindingType_ReadOnlyStorage);    // packed_splats
    fill(entries[2], 2, WGPUBufferBindingType_Storage);            // gid out
    fill(entries[3], 3, WGPUBufferBindingType_Storage);            // depths out
    WGPUBindGroupLayoutDescriptor desc = WGPU_BIND_GROUP_LAYOUT_DESCRIPTOR_INIT;
    desc.entryCount = 4;
    desc.entries = entries;
    return wgpuDeviceCreateBindGroupLayout(wd, &desc);
}

// project_visible.wgsl bind group (Phase 6.4f.3.a — packed format):
//   0: storage,read_write RenderUniforms (atomic load only)
//   1: storage,read       packed_splats (vec4<u32>[N])
//   2: storage,read       coeffs_non_dc (PackedVec3[N * num_non_dc] for SH degree 1+)
//                         Bound to a 1-element placeholder buffer when degree=0.
//   3: storage,read       global_from_compact_gid
//   4: storage,read_write projected
WGPUBindGroupLayout create_project_visible_bgl(WGPUDevice wd) {
    WGPUBindGroupLayoutEntry entries[5] = {};
    auto fill = [](WGPUBindGroupLayoutEntry& e, uint32_t binding,
                   WGPUBufferBindingType type) {
        e.binding = binding;
        e.visibility = WGPUShaderStage_Compute;
        e.buffer.type = type;
        e.buffer.hasDynamicOffset = WGPU_FALSE;
        e.buffer.minBindingSize = 0;
    };
    fill(entries[0], 0, WGPUBufferBindingType_Storage);            // uniforms (atomicLoad)
    fill(entries[1], 1, WGPUBufferBindingType_ReadOnlyStorage);    // packed_splats
    fill(entries[2], 2, WGPUBufferBindingType_ReadOnlyStorage);    // coeffs_non_dc
    fill(entries[3], 3, WGPUBufferBindingType_ReadOnlyStorage);    // gid in
    fill(entries[4], 4, WGPUBufferBindingType_Storage);            // projected out
    WGPUBindGroupLayoutDescriptor desc = WGPU_BIND_GROUP_LAYOUT_DESCRIPTOR_INIT;
    desc.entryCount = 5;
    desc.entries = entries;
    return wgpuDeviceCreateBindGroupLayout(wd, &desc);
}

// splat_render.wgsl bind group (vert+frag):
//   0: storage,read RenderUniforms
//   1: storage,read projected
//   2: storage,read order  (Phase 6.4f.2 sort permutation)
WGPUBindGroupLayout create_splat_render_bgl(WGPUDevice wd) {
    WGPUBindGroupLayoutEntry entries[3] = {};
    auto fill = [](WGPUBindGroupLayoutEntry& e, uint32_t binding) {
        e.binding = binding;
        e.visibility = WGPUShaderStage_Vertex | WGPUShaderStage_Fragment;
        e.buffer.type = WGPUBufferBindingType_ReadOnlyStorage;
        e.buffer.hasDynamicOffset = WGPU_FALSE;
        e.buffer.minBindingSize = 0;
    };
    fill(entries[0], 0);
    fill(entries[1], 1);
    fill(entries[2], 2);
    WGPUBindGroupLayoutDescriptor desc = WGPU_BIND_GROUP_LAYOUT_DESCRIPTOR_INIT;
    desc.entryCount = 3;
    desc.entries = entries;
    return wgpuDeviceCreateBindGroupLayout(wd, &desc);
}

// ─── Phase 6.4f.2.a — sort BGL builders (per-pass ping-pong) ───────────
//
// sort_prep_depth.wgsl:
//   0: storage,read       uniforms
//   1: storage,read       depths (f32[N])
//   2: storage,read_write num_keys_arr (u32[1])
//   3: storage,read_write keys (u32[N])
//   4: storage,read_write values (u32[N])
WGPUBindGroupLayout create_sort_prep_bgl(WGPUDevice wd) {
    WGPUBindGroupLayoutEntry entries[5] = {};
    auto fill = [](WGPUBindGroupLayoutEntry& e, uint32_t binding,
                   WGPUBufferBindingType type) {
        e.binding = binding;
        e.visibility = WGPUShaderStage_Compute;
        e.buffer.type = type;
        e.buffer.hasDynamicOffset = WGPU_FALSE;
        e.buffer.minBindingSize = 0;
    };
    fill(entries[0], 0, WGPUBufferBindingType_ReadOnlyStorage);
    fill(entries[1], 1, WGPUBufferBindingType_ReadOnlyStorage);
    fill(entries[2], 2, WGPUBufferBindingType_Storage);
    fill(entries[3], 3, WGPUBufferBindingType_Storage);
    fill(entries[4], 4, WGPUBufferBindingType_Storage);
    WGPUBindGroupLayoutDescriptor desc = WGPU_BIND_GROUP_LAYOUT_DESCRIPTOR_INIT;
    desc.entryCount = 5;
    desc.entries = entries;
    return wgpuDeviceCreateBindGroupLayout(wd, &desc);
}

// sort_count.wgsl:
//   0: storage,read       config (shift)
//   1: storage,read       num_keys_arr
//   2: storage,read       src (keys, alternates)
//   3: storage,read_write counts
WGPUBindGroupLayout create_sort_count_bgl(WGPUDevice wd) {
    WGPUBindGroupLayoutEntry entries[4] = {};
    auto fill = [](WGPUBindGroupLayoutEntry& e, uint32_t binding,
                   WGPUBufferBindingType type) {
        e.binding = binding;
        e.visibility = WGPUShaderStage_Compute;
        e.buffer.type = type;
        e.buffer.hasDynamicOffset = WGPU_FALSE;
        e.buffer.minBindingSize = 0;
    };
    fill(entries[0], 0, WGPUBufferBindingType_ReadOnlyStorage);
    fill(entries[1], 1, WGPUBufferBindingType_ReadOnlyStorage);
    fill(entries[2], 2, WGPUBufferBindingType_ReadOnlyStorage);
    fill(entries[3], 3, WGPUBufferBindingType_Storage);
    WGPUBindGroupLayoutDescriptor desc = WGPU_BIND_GROUP_LAYOUT_DESCRIPTOR_INIT;
    desc.entryCount = 4;
    desc.entries = entries;
    return wgpuDeviceCreateBindGroupLayout(wd, &desc);
}

// sort_reduce.wgsl:
//   0: storage,read       num_keys_arr
//   1: storage,read       counts
//   2: storage,read_write reduced
WGPUBindGroupLayout create_sort_reduce_bgl(WGPUDevice wd) {
    WGPUBindGroupLayoutEntry entries[3] = {};
    auto fill = [](WGPUBindGroupLayoutEntry& e, uint32_t binding,
                   WGPUBufferBindingType type) {
        e.binding = binding;
        e.visibility = WGPUShaderStage_Compute;
        e.buffer.type = type;
        e.buffer.hasDynamicOffset = WGPU_FALSE;
        e.buffer.minBindingSize = 0;
    };
    fill(entries[0], 0, WGPUBufferBindingType_ReadOnlyStorage);
    fill(entries[1], 1, WGPUBufferBindingType_ReadOnlyStorage);
    fill(entries[2], 2, WGPUBufferBindingType_Storage);
    WGPUBindGroupLayoutDescriptor desc = WGPU_BIND_GROUP_LAYOUT_DESCRIPTOR_INIT;
    desc.entryCount = 3;
    desc.entries = entries;
    return wgpuDeviceCreateBindGroupLayout(wd, &desc);
}

// sort_scan.wgsl:
//   0: storage,read       num_keys_arr
//   1: storage,read_write reduced
WGPUBindGroupLayout create_sort_scan_bgl(WGPUDevice wd) {
    WGPUBindGroupLayoutEntry entries[2] = {};
    auto fill = [](WGPUBindGroupLayoutEntry& e, uint32_t binding,
                   WGPUBufferBindingType type) {
        e.binding = binding;
        e.visibility = WGPUShaderStage_Compute;
        e.buffer.type = type;
        e.buffer.hasDynamicOffset = WGPU_FALSE;
        e.buffer.minBindingSize = 0;
    };
    fill(entries[0], 0, WGPUBufferBindingType_ReadOnlyStorage);
    fill(entries[1], 1, WGPUBufferBindingType_Storage);
    WGPUBindGroupLayoutDescriptor desc = WGPU_BIND_GROUP_LAYOUT_DESCRIPTOR_INIT;
    desc.entryCount = 2;
    desc.entries = entries;
    return wgpuDeviceCreateBindGroupLayout(wd, &desc);
}

// sort_scan_add.wgsl:
//   0: storage,read       num_keys_arr
//   1: storage,read       reduced
//   2: storage,read_write counts
WGPUBindGroupLayout create_sort_scan_add_bgl(WGPUDevice wd) {
    WGPUBindGroupLayoutEntry entries[3] = {};
    auto fill = [](WGPUBindGroupLayoutEntry& e, uint32_t binding,
                   WGPUBufferBindingType type) {
        e.binding = binding;
        e.visibility = WGPUShaderStage_Compute;
        e.buffer.type = type;
        e.buffer.hasDynamicOffset = WGPU_FALSE;
        e.buffer.minBindingSize = 0;
    };
    fill(entries[0], 0, WGPUBufferBindingType_ReadOnlyStorage);
    fill(entries[1], 1, WGPUBufferBindingType_ReadOnlyStorage);
    fill(entries[2], 2, WGPUBufferBindingType_Storage);
    WGPUBindGroupLayoutDescriptor desc = WGPU_BIND_GROUP_LAYOUT_DESCRIPTOR_INIT;
    desc.entryCount = 3;
    desc.entries = entries;
    return wgpuDeviceCreateBindGroupLayout(wd, &desc);
}

// sort_scatter.wgsl:
//   0: storage,read       config (shift)
//   1: storage,read       num_keys_arr
//   2: storage,read       src (keys)
//   3: storage,read       values
//   4: storage,read       counts
//   5: storage,read_write out
//   6: storage,read_write out_values
WGPUBindGroupLayout create_sort_scatter_bgl(WGPUDevice wd) {
    WGPUBindGroupLayoutEntry entries[7] = {};
    auto fill = [](WGPUBindGroupLayoutEntry& e, uint32_t binding,
                   WGPUBufferBindingType type) {
        e.binding = binding;
        e.visibility = WGPUShaderStage_Compute;
        e.buffer.type = type;
        e.buffer.hasDynamicOffset = WGPU_FALSE;
        e.buffer.minBindingSize = 0;
    };
    fill(entries[0], 0, WGPUBufferBindingType_ReadOnlyStorage);
    fill(entries[1], 1, WGPUBufferBindingType_ReadOnlyStorage);
    fill(entries[2], 2, WGPUBufferBindingType_ReadOnlyStorage);
    fill(entries[3], 3, WGPUBufferBindingType_ReadOnlyStorage);
    fill(entries[4], 4, WGPUBufferBindingType_ReadOnlyStorage);
    fill(entries[5], 5, WGPUBufferBindingType_Storage);
    fill(entries[6], 6, WGPUBufferBindingType_Storage);
    WGPUBindGroupLayoutDescriptor desc = WGPU_BIND_GROUP_LAYOUT_DESCRIPTOR_INIT;
    desc.entryCount = 7;
    desc.entries = entries;
    return wgpuDeviceCreateBindGroupLayout(wd, &desc);
}

WGPUComputePipeline create_compute_pipeline(WGPUDevice wd,
                                              WGPUShaderModule sm,
                                              WGPUPipelineLayout layout,
                                              const char* entry) {
    WGPUComputePipelineDescriptor desc = WGPU_COMPUTE_PIPELINE_DESCRIPTOR_INIT;
    desc.layout = layout;
    desc.compute.module = sm;
    desc.compute.entryPoint = WGPUStringView{entry, WGPU_STRLEN};
    return wgpuDeviceCreateComputePipeline(wd, &desc);
}

// Splat overlay pipeline rebuilt with explicit BindGroupLayout so we can
// bind the unified compute-shared splat_uniforms_buf + projected_splats_buf
// without going through Dawn auto-layout (which would synthesize a layout
// requiring exact storage/read access type matches).
WGPURenderPipeline create_splat_overlay_pipeline_explicit(
    WGPUDevice wd, WGPUShaderModule vs, WGPUShaderModule fs,
    WGPUTextureFormat color_format, WGPUPipelineLayout layout) {
    WGPUBlendState blend = WGPU_BLEND_STATE_INIT;
    blend.color.operation = WGPUBlendOperation_Add;
    blend.color.srcFactor = WGPUBlendFactor_One;
    blend.color.dstFactor = WGPUBlendFactor_OneMinusSrcAlpha;
    blend.alpha.operation = WGPUBlendOperation_Add;
    blend.alpha.srcFactor = WGPUBlendFactor_One;
    blend.alpha.dstFactor = WGPUBlendFactor_OneMinusSrcAlpha;

    WGPUColorTargetState color_target = WGPU_COLOR_TARGET_STATE_INIT;
    color_target.format = color_format;
    color_target.blend = &blend;
    color_target.writeMask = WGPUColorWriteMask_All;

    WGPUFragmentState fragment = WGPU_FRAGMENT_STATE_INIT;
    fragment.module = fs;
    fragment.entryPoint = WGPUStringView{"fs_main", WGPU_STRLEN};
    fragment.targetCount = 1;
    fragment.targets = &color_target;

    WGPUVertexState vertex = WGPU_VERTEX_STATE_INIT;
    vertex.module = vs;
    vertex.entryPoint = WGPUStringView{"vs_main", WGPU_STRLEN};
    vertex.bufferCount = 0;

    // Depth: read-only test (so splats hidden behind mesh are clipped).
    WGPUDepthStencilState depth = WGPU_DEPTH_STENCIL_STATE_INIT;
    depth.format = WGPUTextureFormat_Depth32Float;
    depth.depthWriteEnabled = WGPUOptionalBool_False;
    depth.depthCompare = WGPUCompareFunction_LessEqual;

    WGPURenderPipelineDescriptor desc = WGPU_RENDER_PIPELINE_DESCRIPTOR_INIT;
    desc.layout = layout;
    desc.vertex = vertex;
    desc.fragment = &fragment;
    desc.primitive.topology = WGPUPrimitiveTopology_TriangleList;
    desc.primitive.cullMode = WGPUCullMode_None;
    desc.primitive.frontFace = WGPUFrontFace_CCW;
    desc.depthStencil = &depth;
    desc.multisample.count = 1;
    desc.multisample.mask = 0xFFFFFFFFu;

    return wgpuDeviceCreateRenderPipeline(wd, &desc);
}

}  // namespace

// ═══════════════════════════════════════════════════════════════════════
// AetherSceneRenderer
// ═══════════════════════════════════════════════════════════════════════

struct AetherSceneRenderer {
    GPUDevice* device{nullptr};
    std::uint32_t width{0}, height{0};
    GPUTextureFormat color_format{GPUTextureFormat::kInvalid};

    // Render targets
    GPUTextureHandle iosurface_tex;
    GPUTextureHandle depth_tex;

    // Splat path (always bound, overlay)
    GPUBufferHandle splat_uniforms_buf;
    GPUBufferHandle splats_buf;        // ProjectedSplat[N] — output of project_visible
    GPUShaderHandle splat_vs, splat_fs;
    GPUShaderHandle project_forward_shader;  // compute kernel
    GPUShaderHandle project_visible_shader;  // compute kernel
    // Phase 6.4f.2.a: 6 sort kernels (5 brush radix + 1 aether prep).
    GPUShaderHandle sort_prep_shader;
    GPUShaderHandle sort_count_shader;
    GPUShaderHandle sort_reduce_shader;
    GPUShaderHandle sort_scan_shader;
    GPUShaderHandle sort_scan_add_shader;
    GPUShaderHandle sort_scatter_shader;
    WGPURenderPipeline splat_pipe{nullptr};
    WGPUBindGroupLayout splat_render_bgl{nullptr};
    WGPUPipelineLayout splat_render_layout{nullptr};

    // Splat scene (filled by load_ply / load_spz). When valid, render_full
    // dispatches the project_forward → project_visible → splat_render
    // chain each frame, gated on splat_scene.has_value().
    std::optional<SplatScene> splat_scene;

    // Mirrors splat_scene.has_value() for fast per-frame branching. Kept
    // separate so the per-frame hot path doesn't pay the optional check.
    bool has_splats{false};

    // Mesh path (filled by load_glb)
    bool has_mesh{false};
    std::optional<LoadedMesh> loaded_mesh;
    GPUBufferHandle mesh_camera_buf;
    GPUBufferHandle mesh_model_buf;
    GPUBufferHandle mesh_light_buf;
    GPUShaderHandle mesh_vs, mesh_fs;
    WGPURenderPipeline mesh_pipe{nullptr};
    WGPUSampler mesh_sampler{nullptr};
    // Explicit BindGroupLayout + PipelineLayout (vs Dawn's `auto` layout
    // inference). Owning these on the renderer instead of regenerating
    // them per frame from `wgpuRenderPipelineGetBindGroupLayout` lets
    // the BGL match the C++ encode_mesh_pass's 10-entry BindGroup
    // exactly, regardless of whether the WGSL fragment shader actually
    // references every binding (mesh_render.wgsl currently runs in
    // unlit mode and doesn't sample metallic_roughness / normal nor
    // read the Light uniform — `auto` would strip those, breaking
    // CreateBindGroup validation).
    WGPUBindGroupLayout mesh_bgl{nullptr};
    WGPUPipelineLayout mesh_pipeline_layout{nullptr};

    // ─── Mesh draw cache (Plan A perf fix, 2026-05-02) ─────────────────
    // Built once per load_glb, reused every frame. Stops encode_mesh_pass
    // from creating ~50 BindGroups + ~250 texture views per frame for a
    // multi-primitive GLB like the Khronos ToyCar (49 primitives × 5
    // textures + 1 BindGroup), which was the main thermal hotspot —
    // every entry in this cache used to be re-allocated and re-validated
    // by Dawn every frame. Per-frame work in encode_mesh_pass is now
    // just SetBindGroup + SetVertexBuffer + SetIndexBuffer + DrawIndexed
    // per primitive; zero allocations, zero validation.
    //
    // - material_factors_bufs: ONE uniform buffer per material, written
    //   ONCE at load time. Previously a single shared mesh_factors_buf
    //   was overwritten 49 times per frame, serializing all draw calls
    //   on the buffer's update.
    // - material_texture_views: 5 views per material (base / mr / normal
    //   / occlusion / emissive), kept alive for the lifetime of the
    //   loaded mesh. Texture views were the largest per-frame Metal
    //   object churn.
    // - primitive_bind_groups: ONE BindGroup per primitive, references
    //   the renderer's camera/model/light buffers + the material's
    //   factors buffer + texture views.
    std::vector<GPUBufferHandle> material_factors_bufs;
    std::vector<WGPUTextureView> material_texture_views;  // 5 per material
    std::vector<WGPUBindGroup> primitive_bind_groups;

    // 1x1 fallback textures for missing PBR slots.
    GPUTextureHandle fallback_white;
    GPUTextureHandle fallback_flat_normal;
    GPUTextureHandle fallback_black;
};

// Forward decls — definitions follow aether_scene_renderer_destroy
// because both destroy and load_glb (the actual call sites) live above
// the implementations.
static void free_mesh_draw_cache(AetherSceneRenderer* r);
static bool build_mesh_draw_cache(AetherSceneRenderer* r);
static void free_splat_scene(AetherSceneRenderer* r);

// encode_splat_pass deleted 2026-05-02 (Phase 6.4f stub stage).
//
// The previous overlay-style render pass drew the kBaselineSplats
// debug fixture and was the source of the "上方暗光斑" user bug.
// The real splat path lands in Phase 6.4f's full implementation,
// which dispatches the 8-kernel Brush compute chain (project_forward
// → project_visible → map_gaussian_to_intersects → sort × 5 →
// splat_render) per frame, gated on `r->has_splats`. The render
// pipeline + shaders + sampler are still allocated at create time
// so 6.4f's implementation only needs to add the storage buffers
// and dispatch chain.

// Helper: encode the mesh render pass.
static void encode_mesh_pass(WGPUCommandEncoder encoder,
                              WGPUTextureView color_view,
                              WGPUTextureView depth_view,
                              AetherSceneRenderer* r) {
    using namespace ::aether::render;
    auto& dev = *(r->device);
    if (!is_dawn(&dev)) return;
    LoadedMesh& mesh = *r->loaded_mesh;
    if (mesh.primitives.empty()) return;

    WGPURenderPassColorAttachment color_attach = WGPU_RENDER_PASS_COLOR_ATTACHMENT_INIT;
    color_attach.view = color_view;
    color_attach.loadOp = WGPULoadOp_Clear;
    color_attach.storeOp = WGPUStoreOp_Store;
    // Transparent clear so the Flutter widget.background color shows
    // through behind the model. Pre-G4 cards shipped on thermion which
    // also wrote alpha=0 around the model; matching that lets the
    // PostCard's outer `ColoredBox(color: widget.background)` (white
    // by default) be the visible background, not the renderer's
    // hardcoded clear color. The mesh fragment shader still writes
    // alpha=base_color.a (≈1 for opaque materials), so the model
    // silhouette stays opaque against the transparent surround.
    color_attach.clearValue = {0.0, 0.0, 0.0, 0.0};
    color_attach.depthSlice = WGPU_DEPTH_SLICE_UNDEFINED;

    WGPURenderPassDepthStencilAttachment depth_attach =
        WGPU_RENDER_PASS_DEPTH_STENCIL_ATTACHMENT_INIT;
    depth_attach.view = depth_view;
    depth_attach.depthLoadOp = WGPULoadOp_Clear;
    depth_attach.depthClearValue = 1.0f;
    depth_attach.depthStoreOp = WGPUStoreOp_Store;
    depth_attach.depthReadOnly = WGPU_FALSE;

    WGPURenderPassDescriptor pass_desc = WGPU_RENDER_PASS_DESCRIPTOR_INIT;
    pass_desc.colorAttachmentCount = 1;
    pass_desc.colorAttachments = &color_attach;
    pass_desc.depthStencilAttachment = &depth_attach;

    WGPURenderPassEncoder pass = wgpuCommandEncoderBeginRenderPass(encoder, &pass_desc);
    wgpuRenderPassEncoderSetPipeline(pass, r->mesh_pipe);

    // Plan-A perf fix: BindGroups + texture views + per-material factor
    // buffers are now built ONCE in aether_scene_renderer_load_glb (see
    // build_mesh_draw_cache). encode_mesh_pass does zero allocations
    // and zero validation per frame — just SetBindGroup +
    // SetVertexBuffer + SetIndexBuffer + DrawIndexed per primitive.
    //
    // Sanity check: cache size MUST match primitive count. If load_glb
    // partially failed and somehow left the renderer with a mismatched
    // cache, fall through silently — the next load_glb call will
    // rebuild correctly. (We could log, but at frame rate.)
    if (r->primitive_bind_groups.size() != mesh.primitives.size()) {
        wgpuRenderPassEncoderEnd(pass);
        wgpuRenderPassEncoderRelease(pass);
        return;
    }

    for (std::size_t i = 0; i < mesh.primitives.size(); ++i) {
        const auto& prim = mesh.primitives[i];
        wgpuRenderPassEncoderSetBindGroup(pass, 0,
                                            r->primitive_bind_groups[i],
                                            0, nullptr);
        WGPUBuffer vbuf = dawn_int::dawn_internal_get_buffer(dev, prim.vertex_buffer);
        WGPUBuffer ibuf = dawn_int::dawn_internal_get_buffer(dev, prim.index_buffer);
        wgpuRenderPassEncoderSetVertexBuffer(pass, 0, vbuf, 0, WGPU_WHOLE_SIZE);
        wgpuRenderPassEncoderSetIndexBuffer(pass, ibuf, WGPUIndexFormat_Uint32,
                                              0, WGPU_WHOLE_SIZE);
        wgpuRenderPassEncoderDrawIndexed(pass, prim.index_count, 1, 0, 0, 0);
    }

    wgpuRenderPassEncoderEnd(pass);
    wgpuRenderPassEncoderRelease(pass);
    // No BindGroups / texture views / factor buffers to release — they
    // outlive the frame and are torn down by free_mesh_draw_cache.
}

// ═══════════════════════════════════════════════════════════════════════
// C ABI
// ═══════════════════════════════════════════════════════════════════════

extern "C" AetherSceneRenderer* aether_scene_renderer_create(
    void* iosurface, uint32_t width, uint32_t height) {
    if (!iosurface || width == 0 || height == 0) {
        scene_log("create: invalid args (iosurface=%p w=%u h=%u)",
                  iosurface, width, height);
        return nullptr;
    }
#if !defined(__APPLE__)
    scene_log("create: IOSurface renderer is Apple-only");
    return nullptr;
#else
    using namespace ::aether::render;

    GPUDevice* device = ::aether::pocketworld::dawn_singleton_acquire();
    if (!device) return nullptr;
    auto& dev = *(device);
    if (!is_dawn(&dev)) {
        ::aether::pocketworld::dawn_singleton_release();
        return nullptr;
    }

    auto* r = new AetherSceneRenderer();
    r->device = device;
    r->width = width;
    r->height = height;
    auto color_format = detect_iosurface_color_format(iosurface, width, height);
    if (!color_format.has_value()) {
        delete r;
        ::aether::pocketworld::dawn_singleton_release();
        return nullptr;
    }
    r->color_format = *color_format;
    const WGPUTextureFormat wgpu_color_format = to_wgpu_color_format(r->color_format);
    if (wgpu_color_format == WGPUTextureFormat_Undefined) {
        scene_log("create: unsupported WGPU color format mapping for %s",
                  gpu_texture_format_name(r->color_format));
        delete r;
        ::aether::pocketworld::dawn_singleton_release();
        return nullptr;
    }

    auto fail = [&](const char* msg) -> AetherSceneRenderer* {
        scene_log("create: %s", msg);
        // Reverse-order cleanup. Not exhaustive (early failures haven't
        // allocated everything) but each handle.valid() check is safe.
        if (r->splat_pipe) wgpuRenderPipelineRelease(r->splat_pipe);
        if (r->splat_render_layout) wgpuPipelineLayoutRelease(r->splat_render_layout);
        if (r->splat_render_bgl)    wgpuBindGroupLayoutRelease(r->splat_render_bgl);
        if (r->mesh_pipe)  wgpuRenderPipelineRelease(r->mesh_pipe);
        if (r->mesh_pipeline_layout) wgpuPipelineLayoutRelease(r->mesh_pipeline_layout);
        if (r->mesh_bgl)             wgpuBindGroupLayoutRelease(r->mesh_bgl);
        if (r->mesh_sampler) wgpuSamplerRelease(r->mesh_sampler);
        if (r->fallback_white.valid())        device->destroy_texture(r->fallback_white);
        if (r->fallback_flat_normal.valid())  device->destroy_texture(r->fallback_flat_normal);
        if (r->fallback_black.valid())        device->destroy_texture(r->fallback_black);
        if (r->mesh_light_buf.valid())        device->destroy_buffer(r->mesh_light_buf);
        if (r->mesh_model_buf.valid())        device->destroy_buffer(r->mesh_model_buf);
        if (r->mesh_camera_buf.valid())       device->destroy_buffer(r->mesh_camera_buf);
        if (r->mesh_fs.valid())               device->destroy_shader(r->mesh_fs);
        if (r->mesh_vs.valid())               device->destroy_shader(r->mesh_vs);
        if (r->sort_scatter_shader.valid())   device->destroy_shader(r->sort_scatter_shader);
        if (r->sort_scan_add_shader.valid())  device->destroy_shader(r->sort_scan_add_shader);
        if (r->sort_scan_shader.valid())      device->destroy_shader(r->sort_scan_shader);
        if (r->sort_reduce_shader.valid())    device->destroy_shader(r->sort_reduce_shader);
        if (r->sort_count_shader.valid())     device->destroy_shader(r->sort_count_shader);
        if (r->sort_prep_shader.valid())      device->destroy_shader(r->sort_prep_shader);
        if (r->project_visible_shader.valid()) device->destroy_shader(r->project_visible_shader);
        if (r->project_forward_shader.valid()) device->destroy_shader(r->project_forward_shader);
        if (r->splat_fs.valid())              device->destroy_shader(r->splat_fs);
        if (r->splat_vs.valid())              device->destroy_shader(r->splat_vs);
        if (r->splats_buf.valid())            device->destroy_buffer(r->splats_buf);
        if (r->splat_uniforms_buf.valid())    device->destroy_buffer(r->splat_uniforms_buf);
        if (r->depth_tex.valid())             device->destroy_texture(r->depth_tex);
        if (r->iosurface_tex.valid())         device->destroy_texture(r->iosurface_tex);
        delete r;
        ::aether::pocketworld::dawn_singleton_release();
        return nullptr;
    };

    // 1. Render targets: IOSurface color + depth.
    r->iosurface_tex = dawn_import_iosurface_texture(
        *device, iosurface, width, height, r->color_format);
    if (!r->iosurface_tex.valid()) return fail("import_iosurface_texture failed");
    scene_log("create: IOSurface %ux%u format=%s",
              width, height, gpu_texture_format_name(r->color_format));

    GPUTextureDesc depth_desc{};
    depth_desc.width = width;
    depth_desc.height = height;
    depth_desc.depth = 1;
    depth_desc.mip_levels = 1;
    depth_desc.format = GPUTextureFormat::kDepth32Float;
    depth_desc.usage_mask = static_cast<std::uint8_t>(GPUTextureUsage::kRenderTarget);
    depth_desc.label = "scene.depth";
    r->depth_tex = device->create_texture(depth_desc);
    if (!r->depth_tex.valid()) return fail("depth texture create failed");

    // 2. Splat path uniforms + splats + shaders + pipeline.
    auto make_buf = [&](std::size_t bytes, std::uint8_t usage_mask, const char* label) {
        GPUBufferDesc d{};
        d.size_bytes = bytes;
        d.storage = GPUStorageMode::kPrivate;
        d.usage_mask = usage_mask;
        d.label = label;
        return device->create_buffer(d);
    };

    // Phase 6.4f stub: splat_uniforms_buf is always created (it holds
    // the per-frame RenderUniforms struct that all 8 Brush kernels
    // share); splats_buf becomes the OUTPUT of project_visible at
    // implementation time and gets allocated lazily inside the
    // Phase 6.4f load_ply path with the right capacity for the
    // loaded scene. For now we allocate a 1-slot placeholder so the
    // existing splat_pipe still has a bind target if it gets used
    // (it doesn't — encode_splat_pass deleted above).
    r->splat_uniforms_buf = make_buf(sizeof(RenderArgsStorage),
        static_cast<std::uint8_t>(GPUBufferUsage::kStorage),
        "scene.splat_uniforms");
    r->splats_buf = make_buf(sizeof(ProjectedSplatLayout),
        static_cast<std::uint8_t>(GPUBufferUsage::kStorage),
        "scene.splats.placeholder");
    if (!r->splat_uniforms_buf.valid() || !r->splats_buf.valid())
        return fail("splat buffer create failed");

    RenderArgsStorage uniforms = make_empty_uniforms(width, height);
    device->update_buffer(r->splat_uniforms_buf, &uniforms, 0, sizeof(uniforms));

    r->splat_vs = device->load_shader("splat_render_vs", GPUShaderStage::kVertex);
    r->splat_fs = device->load_shader("splat_render_fs", GPUShaderStage::kFragment);
    if (!r->splat_vs.valid() || !r->splat_fs.valid())
        return fail("splat load_shader failed");
    // Phase 6.4f: also load the 2 compute kernels (project_forward,
    // project_visible). They only get instantiated into pipelines when
    // load_ply / load_spz fires, but we register the WGSL up front so
    // that path doesn't depend on lazy registration ordering.
    r->project_forward_shader = device->load_shader("project_forward",
                                                     GPUShaderStage::kCompute);
    r->project_visible_shader = device->load_shader("project_visible",
                                                     GPUShaderStage::kCompute);
    if (!r->project_forward_shader.valid() || !r->project_visible_shader.valid())
        return fail("splat compute load_shader failed");

    // Phase 6.4f.2.a: load the 6 sort kernels (sort_prep_depth +
    // 5-stage Brush radix sort: count → reduce → scan → scan_add →
    // scatter). Pipelines are instantiated per-scene in
    // build_splat_scene_from_gaussians; the shader modules are global.
    r->sort_prep_shader     = device->load_shader("sort_prep_depth", GPUShaderStage::kCompute);
    r->sort_count_shader    = device->load_shader("sort_count",      GPUShaderStage::kCompute);
    r->sort_reduce_shader   = device->load_shader("sort_reduce",     GPUShaderStage::kCompute);
    r->sort_scan_shader     = device->load_shader("sort_scan",       GPUShaderStage::kCompute);
    r->sort_scan_add_shader = device->load_shader("sort_scan_add",   GPUShaderStage::kCompute);
    r->sort_scatter_shader  = device->load_shader("sort_scatter",    GPUShaderStage::kCompute);
    if (!r->sort_prep_shader.valid()    || !r->sort_count_shader.valid() ||
        !r->sort_reduce_shader.valid()  || !r->sort_scan_shader.valid()  ||
        !r->sort_scan_add_shader.valid()|| !r->sort_scatter_shader.valid())
        return fail("sort compute load_shader failed");

    // splat_render: build an explicit BindGroupLayout so Phase 6.4f's
    // load_ply path can create BindGroups against it. (The auto layout
    // path used previously generated a layout we couldn't reference from
    // C++.)
    WGPUDevice wd_for_splat = dawn_int::dawn_internal_wgpu_device(dev);
    r->splat_render_bgl = create_splat_render_bgl(wd_for_splat);
    if (!r->splat_render_bgl) return fail("splat_render BGL create failed");
    {
        WGPUPipelineLayoutDescriptor pl = WGPU_PIPELINE_LAYOUT_DESCRIPTOR_INIT;
        pl.bindGroupLayoutCount = 1;
        pl.bindGroupLayouts = &r->splat_render_bgl;
        r->splat_render_layout = wgpuDeviceCreatePipelineLayout(wd_for_splat, &pl);
    }
    if (!r->splat_render_layout) return fail("splat_render layout create failed");

    std::string ep_unused;
    r->splat_pipe = create_splat_overlay_pipeline_explicit(
        wd_for_splat,
        dawn_int::dawn_internal_get_shader_module(dev, r->splat_vs, ep_unused),
        dawn_int::dawn_internal_get_shader_module(dev, r->splat_fs, ep_unused),
        wgpu_color_format,
        r->splat_render_layout);
    if (!r->splat_pipe) return fail("splat pipeline create failed");

    // 3. Mesh path: shaders + pipeline + uniforms + sampler + fallback textures.
    r->mesh_vs = device->load_shader("mesh_render_vs", GPUShaderStage::kVertex);
    r->mesh_fs = device->load_shader("mesh_render_fs", GPUShaderStage::kFragment);
    if (!r->mesh_vs.valid() || !r->mesh_fs.valid())
        return fail("mesh load_shader failed");

    // Build the explicit BindGroupLayout once and reuse it everywhere
    // (pipeline create + per-frame BindGroup create in encode_mesh_pass).
    // See create_mesh_bind_group_layout's comment for why we don't use
    // Dawn's `auto` layout (the WGSL fragment shader has un-referenced
    // bindings in unlit mode, which auto-layout strips).
    WGPUDevice wd = dawn_int::dawn_internal_wgpu_device(dev);
    r->mesh_bgl = create_mesh_bind_group_layout(wd);
    if (!r->mesh_bgl) return fail("mesh bind group layout create failed");

    WGPUPipelineLayoutDescriptor pl_desc = WGPU_PIPELINE_LAYOUT_DESCRIPTOR_INIT;
    pl_desc.bindGroupLayoutCount = 1;
    pl_desc.bindGroupLayouts = &r->mesh_bgl;
    r->mesh_pipeline_layout = wgpuDeviceCreatePipelineLayout(wd, &pl_desc);
    if (!r->mesh_pipeline_layout)
        return fail("mesh pipeline layout create failed");

    r->mesh_pipe = create_mesh_pipeline(
        wd,
        dawn_int::dawn_internal_get_shader_module(dev, r->mesh_vs, ep_unused),
        dawn_int::dawn_internal_get_shader_module(dev, r->mesh_fs, ep_unused),
        wgpu_color_format,
        r->mesh_pipeline_layout);
    if (!r->mesh_pipe) return fail("mesh pipeline create failed");

    r->mesh_camera_buf = make_buf(sizeof(CameraUniforms),
        static_cast<std::uint8_t>(GPUBufferUsage::kUniform), "scene.mesh.camera");
    r->mesh_model_buf = make_buf(sizeof(ModelTransform),
        static_cast<std::uint8_t>(GPUBufferUsage::kUniform), "scene.mesh.model");
    r->mesh_light_buf = make_buf(sizeof(LightUniforms),
        static_cast<std::uint8_t>(GPUBufferUsage::kUniform), "scene.mesh.light");
    // Plan-A perf fix: pbr_factors moved to PER-MATERIAL buffers built
    // in build_mesh_draw_cache (each material gets its own immutable
    // factors buffer at load_glb time, never written at frame time).
    // The shared "scene.mesh.factors" buffer is gone.
    if (!r->mesh_camera_buf.valid() || !r->mesh_model_buf.valid()
        || !r->mesh_light_buf.valid())
        return fail("mesh uniform buffer create failed");

    // Initialize light uniform: directional from above-front, white,
    // intensity 3.0 (Filament default-ish).
    LightUniforms light{};
    light.direction[0] = -0.3f;
    light.direction[1] = -1.0f;
    light.direction[2] = -0.5f;
    light.direction[3] = 0.0f;
    light.color[0] = 1.0f; light.color[1] = 1.0f; light.color[2] = 1.0f;
    light.color[3] = 1.0f;
    light.intensity = 3.0f;
    device->update_buffer(r->mesh_light_buf, &light, 0, sizeof(light));

    r->mesh_sampler = create_default_sampler(dawn_int::dawn_internal_wgpu_device(dev));
    if (!r->mesh_sampler) return fail("sampler create failed");

    r->fallback_white = create_1x1_texture(*device, 255, 255, 255, 255, "scene.fb.white");
    r->fallback_flat_normal = create_1x1_texture(*device, 128, 128, 255, 255, "scene.fb.flat_normal");
    r->fallback_black = create_1x1_texture(*device, 0, 0, 0, 255, "scene.fb.black");
    if (!r->fallback_white.valid() || !r->fallback_flat_normal.valid()
        || !r->fallback_black.valid())
        return fail("fallback texture create failed");

    return r;
#endif
}

extern "C" void aether_scene_renderer_destroy(AetherSceneRenderer* r) {
    if (!r) return;
    auto* device = r->device;
    if (device) {
        // Plan-A perf fix: tear down the BindGroup / texture-view /
        // factors-buffer cache BEFORE unloading the mesh — the cache
        // holds GPU references into mesh-owned textures, so the order
        // matters (release the wrappers first, then destroy the
        // backing textures).
        free_mesh_draw_cache(r);
        if (r->loaded_mesh) {
            ::aether::pocketworld::unload_glb_mesh(*device, *r->loaded_mesh);
            r->loaded_mesh.reset();
        }
        // Phase 6.4f: tear down splat scene (compute pipelines + GPU
        // buffers) before releasing the splat overlay render pipeline so
        // the BindGroups in splat_scene have valid handles to release.
        free_splat_scene(r);
        if (r->splat_pipe)            wgpuRenderPipelineRelease(r->splat_pipe);
        if (r->splat_render_layout)   wgpuPipelineLayoutRelease(r->splat_render_layout);
        if (r->splat_render_bgl)      wgpuBindGroupLayoutRelease(r->splat_render_bgl);
        if (r->mesh_pipe)             wgpuRenderPipelineRelease(r->mesh_pipe);
        // Release the explicit pipeline layout BEFORE the bind group
        // layout it references — Dawn's reference counting allows
        // either order in practice, but releasing in dependency order
        // matches the construction sequence + makes leak hunts easier.
        if (r->mesh_pipeline_layout)  wgpuPipelineLayoutRelease(r->mesh_pipeline_layout);
        if (r->mesh_bgl)              wgpuBindGroupLayoutRelease(r->mesh_bgl);
        if (r->mesh_sampler)          wgpuSamplerRelease(r->mesh_sampler);
        if (r->fallback_white.valid())       device->destroy_texture(r->fallback_white);
        if (r->fallback_flat_normal.valid()) device->destroy_texture(r->fallback_flat_normal);
        if (r->fallback_black.valid())       device->destroy_texture(r->fallback_black);
        if (r->mesh_light_buf.valid())   device->destroy_buffer(r->mesh_light_buf);
        if (r->mesh_model_buf.valid())   device->destroy_buffer(r->mesh_model_buf);
        if (r->mesh_camera_buf.valid())  device->destroy_buffer(r->mesh_camera_buf);
        if (r->mesh_fs.valid())          device->destroy_shader(r->mesh_fs);
        if (r->mesh_vs.valid())          device->destroy_shader(r->mesh_vs);
        if (r->sort_scatter_shader.valid())   device->destroy_shader(r->sort_scatter_shader);
        if (r->sort_scan_add_shader.valid())  device->destroy_shader(r->sort_scan_add_shader);
        if (r->sort_scan_shader.valid())      device->destroy_shader(r->sort_scan_shader);
        if (r->sort_reduce_shader.valid())    device->destroy_shader(r->sort_reduce_shader);
        if (r->sort_count_shader.valid())     device->destroy_shader(r->sort_count_shader);
        if (r->sort_prep_shader.valid())      device->destroy_shader(r->sort_prep_shader);
        if (r->project_visible_shader.valid()) device->destroy_shader(r->project_visible_shader);
        if (r->project_forward_shader.valid()) device->destroy_shader(r->project_forward_shader);
        if (r->splat_fs.valid())         device->destroy_shader(r->splat_fs);
        if (r->splat_vs.valid())         device->destroy_shader(r->splat_vs);
        if (r->splats_buf.valid())       device->destroy_buffer(r->splats_buf);
        if (r->splat_uniforms_buf.valid()) device->destroy_buffer(r->splat_uniforms_buf);
        if (r->depth_tex.valid())        device->destroy_texture(r->depth_tex);
        if (r->iosurface_tex.valid())    device->destroy_texture(r->iosurface_tex);
    }
    delete r;
    ::aether::pocketworld::dawn_singleton_release();
}

// Phase 6.4f: tear down a previously loaded splat scene. Called from
// load_ply / load_spz (when replacing) and from destroy. Safe to call
// when no scene is loaded (early-out on !splat_scene).
static void free_splat_scene(AetherSceneRenderer* r) {
    if (!r || !r->splat_scene) return;
    SplatScene& s = *r->splat_scene;
    // ─── Phase 6.4f.2.a — sort BindGroups + pipelines + layouts ────────
    for (int i = 0; i < 8; ++i) {
        if (s.sort_scatter_bgs[i]) wgpuBindGroupRelease(s.sort_scatter_bgs[i]);
        if (s.sort_count_bgs[i])   wgpuBindGroupRelease(s.sort_count_bgs[i]);
    }
    if (s.sort_scan_add_bg)        wgpuBindGroupRelease(s.sort_scan_add_bg);
    if (s.sort_scan_bg)            wgpuBindGroupRelease(s.sort_scan_bg);
    if (s.sort_reduce_bg)          wgpuBindGroupRelease(s.sort_reduce_bg);
    if (s.sort_prep_bg)            wgpuBindGroupRelease(s.sort_prep_bg);
    if (s.sort_scatter_pipe)       wgpuComputePipelineRelease(s.sort_scatter_pipe);
    if (s.sort_scan_add_pipe)      wgpuComputePipelineRelease(s.sort_scan_add_pipe);
    if (s.sort_scan_pipe)          wgpuComputePipelineRelease(s.sort_scan_pipe);
    if (s.sort_reduce_pipe)        wgpuComputePipelineRelease(s.sort_reduce_pipe);
    if (s.sort_count_pipe)         wgpuComputePipelineRelease(s.sort_count_pipe);
    if (s.sort_prep_pipe)          wgpuComputePipelineRelease(s.sort_prep_pipe);
    if (s.sort_scatter_layout)     wgpuPipelineLayoutRelease(s.sort_scatter_layout);
    if (s.sort_scan_add_layout)    wgpuPipelineLayoutRelease(s.sort_scan_add_layout);
    if (s.sort_scan_layout)        wgpuPipelineLayoutRelease(s.sort_scan_layout);
    if (s.sort_reduce_layout)      wgpuPipelineLayoutRelease(s.sort_reduce_layout);
    if (s.sort_count_layout)       wgpuPipelineLayoutRelease(s.sort_count_layout);
    if (s.sort_prep_layout)        wgpuPipelineLayoutRelease(s.sort_prep_layout);
    if (s.sort_scatter_bgl)        wgpuBindGroupLayoutRelease(s.sort_scatter_bgl);
    if (s.sort_scan_add_bgl)       wgpuBindGroupLayoutRelease(s.sort_scan_add_bgl);
    if (s.sort_scan_bgl)           wgpuBindGroupLayoutRelease(s.sort_scan_bgl);
    if (s.sort_reduce_bgl)         wgpuBindGroupLayoutRelease(s.sort_reduce_bgl);
    if (s.sort_count_bgl)          wgpuBindGroupLayoutRelease(s.sort_count_bgl);
    if (s.sort_prep_bgl)           wgpuBindGroupLayoutRelease(s.sort_prep_bgl);
    // ─── Phase 6.4f — projection + render BindGroups + pipelines ───────
    if (s.splat_render_bg)     wgpuBindGroupRelease(s.splat_render_bg);
    if (s.project_visible_bg)  wgpuBindGroupRelease(s.project_visible_bg);
    if (s.project_forward_bg)  wgpuBindGroupRelease(s.project_forward_bg);
    if (s.project_visible_pipe) wgpuComputePipelineRelease(s.project_visible_pipe);
    if (s.project_forward_pipe) wgpuComputePipelineRelease(s.project_forward_pipe);
    if (s.project_visible_layout) wgpuPipelineLayoutRelease(s.project_visible_layout);
    if (s.project_forward_layout) wgpuPipelineLayoutRelease(s.project_forward_layout);
    if (s.project_visible_bgl) wgpuBindGroupLayoutRelease(s.project_visible_bgl);
    if (s.project_forward_bgl) wgpuBindGroupLayoutRelease(s.project_forward_bgl);
    if (r->device) {
        // ─── Sort buffers ──────────────────────────────────────────────
        for (int i = 0; i < 8; ++i) {
            if (s.sort_config_bufs[i].valid()) r->device->destroy_buffer(s.sort_config_bufs[i]);
        }
        if (s.sort_num_keys_arr_buf.valid())  r->device->destroy_buffer(s.sort_num_keys_arr_buf);
        if (s.sort_reduced_buf.valid())       r->device->destroy_buffer(s.sort_reduced_buf);
        if (s.sort_counts_buf.valid())        r->device->destroy_buffer(s.sort_counts_buf);
        if (s.sort_values_alt_buf.valid())    r->device->destroy_buffer(s.sort_values_alt_buf);
        if (s.sort_values_buf.valid())        r->device->destroy_buffer(s.sort_values_buf);
        if (s.sort_keys_alt_buf.valid())      r->device->destroy_buffer(s.sort_keys_alt_buf);
        if (s.sort_keys_buf.valid())          r->device->destroy_buffer(s.sort_keys_buf);
        // ─── Source buffers (Phase 6.4f.3.c — shared via SplatData) ────
        // packed_splats_buf + coeffs_non_dc_buf are owned by SplatData;
        // dropping `s.data` (via SplatScene destructor) frees them when
        // the last shared_ptr reference goes away.
        if (s.depths_buf.valid())                  r->device->destroy_buffer(s.depths_buf);
        if (s.global_from_compact_gid_buf.valid()) r->device->destroy_buffer(s.global_from_compact_gid_buf);
    }
    r->splat_scene.reset();
    r->has_splats = false;
}

// Plan-A perf fix: free the per-load cache (factor buffers, texture
// views, BindGroups). Called from load_glb (when replacing a mesh)
// and from destroy.
static void free_mesh_draw_cache(AetherSceneRenderer* r) {
    if (!r) return;
    for (auto& bg : r->primitive_bind_groups) {
        if (bg) wgpuBindGroupRelease(bg);
    }
    r->primitive_bind_groups.clear();
    for (auto& view : r->material_texture_views) {
        if (view) wgpuTextureViewRelease(view);
    }
    r->material_texture_views.clear();
    if (r->device) {
        for (auto& buf : r->material_factors_bufs) {
            if (buf.valid()) r->device->destroy_buffer(buf);
        }
    }
    r->material_factors_bufs.clear();
}

// Plan-A perf fix: build the per-primitive BindGroup + per-material
// factors buffer cache once per load_glb. This replaces what
// encode_mesh_pass used to do every frame:
//   - 1 factors uniform buffer write (×N primitives)
//   - 5 texture view creates (×N primitives)
//   - 1 BindGroup create + validate (×N primitives)
// All of that is now done ONCE here, then re-used every frame for the
// life of the loaded mesh.
//
// Returns true on success, false (with log) on any allocation failure
// — caller treats failure as load failure and unloads the mesh.
static bool build_mesh_draw_cache(AetherSceneRenderer* r) {
    if (!r || !r->device || !r->loaded_mesh) return false;
    using namespace ::aether::render;
    auto& dev = *(r->device);
    if (!is_dawn(&dev)) return false;
    LoadedMesh& mesh = *r->loaded_mesh;
    WGPUDevice wd = dawn_int::dawn_internal_wgpu_device(dev);

    // 1. Per-material factors uniform buffer (write once, never touched
    //    again at frame time).
    r->material_factors_bufs.reserve(mesh.materials.size());
    for (std::size_t mi = 0; mi < mesh.materials.size(); ++mi) {
        GPUBufferDesc desc{};
        desc.size_bytes = sizeof(PbrFactorsUniforms);
        desc.usage_mask = static_cast<std::uint8_t>(GPUBufferUsage::kUniform);
        desc.storage = GPUStorageMode::kPrivate;
        desc.label = "scene.mesh.material_factors";
        GPUBufferHandle h = dev.create_buffer(desc);
        if (!h.valid()) {
            scene_log("build_mesh_draw_cache: factors buffer alloc failed at material %zu", mi);
            return false;
        }
        const auto& mat = mesh.materials[mi];
        PbrFactorsUniforms factors{};
        factors.base_color[0] = mat.base_color_factor[0];
        factors.base_color[1] = mat.base_color_factor[1];
        factors.base_color[2] = mat.base_color_factor[2];
        factors.base_color[3] = mat.base_color_factor[3];
        factors.metallic_roughness[0] = mat.metallic_factor;
        factors.metallic_roughness[1] = mat.roughness_factor;
        factors.occlusion_strength = mat.occlusion_strength;
        factors.emissive[0] = mat.emissive_factor[0];
        factors.emissive[1] = mat.emissive_factor[1];
        factors.emissive[2] = mat.emissive_factor[2];
        dev.update_buffer(h, &factors, 0, sizeof(factors));
        r->material_factors_bufs.push_back(h);
    }

    // 2. Per-material texture views (5 per material, indexed
    //    [mi*5 + 0..4] = base / mr / normal / occlusion / emissive).
    auto resolve = [&](GPUTextureHandle h, GPUTextureHandle fallback) {
        return h.valid() ? dawn_int::dawn_internal_get_texture(dev, h)
                          : dawn_int::dawn_internal_get_texture(dev, fallback);
    };
    r->material_texture_views.reserve(mesh.materials.size() * 5);
    for (std::size_t mi = 0; mi < mesh.materials.size(); ++mi) {
        const auto& mat = mesh.materials[mi];
        WGPUTexture base = resolve(mat.base_color_tex, r->fallback_white);
        WGPUTexture mr   = resolve(mat.metallic_roughness_tex, r->fallback_white);
        WGPUTexture nrm  = resolve(mat.normal_tex, r->fallback_flat_normal);
        WGPUTexture occ  = resolve(mat.occlusion_tex, r->fallback_white);
        WGPUTexture emis = resolve(mat.emissive_tex, r->fallback_black);
        if (!base || !mr || !nrm || !occ || !emis) {
            scene_log("build_mesh_draw_cache: missing material %zu texture", mi);
            return false;
        }
        WGPUTextureViewDescriptor v_desc = WGPU_TEXTURE_VIEW_DESCRIPTOR_INIT;
        r->material_texture_views.push_back(wgpuTextureCreateView(base, &v_desc));
        r->material_texture_views.push_back(wgpuTextureCreateView(mr,   &v_desc));
        r->material_texture_views.push_back(wgpuTextureCreateView(nrm,  &v_desc));
        r->material_texture_views.push_back(wgpuTextureCreateView(occ,  &v_desc));
        r->material_texture_views.push_back(wgpuTextureCreateView(emis, &v_desc));
    }

    // 3. Per-primitive BindGroup. The renderer's camera + model + light
    //    buffers are referenced — when their CONTENTS change per frame
    //    (camera/model are updated in render_full), the BindGroup still
    //    points at the same buffer handles, so the new contents are
    //    visible. The factors buffer + texture views are immutable for
    //    the life of the loaded mesh.
    r->primitive_bind_groups.reserve(mesh.primitives.size());
    for (auto& prim : mesh.primitives) {
        const std::uint32_t mi = (prim.material_index < mesh.materials.size())
                                  ? prim.material_index : 0u;
        // Skip cleanly if the loader assigned an out-of-range material
        // (shouldn't happen, but be defensive).
        if (mi >= r->material_factors_bufs.size()) {
            scene_log("build_mesh_draw_cache: primitive material_index=%u out of range %zu",
                      mi, r->material_factors_bufs.size());
            return false;
        }
        WGPUBindGroupEntry e[10] = {};
        e[0].binding = 0; e[0].buffer = dawn_int::dawn_internal_get_buffer(dev, r->mesh_camera_buf);
        e[0].offset = 0; e[0].size = WGPU_WHOLE_SIZE;
        e[1].binding = 1; e[1].buffer = dawn_int::dawn_internal_get_buffer(dev, r->mesh_model_buf);
        e[1].offset = 0; e[1].size = WGPU_WHOLE_SIZE;
        e[2].binding = 2; e[2].buffer = dawn_int::dawn_internal_get_buffer(dev, r->mesh_light_buf);
        e[2].offset = 0; e[2].size = WGPU_WHOLE_SIZE;
        e[3].binding = 3;
        e[3].buffer = dawn_int::dawn_internal_get_buffer(dev, r->material_factors_bufs[mi]);
        e[3].offset = 0; e[3].size = WGPU_WHOLE_SIZE;
        e[4].binding = 4; e[4].textureView = r->material_texture_views[mi*5 + 0];
        e[5].binding = 5; e[5].sampler     = r->mesh_sampler;
        e[6].binding = 6; e[6].textureView = r->material_texture_views[mi*5 + 1];
        e[7].binding = 7; e[7].textureView = r->material_texture_views[mi*5 + 2];
        e[8].binding = 8; e[8].textureView = r->material_texture_views[mi*5 + 3];
        e[9].binding = 9; e[9].textureView = r->material_texture_views[mi*5 + 4];

        WGPUBindGroupDescriptor bg_desc = WGPU_BIND_GROUP_DESCRIPTOR_INIT;
        bg_desc.layout = r->mesh_bgl;
        bg_desc.entryCount = 10;
        bg_desc.entries = e;
        WGPUBindGroup bg = wgpuDeviceCreateBindGroup(wd, &bg_desc);
        if (!bg) {
            scene_log("build_mesh_draw_cache: BindGroup create failed");
            return false;
        }
        r->primitive_bind_groups.push_back(bg);
    }
    scene_log("build_mesh_draw_cache: %zu materials, %zu primitives cached",
              mesh.materials.size(), mesh.primitives.size());
    return true;
}

extern "C" bool aether_scene_renderer_load_glb(AetherSceneRenderer* r,
                                                 const char* glb_path) {
    if (!r || !r->device || !glb_path) return false;
    if (r->loaded_mesh) {
        free_mesh_draw_cache(r);  // tear down before unloading mesh
                                  // (cache references mesh textures).
        ::aether::pocketworld::unload_glb_mesh(*r->device, *r->loaded_mesh);
        r->loaded_mesh.reset();
        r->has_mesh = false;
    }
    auto opt = ::aether::pocketworld::load_glb_mesh(*r->device, std::string(glb_path));
    if (!opt) return false;
    r->loaded_mesh = std::move(opt);
    r->has_mesh = true;
    if (!build_mesh_draw_cache(r)) {
        // Cache build failed — undo everything so the renderer is in a
        // clean "no mesh" state and the caller sees the load as failed.
        free_mesh_draw_cache(r);
        ::aether::pocketworld::unload_glb_mesh(*r->device, *r->loaded_mesh);
        r->loaded_mesh.reset();
        r->has_mesh = false;
        return false;
    }
    scene_log("loaded GLB '%s' (%zu primitives, %zu materials, bounds [%.2f..%.2f])",
              glb_path,
              r->loaded_mesh->primitives.size(),
              r->loaded_mesh->materials.size(),
              r->loaded_mesh->bounds_min[0], r->loaded_mesh->bounds_max[0]);
    return true;
}

// Phase 6.4f — Brush 8-kernel splat pipeline integration.
//
// load_ply and load_spz both funnel through build_splat_scene_from_gaussians
// once the source PLY/SPZ has been parsed into a vector<GaussianParams>
// by aether::splat::load_ply / aether::splat::load_spz (header-only +
// gzip-decompress impl in src/splat/spz_decoder.cpp). The build function:
//   1. Repacks GaussianParams into Brush WGSL bindings:
//        - PLY quat (w,x,y,z) → WGSL quat (x,y,z,w)
//        - linear color → raw SH DC: sh0 = (c - 0.5) / SH_C0
//        - linear opacity → raw (logit): raw = log(o / (1 - o))
//        - linear scale → log(scale)
//   2. Computes the AABB so get_bounds returns a real rect (Flutter
//      camera-fit needs this).
//   3. Uploads into GPU storage buffers via update_buffer.
//   4. Reallocates the projected_splats output buffer (was 1-slot
//      placeholder at create time) sized to N * sizeof(ProjectedSplat).
//   5. Builds the 2 compute pipelines (project_forward, project_visible)
//      against the per-load BindGroupLayouts; they share the renderer's
//      splat_uniforms_buf so per-frame viewmat updates flow through.
//   6. Builds the 3 BindGroups (project_forward, project_visible,
//      splat_render). They reference stable buffer handles so they can
//      be cached for the lifetime of the loaded scene.
//
// Per-frame: render_full's `if (has_splats)` branch dispatches the 2
// compute kernels then the splat_render render pass. CPU-side num_visible
// readback is avoided by clearing the projected_splats buffer at frame
// start and dispatching splat_render with instance_count = num_splats —
// the fragment shader's discard threshold (`alpha < 1/255`) drops any
// instances where project_visible never wrote (alpha stays 0 from the
// frame-start clear).
//
// Limitations of this first cut (PHASE_BACKLOG.md Phase 6.4f.2):
//   • No per-splat depth sort. Brush's full pipeline runs sort_count →
//     sort_reduce → sort_scan → sort_scan_add → sort_scatter on
//     (tile_id, depth_uint32) keys for back-to-front correct alpha.
//     Without it, overlapping splats blend in atomic-write order →
//     transparency artifacts on heavy occlusion.
//   • SH degree 0 only. SPZ decoder doesn't unpack higher-order SH
//     today; PLY loader DOES extract SH degree 1 but we ignore it.
//     View-dependent shading is uniform.
//   • No tile binning (map_gaussian_to_intersects + per-tile
//     blending). The vert+frag splat_render path overrenders compared
//     to Brush's compute rasterizer but is 23× faster on mobile per
//     splat_render.wgsl's docstring.

// Map an aether::splat::GaussianParams vector onto Brush WGSL buffers,
// allocate intermediates, build pipelines + bind groups, set has_splats.
// Returns false (with log) on any allocation / pipeline-create failure;
// in failure mode the renderer is left in "no splat scene" state.
//
// Phase 6.4f.2.b/c: `sh_degree` (0..3) and `sh_rest` (PLY-native channel-
// major basis-major float layout — see PlyLoadResult docs) drive
// higher-order spherical harmonics. When `sh_degree == 0`, sh_rest is
// ignored. Repacking into Brush's basis-major-vec3 GPU layout happens
// inline below — project_visible.wgsl reads [b0_c0_, b1_c0_, b1_c1_,
// b1_c2_, b2_c0_, …] in that order, with each entry a vec3<f32> spanning
// (R, G, B) for that basis function.
static bool build_splat_scene_from_gaussians(
    AetherSceneRenderer* r,
    const std::vector<::aether::splat::GaussianParams>& gaussians,
    std::uint32_t sh_degree,
    const float* sh_rest,
    const std::string& cache_key = std::string{}) {
    if (!r || !r->device || gaussians.empty()) return false;
    using namespace ::aether::render;
    auto& dev = *(r->device);
    if (!is_dawn(&dev)) return false;
    WGPUDevice wd = dawn_int::dawn_internal_wgpu_device(dev);

    // Tear down any prior scene so we don't leak GPU buffers / pipelines.
    free_splat_scene(r);

    if (sh_degree > 3u) sh_degree = 3u;       // clamp; project_visible
                                               // supports up to 4, we ship 3
    if (sh_degree > 0u && sh_rest == nullptr) sh_degree = 0u;  // safety

    const std::uint32_t N = static_cast<std::uint32_t>(gaussians.size());
    SplatScene s;
    s.num_splats = N;
    s.sh_degree = sh_degree;
    // num_basis_non_dc per channel: 0,3,8,15 for deg 0,1,2,3.
    // (Total basis = 1 (DC) + non_dc; the DC slot is folded into
    // packed_splats_buf's rgba field.)
    const std::uint32_t non_dc_basis = (sh_degree == 0u) ? 0u
                                       : (sh_degree == 1u) ? 3u
                                       : (sh_degree == 2u) ? 8u
                                       : 15u;

    // ─── Phase 6.4f.3.c — cache-hit fast path ──────────────────────────
    //
    // If a SplatData with this key is already alive (another renderer is
    // currently rendering the same scene), grab a strong ref and skip
    // the entire pack / upload / mtime-walk. Per-renderer state (sort
    // scratch, gid/depths, bind groups) is still rebuilt below — only
    // the splat-data buffers themselves are shared.
    std::shared_ptr<SplatData> shared_data;
    if (!cache_key.empty()) {
        shared_data = SplatDataCache::instance().get(cache_key);
        if (shared_data) {
            s.data = shared_data;
            s.packed_splats_buf = shared_data->packed_splats_buf;
            s.coeffs_non_dc_buf = shared_data->coeffs_non_dc_buf;
            s.bounds_min[0] = shared_data->bounds_min[0];
            s.bounds_min[1] = shared_data->bounds_min[1];
            s.bounds_min[2] = shared_data->bounds_min[2];
            s.bounds_max[0] = shared_data->bounds_max[0];
            s.bounds_max[1] = shared_data->bounds_max[1];
            s.bounds_max[2] = shared_data->bounds_max[2];
            scene_log("build_splat_scene: cache HIT key='%s' (refcount=%ld)",
                      cache_key.c_str(),
                      static_cast<long>(shared_data.use_count()));
        }
    }

    // ─── Allocate + upload GPU buffers ─────────────────────────────────
    auto make_buf = [&](std::size_t bytes, const char* label) {
        GPUBufferDesc d{};
        d.size_bytes = bytes;
        d.storage = GPUStorageMode::kPrivate;
        d.usage_mask = static_cast<std::uint8_t>(GPUBufferUsage::kStorage);
        d.label = label;
        return dev.create_buffer(d);
    };

    if (!shared_data) {
        // ─── Phase 6.4f.3.a — pack splats into 16-byte format ──────────
        //
        // Each gaussian gets packed via aether::splat::pack_gaussian
        // (encodes color → sRGB rgba (4B), position → fp16 xyz (6B),
        // rotation → octahedral axis + angle (3B), scale → log byte xyz
        // (3B)). The packing assumes:
        //   - g.color is linear RGB in [0,1]   (PLY contract)
        //   - g.opacity is linear [0,1]         (both PLY + SPZ)
        //   - g.rotation is normalized (w,x,y,z)
        //   - g.scale is positive linear
        // SPZ's `g.color` is actually SH DC (out-of-range); SPZ scenes
        // inherit the same color quantization issue main has — tracked
        // separately, not introduced or fixed by this phase.
        std::vector<::aether::splat::PackedSplat> packed(N);
        std::vector<float> coeffs_non_dc(static_cast<std::size_t>(N) *
                                          non_dc_basis * 3u);  // PackedVec3[]

        s.bounds_min[0] = s.bounds_max[0] = gaussians[0].position[0];
        s.bounds_min[1] = s.bounds_max[1] = gaussians[0].position[1];
        s.bounds_min[2] = s.bounds_max[2] = gaussians[0].position[2];

        for (std::uint32_t i = 0; i < N; ++i) {
            const auto& g = gaussians[i];
            for (int c = 0; c < 3; ++c) {
                if (g.position[c] < s.bounds_min[c]) s.bounds_min[c] = g.position[c];
                if (g.position[c] > s.bounds_max[c]) s.bounds_max[c] = g.position[c];
            }
            ::aether::splat::GaussianParams adapted = g;
            for (int c = 0; c < 3; ++c) {
                if (adapted.scale[c] < 1e-12f) adapted.scale[c] = 1e-12f;
            }
            packed[i] = ::aether::splat::pack_gaussian(adapted);

            // SH non-DC repack (PLY-native channel-major-basis-major →
            // GPU PackedVec3[] indexed slot-then-vec3, no DC slot).
            if (non_dc_basis > 0u && sh_rest != nullptr) {
                const std::size_t src_base = static_cast<std::size_t>(i) *
                                             3u * non_dc_basis;
                for (std::uint32_t b = 0; b < non_dc_basis; ++b) {
                    const std::size_t dst = (static_cast<std::size_t>(i) *
                                              non_dc_basis + b) * 3u;
                    coeffs_non_dc[dst + 0] = sh_rest[src_base + 0u * non_dc_basis + b];
                    coeffs_non_dc[dst + 1] = sh_rest[src_base + 1u * non_dc_basis + b];
                    coeffs_non_dc[dst + 2] = sh_rest[src_base + 2u * non_dc_basis + b];
                }
            }
        }

        // Build a fresh SplatData; the destructor will release any
        // partially-allocated buffers if we early-return mid-setup.
        auto data = std::make_shared<SplatData>();
        data->device = &dev;
        data->num_splats = N;
        data->sh_degree = sh_degree;
        std::memcpy(data->bounds_min, s.bounds_min, sizeof(float) * 3);
        std::memcpy(data->bounds_max, s.bounds_max, sizeof(float) * 3);
        data->packed_splats_buf = make_buf(
            N * sizeof(::aether::splat::PackedSplat), "splat.packed");
        // coeffs_non_dc bound even when degree=0 — WGSL requires the
        // binding to point at a real buffer ≥ minBindingSize. 16-byte
        // placeholder when there are no SH coefficients.
        const std::size_t coeffs_bytes = (non_dc_basis == 0u)
            ? 16u
            : (static_cast<std::size_t>(N) * non_dc_basis * sizeof(float) * 3u);
        data->coeffs_non_dc_buf = make_buf(coeffs_bytes, "splat.coeffs_non_dc");

        if (!data->packed_splats_buf.valid() || !data->coeffs_non_dc_buf.valid()) {
            scene_log("build_splat_scene: data buffer alloc failed");
            return false;  // ~SplatData frees whatever did alloc
        }
        dev.update_buffer(data->packed_splats_buf, packed.data(), 0,
                          packed.size() * sizeof(::aether::splat::PackedSplat));
        if (non_dc_basis > 0u) {
            dev.update_buffer(data->coeffs_non_dc_buf, coeffs_non_dc.data(), 0,
                              coeffs_non_dc.size() * sizeof(float));
        }
        shared_data = std::move(data);
        s.data = shared_data;
        s.packed_splats_buf = shared_data->packed_splats_buf;
        s.coeffs_non_dc_buf = shared_data->coeffs_non_dc_buf;
        if (!cache_key.empty()) {
            SplatDataCache::instance().put(cache_key, shared_data);
            scene_log("build_splat_scene: cache MISS key='%s' (uploaded %u splats, %u non_dc_basis)",
                      cache_key.c_str(), N, non_dc_basis);
        }
    }

    // Per-renderer scratch buffers — never shared, rebuilt every load.
    s.global_from_compact_gid_buf = make_buf(N * sizeof(std::uint32_t),
                                              "splat.global_from_compact_gid");
    s.depths_buf = make_buf(N * sizeof(float), "splat.depths");
    if (!s.global_from_compact_gid_buf.valid() || !s.depths_buf.valid()) {
        scene_log("build_splat_scene: scratch buffer alloc failed");
        if (s.depths_buf.valid())                  dev.destroy_buffer(s.depths_buf);
        if (s.global_from_compact_gid_buf.valid()) dev.destroy_buffer(s.global_from_compact_gid_buf);
        // s.data goes out of scope — shared_ptr handles cleanup.
        return false;
    }

    // Reallocate the projected_splats output (replaces the 1-slot placeholder
    // created in aether_scene_renderer_create) sized to N * 36 bytes.
    if (r->splats_buf.valid()) dev.destroy_buffer(r->splats_buf);
    r->splats_buf = make_buf(N * sizeof(ProjectedSplatLayout), "splat.projected");
    if (!r->splats_buf.valid()) {
        scene_log("build_splat_scene: projected_splats buffer alloc failed");
        if (s.depths_buf.valid())                  dev.destroy_buffer(s.depths_buf);
        if (s.global_from_compact_gid_buf.valid()) dev.destroy_buffer(s.global_from_compact_gid_buf);
        // s.data shared_ptr handles packed_splats / coeffs_non_dc cleanup.
        return false;
    }

    // ─── Build BindGroupLayouts + PipelineLayouts + ComputePipelines ───
    s.project_forward_bgl = create_project_forward_bgl(wd);
    s.project_visible_bgl = create_project_visible_bgl(wd);
    if (!s.project_forward_bgl || !s.project_visible_bgl) {
        scene_log("build_splat_scene: compute BGL create failed");
        if (s.project_visible_bgl) wgpuBindGroupLayoutRelease(s.project_visible_bgl);
        if (s.project_forward_bgl) wgpuBindGroupLayoutRelease(s.project_forward_bgl);
        if (r->splats_buf.valid()) dev.destroy_buffer(r->splats_buf);
        if (s.depths_buf.valid())                  dev.destroy_buffer(s.depths_buf);
        if (s.global_from_compact_gid_buf.valid()) dev.destroy_buffer(s.global_from_compact_gid_buf);
        // s.data shared_ptr handles packed_splats / coeffs_non_dc cleanup.
        return false;
    }

    {
        WGPUPipelineLayoutDescriptor pl = WGPU_PIPELINE_LAYOUT_DESCRIPTOR_INIT;
        pl.bindGroupLayoutCount = 1;
        pl.bindGroupLayouts = &s.project_forward_bgl;
        s.project_forward_layout = wgpuDeviceCreatePipelineLayout(wd, &pl);
        pl.bindGroupLayouts = &s.project_visible_bgl;
        s.project_visible_layout = wgpuDeviceCreatePipelineLayout(wd, &pl);
    }
    if (!s.project_forward_layout || !s.project_visible_layout) {
        scene_log("build_splat_scene: compute pipeline layout create failed");
        // Stash s into the renderer momentarily so free_splat_scene cleans up.
        r->splat_scene = std::move(s);
        free_splat_scene(r);
        return false;
    }

    std::string ep_unused;
    s.project_forward_pipe = create_compute_pipeline(wd,
        dawn_int::dawn_internal_get_shader_module(dev, r->project_forward_shader, ep_unused),
        s.project_forward_layout, "main");
    s.project_visible_pipe = create_compute_pipeline(wd,
        dawn_int::dawn_internal_get_shader_module(dev, r->project_visible_shader, ep_unused),
        s.project_visible_layout, "main");
    if (!s.project_forward_pipe || !s.project_visible_pipe) {
        scene_log("build_splat_scene: compute pipeline create failed");
        r->splat_scene = std::move(s);
        free_splat_scene(r);
        return false;
    }

    // ─── Phase 6.4f.2.a — sort buffers + pipelines + BindGroups ────────
    //
    // 5-kernel radix sort, 8 passes (4 bits/pass for 32-bit depth keys).
    // We dispatch enough workgroups for `total_splats` not `num_visible`
    // (the kernel reads num_keys_arr[0] internally and clamps), so the
    // dispatch count is CPU-known and constant-per-load.
    {
        constexpr std::uint32_t kBlockSize = 1024u;  // matches sort_count.wgsl
        constexpr std::uint32_t kBinCount  = 16u;
        const std::uint32_t num_blocks =
            (N + kBlockSize - 1u) / kBlockSize;
        // sort_reduce.wgsl emits one entry per workgroup. The number of
        // reduce workgroups is `BIN_COUNT * div_ceil(num_blocks,
        // BLOCK_SIZE)`, which for our N≤a few million is always 16
        // (single reduce-scan tier; brush extends to multi-tier for
        // billions of splats — out of scope here).
        const std::uint32_t num_reduce_groups =
            (num_blocks + kBlockSize - 1u) / kBlockSize;
        const std::uint32_t reduced_count =
            kBinCount * num_reduce_groups;
        s.sort_num_blocks        = num_blocks;
        s.sort_num_reduce_groups = num_reduce_groups;

        s.sort_keys_buf       = make_buf(N * sizeof(std::uint32_t),       "splat.sort_keys");
        s.sort_keys_alt_buf   = make_buf(N * sizeof(std::uint32_t),       "splat.sort_keys_alt");
        s.sort_values_buf     = make_buf(N * sizeof(std::uint32_t),       "splat.sort_values");
        s.sort_values_alt_buf = make_buf(N * sizeof(std::uint32_t),       "splat.sort_values_alt");
        s.sort_counts_buf     = make_buf(num_blocks * kBinCount * sizeof(std::uint32_t),
                                         "splat.sort_counts");
        s.sort_reduced_buf    = make_buf(reduced_count * sizeof(std::uint32_t),
                                         "splat.sort_reduced");
        s.sort_num_keys_arr_buf = make_buf(sizeof(std::uint32_t),
                                            "splat.sort_num_keys");
        if (!s.sort_keys_buf.valid() || !s.sort_keys_alt_buf.valid() ||
            !s.sort_values_buf.valid() || !s.sort_values_alt_buf.valid() ||
            !s.sort_counts_buf.valid() || !s.sort_reduced_buf.valid() ||
            !s.sort_num_keys_arr_buf.valid()) {
            scene_log("build_splat_scene: sort buffer alloc failed");
            r->splat_scene = std::move(s);
            free_splat_scene(r);
            return false;
        }
        // 8 config buffers, one per radix pass (shift = 0,4,8,…,28).
        for (std::uint32_t pass = 0; pass < 8u; ++pass) {
            s.sort_config_bufs[pass] = make_buf(sizeof(std::uint32_t),
                                                "splat.sort_config");
            if (!s.sort_config_bufs[pass].valid()) {
                scene_log("build_splat_scene: sort config buf %u alloc failed", pass);
                r->splat_scene = std::move(s);
                free_splat_scene(r);
                return false;
            }
            const std::uint32_t shift = pass * 4u;
            dev.update_buffer(s.sort_config_bufs[pass], &shift, 0, sizeof(shift));
        }

        // BGLs — one per kernel kind (sort_count + sort_scatter share
        // their BGL across all 8 passes; the per-pass differences are
        // limited to the bind groups themselves).
        s.sort_prep_bgl     = create_sort_prep_bgl(wd);
        s.sort_count_bgl    = create_sort_count_bgl(wd);
        s.sort_reduce_bgl   = create_sort_reduce_bgl(wd);
        s.sort_scan_bgl     = create_sort_scan_bgl(wd);
        s.sort_scan_add_bgl = create_sort_scan_add_bgl(wd);
        s.sort_scatter_bgl  = create_sort_scatter_bgl(wd);
        if (!s.sort_prep_bgl    || !s.sort_count_bgl  || !s.sort_reduce_bgl ||
            !s.sort_scan_bgl    || !s.sort_scan_add_bgl || !s.sort_scatter_bgl) {
            scene_log("build_splat_scene: sort BGL create failed");
            r->splat_scene = std::move(s);
            free_splat_scene(r);
            return false;
        }
        // Pipeline layouts (each is a single-BGL layout).
        auto make_pl = [&](WGPUBindGroupLayout bgl) {
            WGPUPipelineLayoutDescriptor pl = WGPU_PIPELINE_LAYOUT_DESCRIPTOR_INIT;
            pl.bindGroupLayoutCount = 1;
            pl.bindGroupLayouts = &bgl;
            return wgpuDeviceCreatePipelineLayout(wd, &pl);
        };
        s.sort_prep_layout     = make_pl(s.sort_prep_bgl);
        s.sort_count_layout    = make_pl(s.sort_count_bgl);
        s.sort_reduce_layout   = make_pl(s.sort_reduce_bgl);
        s.sort_scan_layout     = make_pl(s.sort_scan_bgl);
        s.sort_scan_add_layout = make_pl(s.sort_scan_add_bgl);
        s.sort_scatter_layout  = make_pl(s.sort_scatter_bgl);
        if (!s.sort_prep_layout    || !s.sort_count_layout  ||
            !s.sort_reduce_layout  || !s.sort_scan_layout   ||
            !s.sort_scan_add_layout|| !s.sort_scatter_layout) {
            scene_log("build_splat_scene: sort layout create failed");
            r->splat_scene = std::move(s);
            free_splat_scene(r);
            return false;
        }
        // Compute pipelines.
        s.sort_prep_pipe = create_compute_pipeline(wd,
            dawn_int::dawn_internal_get_shader_module(dev, r->sort_prep_shader, ep_unused),
            s.sort_prep_layout, "main");
        s.sort_count_pipe = create_compute_pipeline(wd,
            dawn_int::dawn_internal_get_shader_module(dev, r->sort_count_shader, ep_unused),
            s.sort_count_layout, "main");
        s.sort_reduce_pipe = create_compute_pipeline(wd,
            dawn_int::dawn_internal_get_shader_module(dev, r->sort_reduce_shader, ep_unused),
            s.sort_reduce_layout, "main");
        s.sort_scan_pipe = create_compute_pipeline(wd,
            dawn_int::dawn_internal_get_shader_module(dev, r->sort_scan_shader, ep_unused),
            s.sort_scan_layout, "main");
        s.sort_scan_add_pipe = create_compute_pipeline(wd,
            dawn_int::dawn_internal_get_shader_module(dev, r->sort_scan_add_shader, ep_unused),
            s.sort_scan_add_layout, "main");
        s.sort_scatter_pipe = create_compute_pipeline(wd,
            dawn_int::dawn_internal_get_shader_module(dev, r->sort_scatter_shader, ep_unused),
            s.sort_scatter_layout, "main");
        if (!s.sort_prep_pipe || !s.sort_count_pipe || !s.sort_reduce_pipe ||
            !s.sort_scan_pipe || !s.sort_scan_add_pipe || !s.sort_scatter_pipe) {
            scene_log("build_splat_scene: sort pipeline create failed");
            r->splat_scene = std::move(s);
            free_splat_scene(r);
            return false;
        }
    }

    // ─── Build BindGroups (cached for the life of the loaded scene) ────
    auto bind_buf = [&](GPUBufferHandle h, std::uint32_t binding) {
        WGPUBindGroupEntry e{};
        e.binding = binding;
        e.buffer = dawn_int::dawn_internal_get_buffer(dev, h);
        e.offset = 0;
        e.size = WGPU_WHOLE_SIZE;
        return e;
    };

    {
        // Phase 6.4f.3.a — packed format: 4 bindings.
        WGPUBindGroupEntry entries[4] = {
            bind_buf(r->splat_uniforms_buf, 0),
            bind_buf(s.packed_splats_buf, 1),
            bind_buf(s.global_from_compact_gid_buf, 2),
            bind_buf(s.depths_buf, 3),
        };
        WGPUBindGroupDescriptor bg = WGPU_BIND_GROUP_DESCRIPTOR_INIT;
        bg.layout = s.project_forward_bgl;
        bg.entryCount = 4;
        bg.entries = entries;
        s.project_forward_bg = wgpuDeviceCreateBindGroup(wd, &bg);
    }
    {
        // Phase 6.4f.3.a — packed format: 5 bindings (DC SH folded into
        // packed_splats; coeffs_non_dc holds the non-DC coefficients).
        WGPUBindGroupEntry entries[5] = {
            bind_buf(r->splat_uniforms_buf, 0),
            bind_buf(s.packed_splats_buf, 1),
            bind_buf(s.coeffs_non_dc_buf, 2),
            bind_buf(s.global_from_compact_gid_buf, 3),
            bind_buf(r->splats_buf, 4),
        };
        WGPUBindGroupDescriptor bg = WGPU_BIND_GROUP_DESCRIPTOR_INIT;
        bg.layout = s.project_visible_bgl;
        bg.entryCount = 5;
        bg.entries = entries;
        s.project_visible_bg = wgpuDeviceCreateBindGroup(wd, &bg);
    }
    {
        // Phase 6.4f.2.a: 3rd binding = sort_values_buf (the radix sort
        // permutation; splats[order[ii]] gives back-to-front order).
        WGPUBindGroupEntry entries[3] = {
            bind_buf(r->splat_uniforms_buf, 0),
            bind_buf(r->splats_buf, 1),
            bind_buf(s.sort_values_buf, 2),
        };
        WGPUBindGroupDescriptor bg = WGPU_BIND_GROUP_DESCRIPTOR_INIT;
        bg.layout = r->splat_render_bgl;
        bg.entryCount = 3;
        bg.entries = entries;
        s.splat_render_bg = wgpuDeviceCreateBindGroup(wd, &bg);
    }

    // ─── Phase 6.4f.2.a — sort BindGroups ──────────────────────────────
    //
    // sort_prep_depth, sort_reduce, sort_scan, sort_scan_add are
    // pass-invariant: 1 BG each. sort_count and sort_scatter alternate
    // src/out between (keys ↔ keys_alt) every pass — 8 BGs each.
    {
        WGPUBindGroupEntry entries[5] = {
            bind_buf(r->splat_uniforms_buf, 0),
            bind_buf(s.depths_buf, 1),
            bind_buf(s.sort_num_keys_arr_buf, 2),
            bind_buf(s.sort_keys_buf, 3),
            bind_buf(s.sort_values_buf, 4),
        };
        WGPUBindGroupDescriptor bg = WGPU_BIND_GROUP_DESCRIPTOR_INIT;
        bg.layout = s.sort_prep_bgl;
        bg.entryCount = 5;
        bg.entries = entries;
        s.sort_prep_bg = wgpuDeviceCreateBindGroup(wd, &bg);
    }
    {
        WGPUBindGroupEntry entries[3] = {
            bind_buf(s.sort_num_keys_arr_buf, 0),
            bind_buf(s.sort_counts_buf, 1),
            bind_buf(s.sort_reduced_buf, 2),
        };
        WGPUBindGroupDescriptor bg = WGPU_BIND_GROUP_DESCRIPTOR_INIT;
        bg.layout = s.sort_reduce_bgl;
        bg.entryCount = 3;
        bg.entries = entries;
        s.sort_reduce_bg = wgpuDeviceCreateBindGroup(wd, &bg);
    }
    {
        WGPUBindGroupEntry entries[2] = {
            bind_buf(s.sort_num_keys_arr_buf, 0),
            bind_buf(s.sort_reduced_buf, 1),
        };
        WGPUBindGroupDescriptor bg = WGPU_BIND_GROUP_DESCRIPTOR_INIT;
        bg.layout = s.sort_scan_bgl;
        bg.entryCount = 2;
        bg.entries = entries;
        s.sort_scan_bg = wgpuDeviceCreateBindGroup(wd, &bg);
    }
    {
        WGPUBindGroupEntry entries[3] = {
            bind_buf(s.sort_num_keys_arr_buf, 0),
            bind_buf(s.sort_reduced_buf, 1),
            bind_buf(s.sort_counts_buf, 2),
        };
        WGPUBindGroupDescriptor bg = WGPU_BIND_GROUP_DESCRIPTOR_INIT;
        bg.layout = s.sort_scan_add_bgl;
        bg.entryCount = 3;
        bg.entries = entries;
        s.sort_scan_add_bg = wgpuDeviceCreateBindGroup(wd, &bg);
    }
    // 8 sort_count BGs — even passes read keys, odd passes read keys_alt.
    for (std::uint32_t pass = 0; pass < 8u; ++pass) {
        const bool even = (pass % 2u) == 0u;
        const auto src = even ? s.sort_keys_buf : s.sort_keys_alt_buf;
        WGPUBindGroupEntry entries[4] = {
            bind_buf(s.sort_config_bufs[pass], 0),
            bind_buf(s.sort_num_keys_arr_buf, 1),
            bind_buf(src, 2),
            bind_buf(s.sort_counts_buf, 3),
        };
        WGPUBindGroupDescriptor bg = WGPU_BIND_GROUP_DESCRIPTOR_INIT;
        bg.layout = s.sort_count_bgl;
        bg.entryCount = 4;
        bg.entries = entries;
        s.sort_count_bgs[pass] = wgpuDeviceCreateBindGroup(wd, &bg);
    }
    // 8 sort_scatter BGs — alternate (keys/values → keys_alt/values_alt)
    // each pass. After 8 passes (last=odd), the sorted result is back in
    // (keys, values), which is what splat_render_bg points at via
    // sort_values_buf.
    for (std::uint32_t pass = 0; pass < 8u; ++pass) {
        const bool even = (pass % 2u) == 0u;
        const auto src       = even ? s.sort_keys_buf       : s.sort_keys_alt_buf;
        const auto vals      = even ? s.sort_values_buf     : s.sort_values_alt_buf;
        const auto out       = even ? s.sort_keys_alt_buf   : s.sort_keys_buf;
        const auto out_vals  = even ? s.sort_values_alt_buf : s.sort_values_buf;
        WGPUBindGroupEntry entries[7] = {
            bind_buf(s.sort_config_bufs[pass], 0),
            bind_buf(s.sort_num_keys_arr_buf, 1),
            bind_buf(src, 2),
            bind_buf(vals, 3),
            bind_buf(s.sort_counts_buf, 4),
            bind_buf(out, 5),
            bind_buf(out_vals, 6),
        };
        WGPUBindGroupDescriptor bg = WGPU_BIND_GROUP_DESCRIPTOR_INIT;
        bg.layout = s.sort_scatter_bgl;
        bg.entryCount = 7;
        bg.entries = entries;
        s.sort_scatter_bgs[pass] = wgpuDeviceCreateBindGroup(wd, &bg);
    }
    // BindGroup validity check — one cumulative test for all sort BGs.
    bool sort_bgs_ok = s.sort_prep_bg && s.sort_reduce_bg &&
                       s.sort_scan_bg && s.sort_scan_add_bg;
    for (int i = 0; i < 8 && sort_bgs_ok; ++i) {
        sort_bgs_ok = s.sort_count_bgs[i] && s.sort_scatter_bgs[i];
    }
    if (!s.project_forward_bg || !s.project_visible_bg || !s.splat_render_bg ||
        !sort_bgs_ok) {
        scene_log("build_splat_scene: BindGroup create failed");
        r->splat_scene = std::move(s);
        free_splat_scene(r);
        return false;
    }

    scene_log("loaded splat scene: %u splats, sh_degree=%u, "
              "bounds [%.3f..%.3f, %.3f..%.3f, %.3f..%.3f]",
              N, s.sh_degree,
              s.bounds_min[0], s.bounds_max[0],
              s.bounds_min[1], s.bounds_max[1],
              s.bounds_min[2], s.bounds_max[2]);

    r->splat_scene = std::move(s);
    r->has_splats = true;
    return true;
}

// ─── Phase 6.4f.3.d — octree LOD subsample ─────────────────────────────
//
// Replaces the naïve stride decimation with a proper hierarchical
// importance-weighted subsample: build an octree of the input
// gaussians, subdivide breadth-first until the leaf count approaches
// the target, then emit one representative splat per leaf chosen by
// visual importance (opacity × scale-volume). This is the "load-time
// LOD" pattern used by Spark `tiny-lod` and PlayCanvas `build-lod` —
// it preserves dense-region detail and silhouette far better than
// stride sampling, at the same target splat count.
//
// Runtime GPU LOD (per-frame node selection based on screen-space
// projected radius — Octree-GS style) is the next step, tracked as
// Phase 6.4f.4. The current load-time octree gives the bulk of the
// memory + rendering perf win without needing a new GPU kernel.
namespace {

struct OctNode {
    float aabb_min[3];
    float aabb_max[3];
    std::vector<std::uint32_t> splat_indices;
};

inline float visual_importance(const ::aether::splat::GaussianParams& g) noexcept {
    // opacity × scale-volume — bigger and more opaque splats win.
    // Use abs so flipped-handed scales still rank, take a small floor
    // so degenerate scales don't all tie at 0.
    const float vol = std::abs(g.scale[0] * g.scale[1] * g.scale[2]) + 1e-12f;
    return g.opacity * vol;
}

inline std::vector<std::uint32_t> octree_subsample_indices(
    const std::vector<::aether::splat::GaussianParams>& gaussians,
    std::uint32_t target_count,
    std::uint32_t max_depth = 7u,
    std::uint32_t leaf_max = 4u)
{
    const std::size_t N = gaussians.size();
    if (N == 0u || target_count >= N) {
        std::vector<std::uint32_t> all(N);
        for (std::size_t i = 0; i < N; ++i) all[i] = static_cast<std::uint32_t>(i);
        return all;
    }

    OctNode root;
    root.aabb_min[0] = root.aabb_min[1] = root.aabb_min[2] = 1e30f;
    root.aabb_max[0] = root.aabb_max[1] = root.aabb_max[2] = -1e30f;
    root.splat_indices.resize(N);
    for (std::size_t i = 0; i < N; ++i) {
        root.splat_indices[i] = static_cast<std::uint32_t>(i);
        for (int c = 0; c < 3; ++c) {
            root.aabb_min[c] = std::min(root.aabb_min[c], gaussians[i].position[c]);
            root.aabb_max[c] = std::max(root.aabb_max[c], gaussians[i].position[c]);
        }
    }

    auto split = [&](OctNode& n) -> std::vector<OctNode> {
        const float cx = (n.aabb_min[0] + n.aabb_max[0]) * 0.5f;
        const float cy = (n.aabb_min[1] + n.aabb_max[1]) * 0.5f;
        const float cz = (n.aabb_min[2] + n.aabb_max[2]) * 0.5f;
        std::vector<OctNode> children(8);
        for (int o = 0; o < 8; ++o) {
            children[o].aabb_min[0] = (o & 1) ? cx : n.aabb_min[0];
            children[o].aabb_max[0] = (o & 1) ? n.aabb_max[0] : cx;
            children[o].aabb_min[1] = (o & 2) ? cy : n.aabb_min[1];
            children[o].aabb_max[1] = (o & 2) ? n.aabb_max[1] : cy;
            children[o].aabb_min[2] = (o & 4) ? cz : n.aabb_min[2];
            children[o].aabb_max[2] = (o & 4) ? n.aabb_max[2] : cz;
        }
        for (auto idx : n.splat_indices) {
            const auto& g = gaussians[idx];
            int o = 0;
            if (g.position[0] >= cx) o |= 1;
            if (g.position[1] >= cy) o |= 2;
            if (g.position[2] >= cz) o |= 4;
            children[o].splat_indices.push_back(idx);
        }
        // Drop empty octants and degenerate splits (all in one octant).
        std::vector<OctNode> kept;
        kept.reserve(8);
        for (auto& c : children) {
            if (!c.splat_indices.empty()) kept.push_back(std::move(c));
        }
        return kept;
    };

    std::vector<OctNode> queue;
    queue.push_back(std::move(root));
    std::vector<OctNode> leaves;
    leaves.reserve(target_count);

    for (std::uint32_t depth = 0;
         depth < max_depth && !queue.empty() &&
             (leaves.size() + queue.size()) < target_count;
         ++depth) {
        std::vector<OctNode> next;
        next.reserve(queue.size() * 4);
        for (auto& n : queue) {
            // Stop subdividing if the leaf budget is met or this node is
            // already small.
            if (n.splat_indices.size() <= leaf_max ||
                (leaves.size() + next.size() + queue.size()) >= target_count) {
                leaves.push_back(std::move(n));
                continue;
            }
            auto children = split(n);
            if (children.size() <= 1u) {
                // Degenerate split (all splats co-located) — keep as leaf.
                leaves.push_back(std::move(n));
                continue;
            }
            for (auto& c : children) next.push_back(std::move(c));
        }
        queue = std::move(next);
    }
    for (auto& n : queue) leaves.push_back(std::move(n));

    // Pick one representative splat per leaf, weighted by visual
    // importance. This single-rep-per-leaf is the "tiny-lod" tier in
    // Spark's terminology — for higher quality we'd emit a *merged*
    // splat (Bhattacharyya-fit gaussian over the leaf members). That's
    // 6.4f.4 territory; the single-rep approximation is what
    // PlayCanvas's build-lod ships by default.
    std::vector<std::uint32_t> selected;
    selected.reserve(leaves.size());
    for (auto& leaf : leaves) {
        std::uint32_t best = leaf.splat_indices[0];
        float best_imp = visual_importance(gaussians[best]);
        for (auto idx : leaf.splat_indices) {
            const float imp = visual_importance(gaussians[idx]);
            if (imp > best_imp) { best = idx; best_imp = imp; }
        }
        selected.push_back(best);
    }
    return selected;
}

}  // namespace

// ─── Phase 6.4f.3.b — load-time caps (max_splats + max_sh_degree) ──────
//
// Applied after the file is decoded but before GPU upload. Two effects:
//
//   1. max_sh_degree clamps result.sh_degree DOWN, and truncates
//      result.sh_rest accordingly. Per channel slot count goes:
//        deg 0 → 0 floats, deg 1 → 9, deg 2 → 24, deg 3 → 45.
//      For PocketWorld feed thumbnails (texture longSide < 256 px) the
//      higher-order SH is imperceptible, but it's the dominant source
//      of GPU memory at high resolutions: 45 × 4 = 180 B/splat at deg 3
//      vs 0 B at deg 0.
//
//   2. max_splats > 0 evicts gaussians via deterministic stride
//      subsample (every k-th element where k = ceil(N / max_splats)).
//      This is a coarse LOD baseline — per-tile / per-octree-node LOD
//      is Phase 6.4f.3.d. Stride subsampling preserves overall scene
//      coverage but does NOT preserve fine detail; it's intended for
//      feed-card thumbnails where 50k splats reads "lizard-shaped" at
//      thumbnail resolution as well as 786k does.
static void apply_load_caps(
    std::vector<::aether::splat::GaussianParams>& gaussians,
    std::vector<float>& sh_rest,
    std::uint32_t& sh_degree,
    std::uint32_t max_splats,
    std::uint8_t max_sh_degree)
{
    auto coeffs_per_basis = [](std::uint32_t d) -> std::uint32_t {
        // non-DC basis count: 0,3,8,15 for deg 0,1,2,3.
        if (d == 0u) return 0u;
        if (d == 1u) return 3u;
        if (d == 2u) return 8u;
        return 15u;
    };

    // ── (1) Clamp SH degree ───────────────────────────────────────────
    if (max_sh_degree < 3u && sh_degree > max_sh_degree) {
        const std::uint32_t old_basis = coeffs_per_basis(sh_degree);
        const std::uint32_t new_basis = coeffs_per_basis(
            static_cast<std::uint32_t>(max_sh_degree));
        if (new_basis == 0u) {
            sh_rest.clear();
        } else if (old_basis > new_basis && !sh_rest.empty()) {
            // PLY-native SH layout: sh_rest[i * (3 * old_basis) +
            //   channel * old_basis + basis]. To downsize, repack into
            //   sh_rest_new[i * (3 * new_basis) + channel * new_basis + basis]
            //   keeping basis ∈ [0, new_basis).
            const std::size_t N = gaussians.size();
            std::vector<float> trimmed(N * 3u * new_basis);
            for (std::size_t i = 0; i < N; ++i) {
                for (std::uint32_t c = 0; c < 3u; ++c) {
                    const std::size_t src_off = i * 3u * old_basis + c * old_basis;
                    const std::size_t dst_off = i * 3u * new_basis + c * new_basis;
                    for (std::uint32_t b = 0; b < new_basis; ++b) {
                        trimmed[dst_off + b] = sh_rest[src_off + b];
                    }
                }
            }
            sh_rest = std::move(trimmed);
        }
        sh_degree = static_cast<std::uint32_t>(max_sh_degree);
    }

    // ── (2) Octree-based importance-weighted subsample (Phase 6.4f.3.d)
    if (max_splats > 0u && gaussians.size() > max_splats) {
        const std::vector<std::uint32_t> indices =
            octree_subsample_indices(gaussians, max_splats);
        std::vector<::aether::splat::GaussianParams> kept;
        kept.reserve(indices.size());
        const std::uint32_t basis = coeffs_per_basis(sh_degree);
        std::vector<float> sh_kept;
        if (basis > 0u && !sh_rest.empty()) {
            sh_kept.reserve(indices.size() * 3u * basis);
        }
        for (auto i : indices) {
            kept.push_back(gaussians[i]);
            if (basis > 0u && !sh_rest.empty()) {
                const std::size_t src = static_cast<std::size_t>(i) * 3u * basis;
                for (std::uint32_t c = 0; c < 3u; ++c) {
                    for (std::uint32_t b = 0; b < basis; ++b) {
                        sh_kept.push_back(sh_rest[src + c * basis + b]);
                    }
                }
            }
        }
        gaussians = std::move(kept);
        sh_rest = std::move(sh_kept);
    }
}

// Phase 6.4f.3.c — build a stable per-load cache key. Same path with
// the same caps + same on-disk mtime maps to the same SplatData. mtime
// guards against the user re-downloading content into the same path.
// Format: "ext|absolute_path|mtime_ns|max_splats|max_sh_degree".
static std::string make_cache_key(const char* ext,
                                   const char* path,
                                   std::uint32_t max_splats,
                                   std::uint8_t max_sh_degree) {
    std::int64_t mtime = 0;
    struct stat st{};
    if (path && stat(path, &st) == 0) {
#if defined(__APPLE__)
        mtime = static_cast<std::int64_t>(st.st_mtimespec.tv_sec) * 1'000'000'000LL +
                static_cast<std::int64_t>(st.st_mtimespec.tv_nsec);
#else
        mtime = static_cast<std::int64_t>(st.st_mtime);
#endif
    }
    char buf[1024];
    std::snprintf(buf, sizeof(buf), "%s|%s|%lld|%u|%u",
                  ext ? ext : "?",
                  path ? path : "",
                  static_cast<long long>(mtime),
                  static_cast<unsigned>(max_splats),
                  static_cast<unsigned>(max_sh_degree));
    return std::string(buf);
}

static bool load_ply_into_renderer(
    AetherSceneRenderer* r,
    const char* ply_path,
    std::uint32_t max_splats,
    std::uint8_t max_sh_degree)
{
    if (!r || !ply_path) return false;
    ::aether::splat::PlyLoadResult result;
    auto status = ::aether::splat::load_ply(ply_path, result);
    if (!::aether::core::is_ok(status)) {
        scene_log("load_ply: parse failed status=%d path='%s'",
                  static_cast<int>(status), ply_path);
        return false;
    }
    if (result.gaussians.empty()) {
        scene_log("load_ply: no gaussians in '%s'", ply_path);
        return false;
    }
    std::uint32_t sh_degree = result.sh_degree;
    apply_load_caps(result.gaussians, result.sh_rest, sh_degree,
                    max_splats, max_sh_degree);
    const float* sh_rest = result.sh_rest.empty() ? nullptr : result.sh_rest.data();
    const std::string key = make_cache_key("ply", ply_path,
                                            max_splats, max_sh_degree);
    if (!build_splat_scene_from_gaussians(r, result.gaussians,
                                           sh_degree, sh_rest, key)) {
        scene_log("load_ply: build_splat_scene failed for '%s'", ply_path);
        return false;
    }
    scene_log("load_ply: '%s' kept=%zu sh_degree=%u (cap max_splats=%u max_sh=%u)",
              ply_path, result.gaussians.size(),
              static_cast<unsigned>(sh_degree),
              max_splats, static_cast<unsigned>(max_sh_degree));
    return true;
}

static bool load_spz_into_renderer(
    AetherSceneRenderer* r,
    const char* spz_path,
    std::uint32_t max_splats,
    std::uint8_t max_sh_degree)
{
    if (!r || !spz_path) return false;
    ::aether::splat::SpzDecodeResult spz_result;
    auto status = ::aether::splat::load_spz(spz_path, spz_result);
    if (!::aether::core::is_ok(status)) {
        scene_log("load_spz: parse/decode failed status=%d path='%s'",
                  static_cast<int>(status), spz_path);
        return false;
    }
    if (spz_result.gaussians.empty()) {
        scene_log("load_spz: no gaussians in '%s'", spz_path);
        return false;
    }
    // SPZ decoder doesn't unpack higher-order SH today (only DC). Force
    // sh_degree=0 so project_visible doesn't read from a missing buffer.
    // The cap helper still runs for stride-subsample side-effect.
    std::uint32_t sh_degree = 0u;
    std::vector<float> empty_sh;
    apply_load_caps(spz_result.gaussians, empty_sh, sh_degree,
                    max_splats, /*max_sh_degree=*/0u);
    const std::string key = make_cache_key("spz", spz_path,
                                            max_splats, max_sh_degree);
    if (!build_splat_scene_from_gaussians(r, spz_result.gaussians,
                                           /*sh_degree=*/0u, /*sh_rest=*/nullptr,
                                           key)) {
        scene_log("load_spz: build_splat_scene failed for '%s'", spz_path);
        return false;
    }
    (void)max_sh_degree;  // SPZ SH unpack is a follow-up — see PHASE_BACKLOG.
    return true;
}

extern "C" bool aether_scene_renderer_load_ply(AetherSceneRenderer* r,
                                                 const char* ply_path) {
    return load_ply_into_renderer(r, ply_path, /*max_splats=*/0u,
                                   /*max_sh_degree=*/3u);
}

extern "C" bool aether_scene_renderer_load_spz(AetherSceneRenderer* r,
                                                 const char* spz_path) {
    return load_spz_into_renderer(r, spz_path, /*max_splats=*/0u,
                                   /*max_sh_degree=*/3u);
}

extern "C" bool aether_scene_renderer_load_ply_capped(
    AetherSceneRenderer* r,
    const char* ply_path,
    uint32_t max_splats,
    uint8_t max_sh_degree)
{
    return load_ply_into_renderer(r, ply_path, max_splats, max_sh_degree);
}

extern "C" bool aether_scene_renderer_load_spz_capped(
    AetherSceneRenderer* r,
    const char* spz_path,
    uint32_t max_splats,
    uint8_t max_sh_degree)
{
    return load_spz_into_renderer(r, spz_path, max_splats, max_sh_degree);
}

extern "C" bool aether_scene_renderer_get_bounds(AetherSceneRenderer* r,
                                                  float* out_min,
                                                  float* out_max) {
    if (!r || !out_min || !out_max) return false;
    if (r->has_mesh && r->loaded_mesh) {
        const auto& m = *r->loaded_mesh;
        out_min[0] = m.bounds_min[0];
        out_min[1] = m.bounds_min[1];
        out_min[2] = m.bounds_min[2];
        out_max[0] = m.bounds_max[0];
        out_max[1] = m.bounds_max[1];
        out_max[2] = m.bounds_max[2];
        return true;
    }
    if (r->has_splats && r->splat_scene) {
        const auto& s = *r->splat_scene;
        out_min[0] = s.bounds_min[0];
        out_min[1] = s.bounds_min[1];
        out_min[2] = s.bounds_min[2];
        out_max[0] = s.bounds_max[0];
        out_max[1] = s.bounds_max[1];
        out_max[2] = s.bounds_max[2];
        return true;
    }
    return false;
}

extern "C" void aether_scene_renderer_render_full(
    AetherSceneRenderer* r,
    const float* view_matrix,
    const float* model_matrix
) {
    if (!r || !r->device || !view_matrix || !model_matrix) return;
    using namespace ::aether::render;
    auto& dev = *(r->device);
    if (!is_dawn(&dev)) return;

    // Update mesh uniforms from caller matrices.
    if (r->has_mesh && r->loaded_mesh) {
        // Camera: view_proj = perspective(60°, aspect, near, far) * view.
        // Aspect: width/height from IOSurface dims.
        //
        // G4: previously hardcoded near=0.1, far=100. That fails for any
        // GLB that lives outside a unit cube — the Khronos ToyCar
        // sample has a half-diagonal r≈540, so the camera fit puts the
        // eye at ~2900 units and the entire model is past the far
        // plane → black texture. Derive near/far from the loaded
        // bounds: near floored at 0.01 (Corset has r≈0.04, so r*0.5
        // is safe), far at 100×r so even pinch-out / orbit-zoom-out
        // gestures don't trip the plane mid-frame.
        const auto& m = *r->loaded_mesh;
        const float hx = (m.bounds_max[0] - m.bounds_min[0]) * 0.5f;
        const float hy = (m.bounds_max[1] - m.bounds_min[1]) * 0.5f;
        const float hz = (m.bounds_max[2] - m.bounds_min[2]) * 0.5f;
        const float bounds_radius = std::sqrt(hx*hx + hy*hy + hz*hz);
        const float near_plane = (bounds_radius > 0.0f)
            ? std::max(0.01f, bounds_radius * 0.5f) : 0.1f;
        const float far_plane = (bounds_radius > 0.0f)
            ? bounds_radius * 100.0f : 100.0f;
        const float aspect = static_cast<float>(r->width) /
                             static_cast<float>(r->height);
        float proj[16];
        mat4_perspective(proj, 60.0f * 3.14159265f / 180.0f, aspect,
                         near_plane, far_plane);
        CameraUniforms cam{};
        mat4_mul(cam.view_proj, proj, view_matrix);
        // camera_pos: extract from inverse-view's translation column. For
        // an orbit lookAt view matrix, camera world position = -R^T * t
        // where t = view.col3.xyz. Approximation: use distance derived
        // from view_t.z (works for our z-aligned orbit).
        cam.camera_pos[0] = -view_matrix[12];
        cam.camera_pos[1] = -view_matrix[13];
        cam.camera_pos[2] = -view_matrix[14];
        cam.camera_pos[3] = 1.0f;
        r->device->update_buffer(r->mesh_camera_buf, &cam, 0, sizeof(cam));

        // Model: caller-supplied; normal_mat = inverse-transpose 3x3 of model.
        ModelTransform mt{};
        std::memcpy(mt.model, model_matrix, sizeof(mt.model));
        mat4_inverse_3x3_transpose(mt.normal_mat, model_matrix);
        r->device->update_buffer(r->mesh_model_buf, &mt, 0, sizeof(mt));
    }

    // Phase 6.4f: per-frame splat uniforms. project_forward atomically
    // increments num_visible from 0 each frame, so we MUST reset it
    // before dispatch. Other fields are stable for the loaded scene
    // (total_splats, sh_degree) but recomputed from the splat scene
    // each frame for clarity. focal length derived from a fixed 60°
    // vertical FOV — matches the mesh path's projection.
    if (r->has_splats && r->splat_scene) {
        RenderArgsStorage splat_u = make_empty_uniforms(r->width, r->height);
        std::memcpy(splat_u.viewmat, view_matrix, 16 * sizeof(float));
        // Match the mesh-pass FOV = 60° vertical → focal_y = (h/2) / tan(30°)
        // ≈ h * 0.866. Apply same focal_x for square pixels (no anamorphism).
        const float fov_y_rad = 60.0f * 3.14159265f / 180.0f;
        const float focal = static_cast<float>(r->height) * 0.5f /
                            std::tan(fov_y_rad * 0.5f);
        splat_u.focal[0] = focal;
        splat_u.focal[1] = focal;
        splat_u.total_splats = r->splat_scene->num_splats;
        splat_u.num_visible = 0;
        splat_u.sh_degree = r->splat_scene->sh_degree;
        // ─── Phase 6.4f.2.b/c — camera world position for SH eval ──────
        //
        // project_visible.wgsl evaluates view-dependent SH per-splat
        // using viewdir = normalize(mean - camera_position). The view
        // matrix is world→camera; camera world position is the column 3
        // of its inverse. For a rigid (rotation + translation) view
        // matrix VM = [R | t; 0 0 0 1] in column-major storage where
        //   R = (vm[0..2], vm[4..6], vm[8..10]) (3 column-major basis vectors)
        //   t = vm[12..14]
        // the inverse is [R^T | -R^T t]. Camera world pos = -R^T * t.
        const float* vm = view_matrix;
        const float tx = vm[12], ty = vm[13], tz = vm[14];
        const float cam_x = -(vm[0] * tx + vm[1] * ty + vm[2]  * tz);
        const float cam_y = -(vm[4] * tx + vm[5] * ty + vm[6]  * tz);
        const float cam_z = -(vm[8] * tx + vm[9] * ty + vm[10] * tz);
        splat_u.camera_position[0] = cam_x;
        splat_u.camera_position[1] = cam_y;
        splat_u.camera_position[2] = cam_z;
        splat_u.camera_position[3] = 1.0f;
        r->device->update_buffer(r->splat_uniforms_buf, &splat_u, 0, sizeof(splat_u));
    }

    // BeginAccess fence on IOSurface.
    if (!dawn_iosurface_begin_access(*r->device, r->iosurface_tex)) return;

    // Build texture views once for this frame.
    WGPUTexture color_tex = dawn_int::dawn_internal_get_texture(dev, r->iosurface_tex);
    WGPUTexture depth_tex = dawn_int::dawn_internal_get_texture(dev, r->depth_tex);
    WGPUTextureViewDescriptor v_desc = WGPU_TEXTURE_VIEW_DESCRIPTOR_INIT;
    WGPUTextureView color_view = wgpuTextureCreateView(color_tex, &v_desc);
    WGPUTextureView depth_view = wgpuTextureCreateView(depth_tex, &v_desc);

    // Encode + submit + wait.
    WGPUCommandEncoderDescriptor enc_desc = WGPU_COMMAND_ENCODER_DESCRIPTOR_INIT;
    WGPUCommandEncoder encoder = wgpuDeviceCreateCommandEncoder(
        dawn_int::dawn_internal_wgpu_device(dev), &enc_desc);

    // Phase 6.4f: when a splat scene is loaded, run the 2-kernel projection
    // chain BEFORE any render passes so the projected_splats buffer is
    // ready for splat_render to consume.
    //
    // Frame structure (pseudo-code):
    //   if has_splats:
    //     clearBuffer(projected_splats)      // ensures no stale alpha
    //     computePass:
    //       project_forward                  // atomic num_visible, depths,
    //                                        // global_from_compact_gid
    //       project_visible                  // SH eval + cov2d → ProjectedSplat
    //   if has_mesh:
    //     mesh_pass                          // clears color + depth, draws mesh
    //   elif has_splats:
    //     clear_pass                         // clears color + depth (no mesh
    //                                        // before splats; splat depth-test
    //                                        // needs cleared depth)
    //   else:
    //     empty_card_pass                    // just clears color
    //   if has_splats:
    //     splat_render_pass                  // loads color+depth from prior
    //                                        // pass; instanced quads with
    //                                        // discard for invalid splats
    if (r->has_splats && r->splat_scene) {
        auto& s = *r->splat_scene;
        // Clear projected_splats so any instance index ≥ num_visible
        // (i.e. project_visible never wrote to it) has alpha=0 → discarded
        // by splat_render's fragment shader. This eliminates the need for
        // a CPU-side num_visible readback before the render pass.
        const std::uint64_t projected_bytes = static_cast<std::uint64_t>(
            s.num_splats) * sizeof(ProjectedSplatLayout);
        wgpuCommandEncoderClearBuffer(encoder,
            dawn_int::dawn_internal_get_buffer(dev, r->splats_buf),
            0, projected_bytes);

        WGPUComputePassDescriptor cpass_desc = WGPU_COMPUTE_PASS_DESCRIPTOR_INIT;
        WGPUComputePassEncoder cpass = wgpuCommandEncoderBeginComputePass(
            encoder, &cpass_desc);

        const std::uint32_t wg_x = (s.num_splats + 255u) / 256u;

        wgpuComputePassEncoderSetPipeline(cpass, s.project_forward_pipe);
        wgpuComputePassEncoderSetBindGroup(cpass, 0, s.project_forward_bg, 0, nullptr);
        wgpuComputePassEncoderDispatchWorkgroups(cpass, wg_x, 1, 1);

        wgpuComputePassEncoderSetPipeline(cpass, s.project_visible_pipe);
        wgpuComputePassEncoderSetBindGroup(cpass, 0, s.project_visible_bg, 0, nullptr);
        wgpuComputePassEncoderDispatchWorkgroups(cpass, wg_x, 1, 1);

        // ─── Phase 6.4f.2.a — depth sort (sort_prep + 8 radix passes) ──
        //
        // sort_prep_depth seeds keys[]/values[] from depths[]/uniforms.
        // Then 8 ping-pong radix passes (4-bit/pass × 8 = 32-bit key)
        // execute count → reduce → scan → scan_add → scatter. After
        // pass 7 (last, odd-indexed), the sorted permutation lives in
        // (sort_keys_buf, sort_values_buf), which splat_render_bg
        // already binds at slot 2.
        wgpuComputePassEncoderSetPipeline(cpass, s.sort_prep_pipe);
        wgpuComputePassEncoderSetBindGroup(cpass, 0, s.sort_prep_bg, 0, nullptr);
        wgpuComputePassEncoderDispatchWorkgroups(cpass, wg_x, 1, 1);

        // Per-pass dispatch counts.
        const std::uint32_t count_wg     = s.sort_num_blocks;       // ceil(N/1024)
        const std::uint32_t reduce_wg    = 16u * s.sort_num_reduce_groups;
        const std::uint32_t scan_wg      = 1u;                      // single workgroup
        const std::uint32_t scan_add_wg  = reduce_wg;               // mirrors reduce
        const std::uint32_t scatter_wg   = s.sort_num_blocks;
        for (std::uint32_t pass = 0; pass < 8u; ++pass) {
            wgpuComputePassEncoderSetPipeline(cpass, s.sort_count_pipe);
            wgpuComputePassEncoderSetBindGroup(cpass, 0,
                s.sort_count_bgs[pass], 0, nullptr);
            wgpuComputePassEncoderDispatchWorkgroups(cpass, count_wg, 1, 1);

            wgpuComputePassEncoderSetPipeline(cpass, s.sort_reduce_pipe);
            wgpuComputePassEncoderSetBindGroup(cpass, 0,
                s.sort_reduce_bg, 0, nullptr);
            wgpuComputePassEncoderDispatchWorkgroups(cpass, reduce_wg, 1, 1);

            wgpuComputePassEncoderSetPipeline(cpass, s.sort_scan_pipe);
            wgpuComputePassEncoderSetBindGroup(cpass, 0,
                s.sort_scan_bg, 0, nullptr);
            wgpuComputePassEncoderDispatchWorkgroups(cpass, scan_wg, 1, 1);

            wgpuComputePassEncoderSetPipeline(cpass, s.sort_scan_add_pipe);
            wgpuComputePassEncoderSetBindGroup(cpass, 0,
                s.sort_scan_add_bg, 0, nullptr);
            wgpuComputePassEncoderDispatchWorkgroups(cpass, scan_add_wg, 1, 1);

            wgpuComputePassEncoderSetPipeline(cpass, s.sort_scatter_pipe);
            wgpuComputePassEncoderSetBindGroup(cpass, 0,
                s.sort_scatter_bgs[pass], 0, nullptr);
            wgpuComputePassEncoderDispatchWorkgroups(cpass, scatter_wg, 1, 1);
        }

        wgpuComputePassEncoderEnd(cpass);
        wgpuComputePassEncoderRelease(cpass);
    }

    // Color/depth setup pass. Mesh path clears + draws; splat-only path
    // just clears so splat_render has a defined background to blend over.
    if (r->has_mesh) {
        encode_mesh_pass(encoder, color_view, depth_view, r);
    } else if (r->has_splats) {
        // Splat-only render: clear color + depth so the subsequent
        // splat_render pass blends over a clean transparent target with
        // a clear depth (which it then read-only-tests against, currently
        // accepting all fragments since depth=1 ≥ near-plane writes).
        WGPURenderPassColorAttachment color_attach =
            WGPU_RENDER_PASS_COLOR_ATTACHMENT_INIT;
        color_attach.view = color_view;
        color_attach.loadOp = WGPULoadOp_Clear;
        color_attach.storeOp = WGPUStoreOp_Store;
        color_attach.clearValue = {0.0, 0.0, 0.0, 0.0};
        color_attach.depthSlice = WGPU_DEPTH_SLICE_UNDEFINED;
        WGPURenderPassDepthStencilAttachment depth_attach =
            WGPU_RENDER_PASS_DEPTH_STENCIL_ATTACHMENT_INIT;
        depth_attach.view = depth_view;
        depth_attach.depthLoadOp = WGPULoadOp_Clear;
        depth_attach.depthClearValue = 1.0f;
        depth_attach.depthStoreOp = WGPUStoreOp_Store;
        depth_attach.depthReadOnly = WGPU_FALSE;
        WGPURenderPassDescriptor pass_desc = WGPU_RENDER_PASS_DESCRIPTOR_INIT;
        pass_desc.colorAttachmentCount = 1;
        pass_desc.colorAttachments = &color_attach;
        pass_desc.depthStencilAttachment = &depth_attach;
        WGPURenderPassEncoder pass = wgpuCommandEncoderBeginRenderPass(
            encoder, &pass_desc);
        wgpuRenderPassEncoderEnd(pass);
        wgpuRenderPassEncoderRelease(pass);
    } else {
        // Empty card: clear the color attachment to transparent so
        // the Flutter compositor sees no leftover pixels from the
        // previous frame. We accomplish this with a no-op render
        // pass that just runs `loadOp = Clear` then `Store` without
        // drawing anything.
        WGPURenderPassColorAttachment color_attach =
            WGPU_RENDER_PASS_COLOR_ATTACHMENT_INIT;
        color_attach.view = color_view;
        color_attach.loadOp = WGPULoadOp_Clear;
        color_attach.storeOp = WGPUStoreOp_Store;
        color_attach.clearValue = {0.0, 0.0, 0.0, 0.0};
        color_attach.depthSlice = WGPU_DEPTH_SLICE_UNDEFINED;
        WGPURenderPassDescriptor pass_desc =
            WGPU_RENDER_PASS_DESCRIPTOR_INIT;
        pass_desc.colorAttachmentCount = 1;
        pass_desc.colorAttachments = &color_attach;
        WGPURenderPassEncoder pass =
            wgpuCommandEncoderBeginRenderPass(encoder, &pass_desc);
        wgpuRenderPassEncoderEnd(pass);
        wgpuRenderPassEncoderRelease(pass);
    }

    // Phase 6.4f: splat render pass — instanced quads, premultiplied OVER
    // blend, depth-readonly (so splats hidden behind opaque mesh fragments
    // are clipped). Loads color + depth from the prior pass so it composes
    // on top.
    if (r->has_splats && r->splat_scene) {
        auto& s = *r->splat_scene;
        WGPURenderPassColorAttachment color_attach =
            WGPU_RENDER_PASS_COLOR_ATTACHMENT_INIT;
        color_attach.view = color_view;
        color_attach.loadOp = WGPULoadOp_Load;       // preserve mesh / clear color
        color_attach.storeOp = WGPUStoreOp_Store;
        color_attach.depthSlice = WGPU_DEPTH_SLICE_UNDEFINED;

        WGPURenderPassDepthStencilAttachment depth_attach =
            WGPU_RENDER_PASS_DEPTH_STENCIL_ATTACHMENT_INIT;
        depth_attach.view = depth_view;
        // Dawn validation: when depthReadOnly = TRUE, BOTH loadOp and
        // storeOp MUST be Undefined (the depth-stencil aspect is purely
        // sampled from existing texture state). When FALSE, both ops
        // must be set. xor — see the brief's "Dawn validation strict"
        // pitfall note.
        depth_attach.depthLoadOp = WGPULoadOp_Undefined;
        depth_attach.depthStoreOp = WGPUStoreOp_Undefined;
        depth_attach.depthReadOnly = WGPU_TRUE;

        WGPURenderPassDescriptor pass_desc = WGPU_RENDER_PASS_DESCRIPTOR_INIT;
        pass_desc.colorAttachmentCount = 1;
        pass_desc.colorAttachments = &color_attach;
        pass_desc.depthStencilAttachment = &depth_attach;

        WGPURenderPassEncoder pass = wgpuCommandEncoderBeginRenderPass(
            encoder, &pass_desc);
        wgpuRenderPassEncoderSetPipeline(pass, r->splat_pipe);
        wgpuRenderPassEncoderSetBindGroup(pass, 0, s.splat_render_bg, 0, nullptr);
        // 6 vertices/quad × num_splats instances. Vertex shader reads
        // splats[ii] from the projected_splats buffer; instances where
        // project_visible never wrote (alpha = 0 from frame-start clear)
        // get discarded in the fragment shader.
        wgpuRenderPassEncoderDraw(pass, /*vertex_count=*/6,
                                   /*instance_count=*/s.num_splats,
                                   /*first_vertex=*/0, /*first_instance=*/0);
        wgpuRenderPassEncoderEnd(pass);
        wgpuRenderPassEncoderRelease(pass);
    }

    WGPUCommandBufferDescriptor cb_desc = WGPU_COMMAND_BUFFER_DESCRIPTOR_INIT;
    WGPUCommandBuffer cmd = wgpuCommandEncoderFinish(encoder, &cb_desc);
    wgpuCommandEncoderRelease(encoder);
    wgpuQueueSubmit(dawn_int::dawn_internal_wgpu_queue(dev), 1, &cmd);
    wgpuCommandBufferRelease(cmd);

    // Wait for completion before EndAccess so Flutter's read sees fresh bytes.
    // Reuse the harness pattern (OnSubmittedWorkDone + WaitAny + UINT64_MAX).
    struct WaitState { bool done; bool err; };
    WaitState ws{false, false};
    WGPUQueueWorkDoneCallbackInfo info = WGPU_QUEUE_WORK_DONE_CALLBACK_INFO_INIT;
    info.mode = WGPUCallbackMode_WaitAnyOnly;
    info.callback = [](WGPUQueueWorkDoneStatus status,
                        WGPUStringView /*msg*/,
                        WGPU_NULLABLE void* userdata1,
                        WGPU_NULLABLE void* /*userdata2*/) {
        auto* s = static_cast<WaitState*>(userdata1);
        if (status == WGPUQueueWorkDoneStatus_Success) s->done = true;
        else s->err = true;
    };
    info.userdata1 = &ws;
    WGPUFuture fut = wgpuQueueOnSubmittedWorkDone(dawn_int::dawn_internal_wgpu_queue(dev), info);
    WGPUFutureWaitInfo wait{fut, false};
    wgpuInstanceWaitAny(dawn_int::dawn_internal_wgpu_instance(dev), 1, &wait, UINT64_MAX);
    if (ws.err) {
        scene_log("render_full: queue work done reported error");
    }

    wgpuTextureViewRelease(color_view);
    wgpuTextureViewRelease(depth_view);

    // EndAccess fence.
    dawn_iosurface_end_access(*r->device, r->iosurface_tex);
}

#else  // !AETHER_ENABLE_DAWN

#include "aether/pocketworld/scene_iosurface_renderer.h"
#include <cstdio>

extern "C" AetherSceneRenderer* aether_scene_renderer_create(void*, uint32_t, uint32_t) {
    std::fprintf(stderr, "[scene_iosurface_renderer] AETHER_ENABLE_DAWN=OFF; create returns NULL\n");
    return nullptr;
}
extern "C" void aether_scene_renderer_destroy(AetherSceneRenderer*) {}
extern "C" bool aether_scene_renderer_load_glb(AetherSceneRenderer*, const char*) { return false; }
extern "C" void aether_scene_renderer_render_full(AetherSceneRenderer*, const float*, const float*) {}

#endif  // AETHER_ENABLE_DAWN
