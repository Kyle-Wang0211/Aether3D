// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

// ─── Phase 6.4b stage 2 — IOSurface scene renderer (mesh + splat) ──────
//
// Two-pass IOSurface renderer:
//   Pass 1: GLB mesh (PBR via mesh_render.wgsl, Filament BRDF) — writes
//           color + depth. Skipped when no mesh is loaded.
//   Pass 2: splat overlay (vert+frag splat_render.wgsl) — reads depth
//           from pass 1 (no write), composes over mesh color via
//           premultiplied alpha. Same hardcoded screen-space splat
//           scene as splat_iosurface_renderer (Phase 6.4f tracks the
//           upgrade to Brush full pipeline).
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

#include "../render/dawn_gpu_device_internal.h"
#include "dawn_device_singleton.h"

#include <webgpu/webgpu.h>

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <optional>
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

// ─── Splat scene baseline (shared with splat_iosurface_renderer) ───────

struct ProjectedSplatLayout {
    float xy_x, xy_y;
    float conic_x, conic_y, conic_z;
    float color_r, color_g, color_b, color_a;
};
static_assert(sizeof(ProjectedSplatLayout) == 36, "matches WGSL ProjectedSplat");

constexpr std::uint32_t kNumSplats = 4;

const ProjectedSplatLayout kBaselineSplats[kNumSplats] = {
    {128.0f, 128.0f, 0.006061f, 0.0f, 0.006061f,  0.641f, 0.641f, 0.641f, 0.731059f},
    {128.0f, 128.0f, 0.024113f, 0.0f, 0.024113f,  0.641f, 0.641f, 0.641f, 0.731059f},
    {128.0f, 128.0f, 0.053767f, 0.0f, 0.053767f,  0.641f, 0.641f, 0.641f, 0.731059f},
    {128.0f, 128.0f, 0.094401f, 0.0f, 0.094401f,  0.641f, 0.641f, 0.641f, 0.731059f},
};

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

RenderArgsStorage make_baseline_uniforms(std::uint32_t w, std::uint32_t h) {
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
    u.num_visible = kNumSplats;
    u.total_splats = kNumSplats;
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

WGPURenderPipeline create_mesh_pipeline(WGPUDevice wd,
                                         WGPUShaderModule vs,
                                         WGPUShaderModule fs) {
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

    // ─── Color target + blend (no blending; mesh writes opaque) ────────
    WGPUColorTargetState color_target = WGPU_COLOR_TARGET_STATE_INIT;
    color_target.format = WGPUTextureFormat_BGRA8Unorm;  // matches IOSurface
    color_target.writeMask = WGPUColorWriteMask_All;
    // blend = nullptr → no blending (opaque mesh on top of cleared color)

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

// Splat overlay pipeline — same blend / topology as splat_iosurface_renderer
// but with depth-test enabled (read from pass 1) + no depth write.
WGPURenderPipeline create_splat_overlay_pipeline(WGPUDevice wd,
                                                  WGPUShaderModule vs,
                                                  WGPUShaderModule fs) {
    WGPUBlendState blend = WGPU_BLEND_STATE_INIT;
    blend.color.operation = WGPUBlendOperation_Add;
    blend.color.srcFactor = WGPUBlendFactor_One;
    blend.color.dstFactor = WGPUBlendFactor_OneMinusSrcAlpha;
    blend.alpha.operation = WGPUBlendOperation_Add;
    blend.alpha.srcFactor = WGPUBlendFactor_One;
    blend.alpha.dstFactor = WGPUBlendFactor_OneMinusSrcAlpha;

    WGPUColorTargetState color_target = WGPU_COLOR_TARGET_STATE_INIT;
    color_target.format = WGPUTextureFormat_BGRA8Unorm;
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

}  // namespace

// ═══════════════════════════════════════════════════════════════════════
// AetherSceneRenderer
// ═══════════════════════════════════════════════════════════════════════

struct AetherSceneRenderer {
    GPUDevice* device{nullptr};
    std::uint32_t width{0}, height{0};

    // Render targets
    GPUTextureHandle iosurface_tex;
    GPUTextureHandle depth_tex;

    // Splat path (always bound, overlay)
    GPUBufferHandle splat_uniforms_buf;
    GPUBufferHandle splats_buf;
    GPUShaderHandle splat_vs, splat_fs;
    WGPURenderPipeline splat_pipe{nullptr};

    // Mesh path (filled by load_glb)
    bool has_mesh{false};
    std::optional<LoadedMesh> loaded_mesh;
    GPUBufferHandle mesh_camera_buf;
    GPUBufferHandle mesh_model_buf;
    GPUBufferHandle mesh_light_buf;
    GPUBufferHandle mesh_factors_buf;
    GPUShaderHandle mesh_vs, mesh_fs;
    WGPURenderPipeline mesh_pipe{nullptr};
    WGPUSampler mesh_sampler{nullptr};

    // 1x1 fallback textures for missing PBR slots.
    GPUTextureHandle fallback_white;
    GPUTextureHandle fallback_flat_normal;
    GPUTextureHandle fallback_black;
};

// Helper: encode the splat overlay render pass.
static void encode_splat_pass(WGPUCommandEncoder encoder,
                               WGPUTextureView color_view,
                               WGPUTextureView depth_view,
                               WGPULoadOp color_load,
                               AetherSceneRenderer* r) {
    using namespace ::aether::render;
    auto& dev = *(r->device);
    if (!is_dawn(&dev)) return;

    WGPURenderPassColorAttachment color_attach = WGPU_RENDER_PASS_COLOR_ATTACHMENT_INIT;
    color_attach.view = color_view;
    color_attach.loadOp = color_load;
    color_attach.storeOp = WGPUStoreOp_Store;
    color_attach.clearValue = {0.0, 0.0, 0.0, 1.0};
    color_attach.depthSlice = WGPU_DEPTH_SLICE_UNDEFINED;

    WGPURenderPassDepthStencilAttachment depth_attach =
        WGPU_RENDER_PASS_DEPTH_STENCIL_ATTACHMENT_INIT;
    depth_attach.view = depth_view;
    // Depth has already been written by mesh pass (Load) OR is fresh
    // (Clear if no mesh). Either way splat doesn't write.
    depth_attach.depthLoadOp = (color_load == WGPULoadOp_Load)
        ? WGPULoadOp_Load : WGPULoadOp_Clear;
    depth_attach.depthClearValue = 1.0f;
    depth_attach.depthStoreOp = WGPUStoreOp_Store;
    depth_attach.depthReadOnly = WGPU_FALSE;  // pass 2 we need to keep depth around

    WGPURenderPassDescriptor pass_desc = WGPU_RENDER_PASS_DESCRIPTOR_INIT;
    pass_desc.colorAttachmentCount = 1;
    pass_desc.colorAttachments = &color_attach;
    pass_desc.depthStencilAttachment = &depth_attach;

    WGPURenderPassEncoder pass = wgpuCommandEncoderBeginRenderPass(encoder, &pass_desc);
    wgpuRenderPassEncoderSetPipeline(pass, r->splat_pipe);

    // Bind group: 2 storage buffers (uniforms + splats).
    WGPUBindGroupLayout bgl = wgpuRenderPipelineGetBindGroupLayout(r->splat_pipe, 0);
    WGPUBindGroupEntry entries[2] = {};
    entries[0].binding = 0;
    entries[0].buffer = dawn_int::dawn_internal_get_buffer(dev, r->splat_uniforms_buf);
    entries[0].offset = 0;
    entries[0].size = WGPU_WHOLE_SIZE;
    entries[1].binding = 1;
    entries[1].buffer = dawn_int::dawn_internal_get_buffer(dev, r->splats_buf);
    entries[1].offset = 0;
    entries[1].size = WGPU_WHOLE_SIZE;
    WGPUBindGroupDescriptor bg_desc = WGPU_BIND_GROUP_DESCRIPTOR_INIT;
    bg_desc.layout = bgl;
    bg_desc.entryCount = 2;
    bg_desc.entries = entries;
    WGPUBindGroup bg = wgpuDeviceCreateBindGroup(dawn_int::dawn_internal_wgpu_device(dev), &bg_desc);
    wgpuBindGroupLayoutRelease(bgl);
    wgpuRenderPassEncoderSetBindGroup(pass, 0, bg, 0, nullptr);
    wgpuRenderPassEncoderDraw(pass, /*vertex*/6, /*instance*/kNumSplats,
                                /*firstVertex*/0, /*firstInstance*/0);
    wgpuRenderPassEncoderEnd(pass);
    wgpuRenderPassEncoderRelease(pass);
    wgpuBindGroupRelease(bg);
}

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
    // Soft purple background so an all-black mesh is still distinguishable
    // from a missing-IOSurface state.
    color_attach.clearValue = {0.05, 0.04, 0.08, 1.0};
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

    WGPUBindGroupLayout bgl = wgpuRenderPipelineGetBindGroupLayout(r->mesh_pipe, 0);

    std::vector<WGPUBindGroup> bind_groups;
    bind_groups.reserve(mesh.primitives.size());

    for (auto& prim : mesh.primitives) {
        // Resolve per-material textures (with fallbacks).
        const PbrMaterial& mat = (prim.material_index < mesh.materials.size())
                                  ? mesh.materials[prim.material_index]
                                  : PbrMaterial{};

        auto resolve = [&](GPUTextureHandle h, GPUTextureHandle fallback) {
            return h.valid() ? dawn_int::dawn_internal_get_texture(dev, h)
                              : dawn_int::dawn_internal_get_texture(dev, fallback);
        };
        WGPUTexture base = resolve(mat.base_color_tex, r->fallback_white);
        WGPUTexture mr   = resolve(mat.metallic_roughness_tex, r->fallback_white);
        WGPUTexture nrm  = resolve(mat.normal_tex, r->fallback_flat_normal);
        WGPUTexture occ  = resolve(mat.occlusion_tex, r->fallback_white);
        WGPUTexture emis = resolve(mat.emissive_tex, r->fallback_black);
        if (!base || !mr || !nrm || !occ || !emis) {
            scene_log("mesh primitive: missing texture (skipping)");
            continue;
        }

        // Texture views (default — full mip range, color aspect).
        WGPUTextureViewDescriptor v_desc = WGPU_TEXTURE_VIEW_DESCRIPTOR_INIT;
        WGPUTextureView base_v = wgpuTextureCreateView(base, &v_desc);
        WGPUTextureView mr_v   = wgpuTextureCreateView(mr,   &v_desc);
        WGPUTextureView nrm_v  = wgpuTextureCreateView(nrm,  &v_desc);
        WGPUTextureView occ_v  = wgpuTextureCreateView(occ,  &v_desc);
        WGPUTextureView emis_v = wgpuTextureCreateView(emis, &v_desc);

        // Update PBR factors uniform from material (per-primitive).
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
        r->device->update_buffer(r->mesh_factors_buf, &factors, 0, sizeof(factors));

        // Build bind group (10 entries).
        WGPUBindGroupEntry e[10] = {};
        e[0].binding = 0; e[0].buffer = dawn_int::dawn_internal_get_buffer(dev, r->mesh_camera_buf);
        e[0].offset = 0; e[0].size = WGPU_WHOLE_SIZE;
        e[1].binding = 1; e[1].buffer = dawn_int::dawn_internal_get_buffer(dev, r->mesh_model_buf);
        e[1].offset = 0; e[1].size = WGPU_WHOLE_SIZE;
        e[2].binding = 2; e[2].buffer = dawn_int::dawn_internal_get_buffer(dev, r->mesh_light_buf);
        e[2].offset = 0; e[2].size = WGPU_WHOLE_SIZE;
        e[3].binding = 3; e[3].buffer = dawn_int::dawn_internal_get_buffer(dev, r->mesh_factors_buf);
        e[3].offset = 0; e[3].size = WGPU_WHOLE_SIZE;
        e[4].binding = 4; e[4].textureView = base_v;
        e[5].binding = 5; e[5].sampler = r->mesh_sampler;
        e[6].binding = 6; e[6].textureView = mr_v;
        e[7].binding = 7; e[7].textureView = nrm_v;
        e[8].binding = 8; e[8].textureView = occ_v;
        e[9].binding = 9; e[9].textureView = emis_v;

        WGPUBindGroupDescriptor bg_desc = WGPU_BIND_GROUP_DESCRIPTOR_INIT;
        bg_desc.layout = bgl;
        bg_desc.entryCount = 10;
        bg_desc.entries = e;
        WGPUBindGroup bg = wgpuDeviceCreateBindGroup(dawn_int::dawn_internal_wgpu_device(dev), &bg_desc);
        bind_groups.push_back(bg);

        wgpuRenderPassEncoderSetBindGroup(pass, 0, bg, 0, nullptr);
        WGPUBuffer vbuf = dawn_int::dawn_internal_get_buffer(dev, prim.vertex_buffer);
        WGPUBuffer ibuf = dawn_int::dawn_internal_get_buffer(dev, prim.index_buffer);
        wgpuRenderPassEncoderSetVertexBuffer(pass, 0, vbuf, 0, WGPU_WHOLE_SIZE);
        wgpuRenderPassEncoderSetIndexBuffer(pass, ibuf, WGPUIndexFormat_Uint32,
                                              0, WGPU_WHOLE_SIZE);
        wgpuRenderPassEncoderDrawIndexed(pass, prim.index_count, 1, 0, 0, 0);

        wgpuTextureViewRelease(base_v);
        wgpuTextureViewRelease(mr_v);
        wgpuTextureViewRelease(nrm_v);
        wgpuTextureViewRelease(occ_v);
        wgpuTextureViewRelease(emis_v);
    }

    wgpuRenderPassEncoderEnd(pass);
    wgpuRenderPassEncoderRelease(pass);
    wgpuBindGroupLayoutRelease(bgl);
    for (WGPUBindGroup bg : bind_groups) wgpuBindGroupRelease(bg);
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

    auto fail = [&](const char* msg) -> AetherSceneRenderer* {
        scene_log("create: %s", msg);
        // Reverse-order cleanup. Not exhaustive (early failures haven't
        // allocated everything) but each handle.valid() check is safe.
        if (r->splat_pipe) wgpuRenderPipelineRelease(r->splat_pipe);
        if (r->mesh_pipe)  wgpuRenderPipelineRelease(r->mesh_pipe);
        if (r->mesh_sampler) wgpuSamplerRelease(r->mesh_sampler);
        if (r->fallback_white.valid())        device->destroy_texture(r->fallback_white);
        if (r->fallback_flat_normal.valid())  device->destroy_texture(r->fallback_flat_normal);
        if (r->fallback_black.valid())        device->destroy_texture(r->fallback_black);
        if (r->mesh_factors_buf.valid())      device->destroy_buffer(r->mesh_factors_buf);
        if (r->mesh_light_buf.valid())        device->destroy_buffer(r->mesh_light_buf);
        if (r->mesh_model_buf.valid())        device->destroy_buffer(r->mesh_model_buf);
        if (r->mesh_camera_buf.valid())       device->destroy_buffer(r->mesh_camera_buf);
        if (r->mesh_fs.valid())               device->destroy_shader(r->mesh_fs);
        if (r->mesh_vs.valid())               device->destroy_shader(r->mesh_vs);
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
        *device, iosurface, width, height, GPUTextureFormat::kBGRA8Unorm);
    if (!r->iosurface_tex.valid()) return fail("import_iosurface_texture failed");

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

    r->splat_uniforms_buf = make_buf(sizeof(RenderArgsStorage),
        static_cast<std::uint8_t>(GPUBufferUsage::kStorage),
        "scene.splat_uniforms");
    r->splats_buf = make_buf(sizeof(kBaselineSplats),
        static_cast<std::uint8_t>(GPUBufferUsage::kStorage),
        "scene.splats");
    if (!r->splat_uniforms_buf.valid() || !r->splats_buf.valid())
        return fail("splat buffer create failed");

    RenderArgsStorage uniforms = make_baseline_uniforms(width, height);
    device->update_buffer(r->splat_uniforms_buf, &uniforms, 0, sizeof(uniforms));
    device->update_buffer(r->splats_buf, kBaselineSplats, 0, sizeof(kBaselineSplats));

    r->splat_vs = device->load_shader("splat_render_vs", GPUShaderStage::kVertex);
    r->splat_fs = device->load_shader("splat_render_fs", GPUShaderStage::kFragment);
    if (!r->splat_vs.valid() || !r->splat_fs.valid())
        return fail("splat load_shader failed");
    std::string ep_unused;
    r->splat_pipe = create_splat_overlay_pipeline(
        dawn_int::dawn_internal_wgpu_device(dev),
        dawn_int::dawn_internal_get_shader_module(dev, r->splat_vs, ep_unused),
        dawn_int::dawn_internal_get_shader_module(dev, r->splat_fs, ep_unused));
    if (!r->splat_pipe) return fail("splat pipeline create failed");

    // 3. Mesh path: shaders + pipeline + uniforms + sampler + fallback textures.
    r->mesh_vs = device->load_shader("mesh_render_vs", GPUShaderStage::kVertex);
    r->mesh_fs = device->load_shader("mesh_render_fs", GPUShaderStage::kFragment);
    if (!r->mesh_vs.valid() || !r->mesh_fs.valid())
        return fail("mesh load_shader failed");
    r->mesh_pipe = create_mesh_pipeline(
        dawn_int::dawn_internal_wgpu_device(dev),
        dawn_int::dawn_internal_get_shader_module(dev, r->mesh_vs, ep_unused),
        dawn_int::dawn_internal_get_shader_module(dev, r->mesh_fs, ep_unused));
    if (!r->mesh_pipe) return fail("mesh pipeline create failed");

    r->mesh_camera_buf = make_buf(sizeof(CameraUniforms),
        static_cast<std::uint8_t>(GPUBufferUsage::kUniform), "scene.mesh.camera");
    r->mesh_model_buf = make_buf(sizeof(ModelTransform),
        static_cast<std::uint8_t>(GPUBufferUsage::kUniform), "scene.mesh.model");
    r->mesh_light_buf = make_buf(sizeof(LightUniforms),
        static_cast<std::uint8_t>(GPUBufferUsage::kUniform), "scene.mesh.light");
    r->mesh_factors_buf = make_buf(sizeof(PbrFactorsUniforms),
        static_cast<std::uint8_t>(GPUBufferUsage::kUniform), "scene.mesh.factors");
    if (!r->mesh_camera_buf.valid() || !r->mesh_model_buf.valid()
        || !r->mesh_light_buf.valid() || !r->mesh_factors_buf.valid())
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
}

extern "C" void aether_scene_renderer_destroy(AetherSceneRenderer* r) {
    if (!r) return;
    auto* device = r->device;
    if (device) {
        if (r->loaded_mesh) {
            ::aether::pocketworld::unload_glb_mesh(*device, *r->loaded_mesh);
            r->loaded_mesh.reset();
        }
        if (r->splat_pipe)            wgpuRenderPipelineRelease(r->splat_pipe);
        if (r->mesh_pipe)             wgpuRenderPipelineRelease(r->mesh_pipe);
        if (r->mesh_sampler)          wgpuSamplerRelease(r->mesh_sampler);
        if (r->fallback_white.valid())       device->destroy_texture(r->fallback_white);
        if (r->fallback_flat_normal.valid()) device->destroy_texture(r->fallback_flat_normal);
        if (r->fallback_black.valid())       device->destroy_texture(r->fallback_black);
        if (r->mesh_factors_buf.valid()) device->destroy_buffer(r->mesh_factors_buf);
        if (r->mesh_light_buf.valid())   device->destroy_buffer(r->mesh_light_buf);
        if (r->mesh_model_buf.valid())   device->destroy_buffer(r->mesh_model_buf);
        if (r->mesh_camera_buf.valid())  device->destroy_buffer(r->mesh_camera_buf);
        if (r->mesh_fs.valid())          device->destroy_shader(r->mesh_fs);
        if (r->mesh_vs.valid())          device->destroy_shader(r->mesh_vs);
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

extern "C" bool aether_scene_renderer_load_glb(AetherSceneRenderer* r,
                                                 const char* glb_path) {
    if (!r || !r->device || !glb_path) return false;
    if (r->loaded_mesh) {
        ::aether::pocketworld::unload_glb_mesh(*r->device, *r->loaded_mesh);
        r->loaded_mesh.reset();
        r->has_mesh = false;
    }
    auto opt = ::aether::pocketworld::load_glb_mesh(*r->device, std::string(glb_path));
    if (!opt) return false;
    r->loaded_mesh = std::move(opt);
    r->has_mesh = true;
    scene_log("loaded GLB '%s' (%zu primitives, %zu materials, bounds [%.2f..%.2f])",
              glb_path,
              r->loaded_mesh->primitives.size(),
              r->loaded_mesh->materials.size(),
              r->loaded_mesh->bounds_min[0], r->loaded_mesh->bounds_max[0]);
    return true;
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
        // Camera: view_proj = perspective(60°, aspect, 0.1, 100) * view.
        // Aspect: width/height from IOSurface dims.
        const float aspect = static_cast<float>(r->width) /
                             static_cast<float>(r->height);
        float proj[16];
        mat4_perspective(proj, 60.0f * 3.14159265f / 180.0f, aspect, 0.1f, 100.0f);
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

    // Splat uniforms: keep the baseline. View matrix uploaded for
    // future-compat but splat_render.wgsl doesn't read it (Phase 6.4f).
    RenderArgsStorage splat_u = make_baseline_uniforms(r->width, r->height);
    std::memcpy(splat_u.viewmat, view_matrix, 16 * sizeof(float));
    r->device->update_buffer(r->splat_uniforms_buf, &splat_u, 0, sizeof(splat_u));

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

    if (r->has_mesh) {
        encode_mesh_pass(encoder, color_view, depth_view, r);
        // Pass 2: splat overlay loads color + depth.
        encode_splat_pass(encoder, color_view, depth_view, WGPULoadOp_Load, r);
    } else {
        // No mesh: splat pass becomes the lone pass; clears color + depth.
        encode_splat_pass(encoder, color_view, depth_view, WGPULoadOp_Clear, r);
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
