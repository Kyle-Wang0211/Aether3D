// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_CPP_TOOLS_DAWN_KERNEL_HARNESS_H
#define AETHER_CPP_TOOLS_DAWN_KERNEL_HARNESS_H

// ─── Phase 6.3 / Plan B refinement — reusable Dawn smoke-test harness ───
//
// One-shot Dawn instance + adapter + device + queue setup, plus per-kernel
// "upload buffer / load WGSL → compute pipeline / dispatch / read back"
// helpers. Used by aether_dawn_splat_smoke_<kernel>.cpp binaries (one per
// Brush kernel adapted in 6.3a/b) so each kernel can be validated in
// isolation BEFORE the full DawnGPUDevice (6.2.H/I/J/K) wrapper exists.
//
// De-risk pattern (per Phase 4-5 precedent + user's 2026-04-26 audit):
//   - Validation chain: 5 layers (Brush WGSL → naga_oil → binding rewrite
//     → Tint → iOS Metal runtime). DawnGPUDevice wrapper would add a 6th.
//   - Plan B = run all 14 kernels through this 5-layer harness FIRST, then
//     wrap. Bug bisection range collapses from 6 layers to 5.
//
// Reuse beyond Phase 6.3:
//   - Toolchain regression catcher (Dawn / naga_oil / Brush re-pin)
//   - Onboarding reference for "how Brush WGSL → Dawn → Metal flow works"
//   - Bisect tool when device-specific issues surface in Phase 7+
//
// Why webgpu_cpp.h not webgpu.h: this is a TOOL, not aether3d_core. Tools
// don't inherit AETHER_STRICT_COMPILE_OPTIONS; webgpu_cpp.h's RAII
// wrappers (which conflict with -fno-exceptions / -fno-rtti) are fine
// here. Same convention as P1.5 aether_dawn_hello_compute.cpp.

#include <webgpu/webgpu_cpp.h>

#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

namespace aether {
namespace tools {

class DawnKernelHarness {
public:
    DawnKernelHarness();
    ~DawnKernelHarness();

    // Non-copyable.
    DawnKernelHarness(const DawnKernelHarness&) = delete;
    DawnKernelHarness& operator=(const DawnKernelHarness&) = delete;

    // Acquire instance (with TimedWaitAny feature) + sync request adapter
    // + sync request device + get queue. Returns false on any failure
    // (writes diagnostic to stderr first). After init() returns true,
    // device() and queue() are valid.
    bool init();

    // Upload `size` bytes from `data` to a new buffer. `usage` must include
    // CopyDst (for the upload itself); typical usage = Storage|CopyDst.
    // Synchronous from caller's POV (queue.WriteBuffer doesn't block but
    // schedules in queue order).
    wgpu::Buffer upload(const void* data, size_t size, wgpu::BufferUsage usage);

    // Allocate empty buffer (zero-initialized by Dawn). For readback
    // targets, callers must include CopySrc in `usage` and create a
    // separate staging buffer via alloc_staging_for_readback() before
    // dispatching. Most Storage outputs are NOT mappable on iOS, hence
    // the explicit staging step.
    wgpu::Buffer alloc(size_t size, wgpu::BufferUsage usage);

    // Allocate a MapRead|CopyDst staging buffer of the given size. Use
    // with copy_to_staging() before readback().
    wgpu::Buffer alloc_staging_for_readback(size_t size);

    // Compile a WGSL source string into a compute pipeline.
    // `wgsl_source` should contain a single @compute @workgroup_size(...)
    // function named `entry_point` (default "main"). Returns invalid
    // pipeline on compile error; full Tint diagnostics emitted to stderr.
    wgpu::ComputePipeline load_compute(std::string_view wgsl_source,
                                        const char* entry_point = "main");

    // Bind `bindings` to @group(0) (in vector order: index 0 → @binding(0))
    // and dispatch a single workgroup grid (wg_x, wg_y, wg_z workgroups).
    // Synchronous: this method submits + waits for completion before
    // returning. Use for smoke tests where you want isolation per kernel.
    void dispatch(const wgpu::ComputePipeline& pipeline,
                  const std::vector<wgpu::Buffer>& bindings,
                  uint32_t wg_x, uint32_t wg_y = 1, uint32_t wg_z = 1);

    // ─── Batched dispatch (one command encoder, many passes, ONE wait) ───
    // dispatch() submits + WaitAny-syncs PER call; for a chain of many small
    // dispatches (e.g. the ~80 GSS blur passes) that per-call sync latency
    // dominates. begin_batch()/dispatch_batched()/end_batch() encode an
    // arbitrary number of compute passes into a SINGLE command buffer and wait
    // exactly once. Storage-buffer hazards between consecutive passes are
    // tracked by Dawn, so a later pass sees the earlier pass's writes (identical
    // result to per-call dispatch — only the sync count changes). Bindings must
    // outlive end_batch(): the bind-group references them until submit.
    void begin_batch();
    void dispatch_batched(const wgpu::ComputePipeline& pipeline,
                          const std::vector<wgpu::Buffer>& bindings,
                          uint32_t wg_x, uint32_t wg_y = 1, uint32_t wg_z = 1);
    // Encode a buffer-to-buffer copy into the open batch (no submit). Used to
    // assemble the packed pyramid in ONE submit instead of 48.
    void copy_region_batched(const wgpu::Buffer& src, uint64_t src_offset,
                             const wgpu::Buffer& dst, uint64_t dst_offset,
                             size_t size);
    void end_batch();  // submit + single WaitAny

    // Bind `bindings` to @group(0) (same order convention as dispatch()) and
    // dispatch an INDIRECT workgroup grid: the (wg_x, wg_y, wg_z) triple is
    // read by the GPU from `indirect_buffer` at byte `indirect_offset` (three
    // consecutive u32). The CPU never reads the count — this is the
    // keypoint-sparse-collection path (GPU_DSP_SIFT_PLAN_AFFINE_OFF.md §3-①):
    // an earlier pass writes indirect_args = [(count+WG-1)/WG, 1, 1] into the
    // buffer, then S4/S5 launch over exactly the detected keypoints without a
    // round-trip. `indirect_buffer` must carry BufferUsage::Indirect (the
    // helper alloc_indirect_args() tags it). Synchronous: submits + waits.
    void dispatch_indirect(const wgpu::ComputePipeline& pipeline,
                           const std::vector<wgpu::Buffer>& bindings,
                           const wgpu::Buffer& indirect_buffer,
                           uint64_t indirect_offset = 0);

    // Allocate a 3*u32 (12-byte, but rounded up by Dawn) indirect-args buffer
    // usable both as a compute Storage target (a tiny pass writes the dispatch
    // dims into it) AND as the source for dispatch_indirect. Usage =
    // Storage | Indirect | CopySrc | CopyDst. Zero-initialized by Dawn.
    wgpu::Buffer alloc_indirect_args();

    // Copy `size` bytes from `src` (any CopySrc-tagged buffer) to `dst`
    // (must be MapRead|CopyDst). Submits + waits.
    void copy_to_staging(const wgpu::Buffer& src, const wgpu::Buffer& dst,
                         size_t size);

    // General buffer-to-buffer copy with explicit src/dst byte offsets (both
    // must be 4-byte aligned per WebGPU). Used to assemble a packed pyramid
    // buffer from per-level buffers without a host round-trip. Submits + waits.
    void copy_region(const wgpu::Buffer& src, uint64_t src_offset,
                     const wgpu::Buffer& dst, uint64_t dst_offset, size_t size);

    // Map a MapRead-usage buffer, copy its contents to a vector<uint8_t>,
    // unmap, return the vector. Spin-waits via WaitAny (Phase 6.2.F's
    // hybrid stability strategy: spin-wait is the RARE path, acceptable
    // for one-shot smoke tests).
    std::vector<uint8_t> readback(const wgpu::Buffer& buf, size_t size);

    // ─── Texture / render-pipeline path (Phase 6.3a Step 4 v3) ─────────

    // Create a render-target texture of (w, h, format). Usage =
    // RenderAttachment | CopySrc | TextureBinding so it can be the color
    // attachment of a render pass + readable via copy-to-buffer +
    // sampleable as a texture in subsequent compute passes.
    //
    // Phase 6 v3 viewer pipeline renders to RGBA8Unorm IOSurface-backed
    // textures (matches Phase 4/5 Flutter Texture widget zero-copy path).
    // Smoke harness uses plain Dawn-native textures; the IOSurface bridge
    // is reused once the DawnGPUDevice (6.2.G) wraps the render-pass API.
    wgpu::Texture alloc_render_target(uint32_t w, uint32_t h,
                                       wgpu::TextureFormat format);

    // Compile a WGSL source containing vertex + fragment entry points
    // into a render pipeline targeting the given color format. WGSL must
    // declare two @vertex / @fragment fns named `vs_entry` and
    // `fs_entry`. Topology defaults to TriangleList (instanced quads
    // emit 6 vertices per instance via vertexID = 0..5).
    wgpu::RenderPipeline load_render_pipeline(
        std::string_view wgsl_source,
        const char* vs_entry,
        const char* fs_entry,
        wgpu::TextureFormat color_format,
        wgpu::PrimitiveTopology topology = wgpu::PrimitiveTopology::TriangleList);

    // Encode a single render pass: clear color = (0,0,0,0), draw the
    // pipeline with vertex_count vertices × instance_count instances.
    // `bindings` are the @group(0) storage buffers (instanced quads
    // typically have NO vertex buffers — vertices are computed from
    // vertexID + instanceID). Submits + waits.
    void dispatch_render_pass(
        const wgpu::RenderPipeline& pipeline,
        const wgpu::Texture& target,
        const std::vector<wgpu::Buffer>& bindings,
        uint32_t vertex_count,
        uint32_t instance_count);

    // Copy a 2D RGBA8 texture's pixels to a new MapRead buffer, return
    // the bytes. Caller specifies width/height/bytes_per_pixel because
    // texture format isn't reflectable from wgpu::Texture in the C++
    // wrapper (Dawn limitation — internal arch is C handles).
    //
    // Bytes-per-row alignment: WebGPU requires 256-byte alignment for
    // copyTextureToBuffer. We pad rows automatically and unpad on
    // readback so the caller gets tightly-packed (w * bpp)-stride
    // bytes back.
    std::vector<uint8_t> readback_texture(
        const wgpu::Texture& tex,
        uint32_t w, uint32_t h,
        uint32_t bytes_per_pixel);

    // True if the device was created with the ShaderF16 feature (the WGSL
    // `enable f16;` extension is usable). Apple Silicon / A16 advertise it;
    // some Adreno do not (and have an f16-crash history) → the f16 descriptor
    // variant is gated on this and falls back to f32 when false.
    bool has_f16() const { return has_f16_; }

    // Accessors for advanced callers.
    const wgpu::Instance& instance() const { return instance_; }
    const wgpu::Adapter&  adapter()  const { return adapter_; }
    const wgpu::Device&   device()   const { return device_; }
    const wgpu::Queue&    queue()    const { return queue_; }

private:
    wgpu::Instance instance_;
    wgpu::Adapter adapter_;
    wgpu::Device device_;
    wgpu::Queue queue_;

    // In-progress batch (begin_batch/dispatch_batched/end_batch). The bind
    // groups must stay alive until end_batch() submits, so we retain them.
    wgpu::CommandEncoder batch_encoder_;
    std::vector<wgpu::BindGroup> batch_bind_groups_;

    // Compiled-pipeline cache, keyed by (entry_point '\0' wgsl_source). The
    // SIFT extractor reloads the SAME ~10 static kernel sources on every
    // frame; CreateShaderModule+CreateComputePipeline is the dominant
    // per-frame cost (~1.3s recompiled each frame). The harness outlives the
    // per-frame loop, so memoizing here collapses N-frames×10 recompiles to
    // 10 total. wgpu::ComputePipeline is a ref-counted handle (cheap to copy).
    std::unordered_map<std::string, wgpu::ComputePipeline> pipeline_cache_;

    bool has_f16_ = false;  // ShaderF16 was granted at device creation
};

}  // namespace tools
}  // namespace aether

#endif  // AETHER_CPP_TOOLS_DAWN_KERNEL_HARNESS_H
