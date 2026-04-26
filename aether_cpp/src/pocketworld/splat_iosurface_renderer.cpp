// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

// ─── Phase 6.4a — IOSurface-backed splat renderer (impl) ───────────────
//
// Singleton DawnGPUDevice (one per process) shared across all renderer
// instances. Each renderer owns:
//   - an imported IOSurface texture (zero-copy with Flutter compositor)
//   - per-instance uniforms + projected-splats buffers
//   - a render pipeline (cached at create time)
//
// Per-frame `render(handle, t_seconds)`:
//   1. BeginAccess fence on the IOSurface texture
//   2. Encode render pass: clear → SetPipeline → SetBindGroup → Draw
//   3. Commit + wait_until_completed (synchronous frame for now —
//      Phase 7 may switch to fire-and-forget once the IOSurface fence
//      semantics are battle-tested on real devices)
//   4. EndAccess fence — IOSurface is now safe for Flutter to read
//
// Stage 1 (this file initially): scene is the cross_validate baseline
// (4 splats at xy=(128,128) with z²-scaled conics, mid-gray RGBA). The
// scene is static across frames — t_seconds is ignored except for log
// output. Stage 2 (6.4a') adds aether_splat_renderer_render_full taking
// view + model matrices as float[16] each, with the C++ side becoming a
// pure pass-through.

#if defined(AETHER_ENABLE_DAWN)

#include "aether/pocketworld/splat_iosurface_renderer.h"

#include "aether/render/dawn_gpu_device.h"
#include "aether/render/gpu_command.h"
#include "aether/render/gpu_device.h"
#include "aether/render/gpu_resource.h"

#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <memory>
#include <mutex>

namespace {

// ─── Singleton DawnGPUDevice ───────────────────────────────────────────

std::mutex& device_mutex() {
    static std::mutex m;
    return m;
}

// Active renderer count. When the last renderer is destroyed, the
// singleton device is also released (so a fresh background→foreground
// cycle gets a fresh device, useful for memory pressure recovery).
std::uint32_t& active_renderer_count() {
    static std::uint32_t count = 0;
    return count;
}

std::unique_ptr<aether::render::GPUDevice>& singleton_device() {
    static std::unique_ptr<aether::render::GPUDevice> device;
    return device;
}

// Acquire (create-if-needed + register WGSL). Caller MUST hold device_mutex.
aether::render::GPUDevice* ensure_device_locked() {
    auto& dev = singleton_device();
    if (!dev) {
        dev = aether::render::create_dawn_gpu_device(/*request_high_performance=*/true);
        if (!dev) {
            std::fprintf(stderr,
                "[splat_iosurface_renderer] FATAL: create_dawn_gpu_device "
                "returned nullptr\n");
            return nullptr;
        }
        // Production-path: baked WGSL only, no filesystem access.
        aether::render::register_baked_wgsl_into_device(*dev);
    }
    return dev.get();
}

// Release the singleton device when active_renderer_count drops to 0.
// Caller MUST hold device_mutex.
void release_device_if_unused_locked() {
    if (active_renderer_count() == 0) {
        singleton_device().reset();
    }
}

// ─── Splat scene baseline (matches cross_validate smoke) ───────────────
//
// Hard-coded ProjectedSplat values: 4 splats centered at (128, 128) in a
// 256×256 framebuffer, with z²-scaled conics and mid-gray RGBA. This is
// the post-project_visible state — splat_render.wgsl consumes it as-is
// (no view matrix; positions are already in screen space).

struct ProjectedSplatLayout {
    float xy_x, xy_y;
    float conic_x, conic_y, conic_z;
    float color_r, color_g, color_b, color_a;
};
static_assert(sizeof(ProjectedSplatLayout) == 36,
              "ProjectedSplatLayout must match WGSL ProjectedSplat (9 f32)");

constexpr std::uint32_t kNumSplats = 4;

const ProjectedSplatLayout kBaselineSplats[kNumSplats] = {
    {128.0f, 128.0f, 0.006061f, 0.0f, 0.006061f,  0.641f, 0.641f, 0.641f, 0.731059f},
    {128.0f, 128.0f, 0.024113f, 0.0f, 0.024113f,  0.641f, 0.641f, 0.641f, 0.731059f},
    {128.0f, 128.0f, 0.053767f, 0.0f, 0.053767f,  0.641f, 0.641f, 0.641f, 0.731059f},
    {128.0f, 128.0f, 0.094401f, 0.0f, 0.094401f,  0.641f, 0.641f, 0.641f, 0.731059f},
};

// RenderUniforms / RenderArgsStorage layout (from splat_render.wgsl).
// Only `img_size` is read by the kernel; other fields are kept for
// binding-layout match.
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
static_assert(sizeof(RenderArgsStorage) == 144,
              "RenderArgsStorage must match WGSL RenderUniforms layout");

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

}  // namespace

// ═══════════════════════════════════════════════════════════════════════
// AetherSplatRenderer (opaque struct exposed via void* in C ABI)
// ═══════════════════════════════════════════════════════════════════════

struct AetherSplatRenderer {
    aether::render::GPUDevice* device{nullptr};       // borrowed (singleton)
    aether::render::GPUTextureHandle iosurface_tex{};
    aether::render::GPUBufferHandle uniforms_buf{};
    aether::render::GPUBufferHandle splats_buf{};
    aether::render::GPUShaderHandle vs{};
    aether::render::GPUShaderHandle fs{};
    aether::render::GPURenderPipelineHandle pipeline{};
    std::uint32_t width{0};
    std::uint32_t height{0};
};

extern "C" AetherSplatRenderer* aether_splat_renderer_create(
    void* iosurface,
    uint32_t width,
    uint32_t height
) {
    if (!iosurface || width == 0 || height == 0) {
        std::fprintf(stderr, "[splat_iosurface_renderer] create: invalid args "
                             "(iosurface=%p w=%u h=%u)\n",
                             iosurface, width, height);
        return nullptr;
    }

    using namespace aether::render;

    std::lock_guard<std::mutex> lock(device_mutex());
    GPUDevice* device = ensure_device_locked();
    if (!device) return nullptr;

    auto* r = new AetherSplatRenderer();
    r->device = device;
    r->width = width;
    r->height = height;

    // 1. Import the IOSurface as a texture.
    r->iosurface_tex = dawn_import_iosurface_texture(
        *device, iosurface, width, height, GPUTextureFormat::kBGRA8Unorm);
    if (!r->iosurface_tex.valid()) {
        std::fprintf(stderr, "[splat_iosurface_renderer] create: "
                             "dawn_import_iosurface_texture failed\n");
        delete r;
        return nullptr;
    }

    // 2. Allocate + upload uniforms + splats.
    GPUBufferDesc uniform_desc{};
    uniform_desc.size_bytes = sizeof(RenderArgsStorage);
    uniform_desc.storage = GPUStorageMode::kPrivate;
    uniform_desc.usage_mask = static_cast<std::uint8_t>(GPUBufferUsage::kStorage);
    uniform_desc.label = "splat_renderer.uniforms";
    r->uniforms_buf = device->create_buffer(uniform_desc);

    GPUBufferDesc splats_desc{};
    splats_desc.size_bytes = sizeof(kBaselineSplats);
    splats_desc.storage = GPUStorageMode::kPrivate;
    splats_desc.usage_mask = static_cast<std::uint8_t>(GPUBufferUsage::kStorage);
    splats_desc.label = "splat_renderer.splats";
    r->splats_buf = device->create_buffer(splats_desc);

    if (!r->uniforms_buf.valid() || !r->splats_buf.valid()) {
        std::fprintf(stderr, "[splat_iosurface_renderer] create: "
                             "create_buffer failed\n");
        device->destroy_texture(r->iosurface_tex);
        if (r->uniforms_buf.valid()) device->destroy_buffer(r->uniforms_buf);
        if (r->splats_buf.valid())   device->destroy_buffer(r->splats_buf);
        delete r;
        return nullptr;
    }

    RenderArgsStorage uniforms = make_baseline_uniforms(width, height);
    device->update_buffer(r->uniforms_buf, &uniforms, 0, sizeof(uniforms));
    device->update_buffer(r->splats_buf, kBaselineSplats, 0, sizeof(kBaselineSplats));

    // 3. Load the splat_render shader pair + create render pipeline.
    r->vs = device->load_shader("splat_render_vs", GPUShaderStage::kVertex);
    r->fs = device->load_shader("splat_render_fs", GPUShaderStage::kFragment);
    if (!r->vs.valid() || !r->fs.valid()) {
        std::fprintf(stderr, "[splat_iosurface_renderer] create: "
                             "load_shader failed (vs=%u fs=%u). "
                             "Did register_baked_wgsl_into_device run?\n",
                             r->vs.id, r->fs.id);
        device->destroy_buffer(r->splats_buf);
        device->destroy_buffer(r->uniforms_buf);
        device->destroy_texture(r->iosurface_tex);
        delete r;
        return nullptr;
    }

    GPURenderTargetDesc rt_desc{};
    rt_desc.color_format = GPUTextureFormat::kBGRA8Unorm;  // matches IOSurface
    rt_desc.depth_format = GPUTextureFormat::kInvalid;
    rt_desc.width = width;
    rt_desc.height = height;
    rt_desc.sample_count = 1;
    rt_desc.blending_enabled = true;  // premultiplied alpha
    rt_desc.color_attachment_count = 1;
    r->pipeline = device->create_render_pipeline(r->vs, r->fs, rt_desc);
    if (!r->pipeline.valid()) {
        std::fprintf(stderr, "[splat_iosurface_renderer] create: "
                             "create_render_pipeline failed\n");
        device->destroy_shader(r->fs);
        device->destroy_shader(r->vs);
        device->destroy_buffer(r->splats_buf);
        device->destroy_buffer(r->uniforms_buf);
        device->destroy_texture(r->iosurface_tex);
        delete r;
        return nullptr;
    }

    ++active_renderer_count();
    return r;
}

extern "C" void aether_splat_renderer_destroy(AetherSplatRenderer* r) {
    if (!r) return;
    std::lock_guard<std::mutex> lock(device_mutex());
    auto* device = r->device;
    if (device) {
        if (r->pipeline.valid())     device->destroy_render_pipeline(r->pipeline);
        if (r->fs.valid())           device->destroy_shader(r->fs);
        if (r->vs.valid())           device->destroy_shader(r->vs);
        if (r->splats_buf.valid())   device->destroy_buffer(r->splats_buf);
        if (r->uniforms_buf.valid()) device->destroy_buffer(r->uniforms_buf);
        if (r->iosurface_tex.valid())device->destroy_texture(r->iosurface_tex);
    }
    delete r;
    if (active_renderer_count() > 0) --active_renderer_count();
    release_device_if_unused_locked();
}

extern "C" void aether_splat_renderer_render(AetherSplatRenderer* r,
                                              double /*t_seconds*/) {
    if (!r || !r->device) return;
    using namespace aether::render;

    // Stage 1: scene is static (cross_validate baseline). t_seconds is
    // ignored. Stage 2 (6.4a') will replace this entry point with one
    // that takes view+model matrices from the caller.

    // 1. BeginAccess fence: synchronize with any prior IOSurface consumer
    //    (Flutter compositor reading the previous frame).
    if (!dawn_iosurface_begin_access(*r->device, r->iosurface_tex)) {
        // Logged inside dawn_iosurface_begin_access. Skip this frame —
        // returning silently here would freeze the texture content.
        return;
    }

    // 2. Encode + submit render pass.
    auto cb = r->device->create_command_buffer();
    if (!cb) {
        dawn_iosurface_end_access(*r->device, r->iosurface_tex);
        return;
    }

    GPURenderPassDesc pass_desc{};
    pass_desc.width = r->width;
    pass_desc.height = r->height;
    pass_desc.color_attachment_count = 1;
    pass_desc.color_attachments[0].texture = r->iosurface_tex;
    pass_desc.color_attachments[0].load = GPULoadAction::kClear;
    pass_desc.color_attachments[0].store = GPUStoreAction::kStore;
    // Clear to opaque black so the alpha channel reads as visible. The
    // splat fragments use premultiplied-alpha blend so the splat
    // contribution composes on top of this background.
    pass_desc.color_attachments[0].clear_color[0] = 0.0f;
    pass_desc.color_attachments[0].clear_color[1] = 0.0f;
    pass_desc.color_attachments[0].clear_color[2] = 0.0f;
    pass_desc.color_attachments[0].clear_color[3] = 1.0f;

    auto* re = cb->make_render_encoder(pass_desc);
    if (!re) {
        std::fprintf(stderr, "[splat_iosurface_renderer] render: "
                             "make_render_encoder NULL\n");
        dawn_iosurface_end_access(*r->device, r->iosurface_tex);
        return;
    }
    re->set_pipeline(r->pipeline);
    re->set_vertex_buffer(r->uniforms_buf, 0, 0);
    re->set_vertex_buffer(r->splats_buf,   0, 1);
    re->draw_instanced(GPUPrimitiveType::kTriangle,
                       /*vertex_count=*/6, /*instance_count=*/kNumSplats);
    re->end_encoding();

    cb->commit();
    cb->wait_until_completed();

    // 3. EndAccess: IOSurface is now safe for Flutter compositor read.
    dawn_iosurface_end_access(*r->device, r->iosurface_tex);
}

#else  // !AETHER_ENABLE_DAWN

// Stub implementations so the C ABI exists even without Dawn (build
// completeness — link errors are louder than missing symbols).

#include "aether/pocketworld/splat_iosurface_renderer.h"
#include <cstdio>

extern "C" AetherSplatRenderer* aether_splat_renderer_create(
    void* /*iosurface*/, uint32_t /*w*/, uint32_t /*h*/) {
    std::fprintf(stderr, "[splat_iosurface_renderer] AETHER_ENABLE_DAWN=OFF; "
                         "create returns NULL\n");
    return nullptr;
}
extern "C" void aether_splat_renderer_destroy(AetherSplatRenderer*) {}
extern "C" void aether_splat_renderer_render(AetherSplatRenderer*, double) {}

#endif  // AETHER_ENABLE_DAWN
