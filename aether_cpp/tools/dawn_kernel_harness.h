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
#include <memory>
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

    // 取出并清除"自上次调用以来是否发生过 Dawn 设备级错误(校验/OOM/
    // internal)"。
    //
    // [P0 崩溃修复 2026-07-27] 未捕获错误回调过去直接 std::abort() ——
    // 对离线 harness 合理,但这份 harness 已被链进出货二进制,于是采集时
    // 任何一次 Dawn 校验失败都会杀掉用户的 App(真机:全黑帧 → 0 特征 →
    // 零尺寸 buffer → CreateBindGroup 校验失败 → 闪退)。现在错误被记录,
    // 调用方**必须**在消费 GPU 结果前查这里,失败就走自己的回退路径。
    //
    // 状态是进程内全局的(回调不能带捕获,拿不到 this;而一个进程只有一个
    // Dawn device,所以与 per-instance 等价)。线程安全。
    static bool take_device_error(std::string* msg = nullptr);

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

    // [W256 2026-09-07] 子区间绑定。Mali-G72(Vulkan)maxStorageBufferBindingSize
    // = 256 MB 而 maxBufferSize = 1 GB:12MP 打包金字塔(≈400 MB)本身合法,
    // 只是**每次绑定**不得超 256 MB。offset 须按 minStorageBufferOffsetAlignment
    // (256 B)对齐;size = WGPU_WHOLE_SIZE 表示到缓冲尾。三端同一代码路径。
    struct BufBinding {
        wgpu::Buffer buffer;
        uint64_t offset = 0;
        uint64_t size = WGPU_WHOLE_SIZE;
        explicit BufBinding(wgpu::Buffer b, uint64_t off = 0,
                            uint64_t sz = WGPU_WHOLE_SIZE)
            : buffer(std::move(b)), offset(off), size(sz) {}
    };
    void dispatch(const wgpu::ComputePipeline& pipeline,
                  const std::vector<BufBinding>& bindings,
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
    void dispatch_batched(const wgpu::ComputePipeline& pipeline,
                          const std::vector<BufBinding>& bindings,
                          uint32_t wg_x, uint32_t wg_y = 1, uint32_t wg_z = 1);
    // Encode a buffer-to-buffer copy into the open batch (no submit). Used to
    // assemble the packed pyramid in ONE submit instead of 48.
    void copy_region_batched(const wgpu::Buffer& src, uint64_t src_offset,
                             const wgpu::Buffer& dst, uint64_t dst_offset,
                             size_t size);
    void end_batch();  // submit + single WaitAny
    // Asynchronous variant: submit the open batch and return immediately; wait_async() blocks on completion (once).
    // Lets a producer thread queue GPU work (e.g. a frame's pyramid) while the consumer thread is still busy.
    struct AsyncBatch { wgpu::Future future{}; std::shared_ptr<bool> done; bool valid = false; std::vector<wgpu::BindGroup> keep; };
    AsyncBatch end_batch_async();
    bool wait_async(AsyncBatch& b);

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

    // [GPU-HANG-A1 2026-08-06] False once any GPU wait timed out / failed
    // (Chromium watchdog 有限超时机制:Dawn TimedWaitAny 超时 → 设备判失活,
    // 不再无限等待)。不健康后所有操作入口立即短路失败;上层(dsp_sift_gpu_c.cc
    // acquire_gpu_harness)据此遗弃并重建 harness。
    bool healthy() const { return device_healthy_; }

    // [EXTRACT-SELFHEAL 2026-08-10] 上层在"设备级错误导致提取失败"后强制
    // 遗弃本实例(acquire_gpu_harness 见 unhealthy 即重建)。与超时判失活
    // 走同一条遗弃-重建路;设备错误类失败此前不标记 ⇒ 补算期 GPU 重试
    // 100% 复用坏实例连败掉 CPU(2026-08-09 未命名(2) 4/4 实锤)。
    void mark_unhealthy() { device_healthy_ = false; }

    // True if the device was created with the ShaderF16 feature (the WGSL
    // `enable f16;` extension is usable). Apple Silicon / A16 advertise it;
    // some Adreno do not (and have an f16-crash history) → the f16 descriptor
    // variant is gated on this and falls back to f32 when false.
    bool has_f16() const { return has_f16_; }
    // Strict math: chain wgpu::ShaderModuleCompilationOptions{strictMath=true} on every shader module
    // (Metal: fastMathEnabled=false / mathMode=safe). Off by default (Dawn default = fast math).
    // Env OFFICIAL_AETHER_STRICT_MATH=1(official 载体)/ AETHER_STRICT_MATH=1(台架)at init()
    // turns it on. Bit-exact ports (OpenCV replicas) need it ON.
    void set_strict_math(bool v) { strict_math_ = v; }
    bool strict_math() const { return strict_math_ && has_strict_math_; }
    bool has_strict_math() const { return has_strict_math_; }

    // Accessors for advanced callers.
    const wgpu::Instance& instance() const { return instance_; }
    const wgpu::Adapter&  adapter()  const { return adapter_; }
    const wgpu::Device&   device()   const { return device_; }
    const wgpu::Queue&    queue()    const { return queue_; }

    // ─── [GPU-TS 2026-07-29] True GPU-side pass timing (timestamp-query) ───
    //
    // WHY: every existing per-stage number in this pipeline (the 9-element
    // `ex[]` split written into frame_split telemetry) is a HOST wall clock
    // around a submit+WaitAny. That interval bundles four different things —
    // host-side loops, buffer uploads, the blocking readback, and the GPU work
    // itself — and the optimisations currently on the table target the
    // non-GPU parts. Ranking them on host wall clock is therefore circular.
    // GPU timestamps split the GPU part out so the rest can be attributed by
    // subtraction.
    //
    // Enabled only when the adapter advertises TimestampQuery AND the env
    // AETHER_GPU_TIMESTAMPS=1 is set: with the env unset the feature is not
    // requested, no query set exists, no pass descriptor is attached, and the
    // encoded command stream is identical to before. Diagnostics must never
    // change what ships.
    //
    // Resolution happens ONCE per frame in gpu_ts_resolve() rather than per
    // dispatch — a per-dispatch resolve would add exactly the kind of
    // round-trip we are trying to measure.
    bool gpu_ts_enabled() const { return ts_enabled_; }
    uint32_t gpu_ts_status() const { return ts_status_; }
    uint32_t gpu_ts_capability() const { return ts_capability_; }
    // Keep adapter advertisement, device-request attempt, device grant, and
    // final query-resource enablement distinct. A device may grant the feature
    // and still fail later query-set/readback allocation.
    bool gpu_ts_feature_request_to_device() const {
        return ts_feature_request_to_device_;
    }
    bool gpu_ts_feature_granted() const { return ts_feature_granted_; }
    // Start a new frame: rewind the slot cursor. Cheap; no GPU work.
    void gpu_ts_reset();
    // Number of passes recorded so far — call at a stage boundary to remember
    // which passes belong to which stage, then attribute after resolve.
    uint32_t gpu_ts_pass_count() const { return ts_next_ / 2; }
    // Resolve + read back every recorded pass. out_ns[i] = GPU nanoseconds for
    // pass i (end-of-pass minus beginning-of-pass timestamp). Returns false if
    // timestamps are off or nothing was recorded.
    bool gpu_ts_resolve(std::vector<uint64_t>* out_ns);
    // Apply the extractor-owned cumulative nine-stage pass boundaries to the
    // pending raw ticks and atomically publish one valid frame snapshot. This
    // performs no GPU work and must be called only after gpu_ts_resolve().
    bool gpu_ts_finalize_frame(const uint32_t* cumulative_pass_counts,
                               uint32_t stage_count);
    // The production C ABI serializes extraction under one harness mutex, then
    // returns to a session-specific caller. Seal the exact frame while that
    // mutex is still held so a later extraction cannot replace the evidence
    // before the caller consumes it.
    static void gpu_ts_clear_caller_thread_frame();
    bool gpu_ts_stash_frame_for_caller_thread();

    // ─── [HOST-BD 2026-07-29] Where the non-GPU time actually goes ───
    //
    // GPU timestamps proved the compute kernels are only ~21% of extract wall
    // time on host; the other ~79% is host-side. This splits that remainder
    // into the four things the harness itself does, so the extractor's own
    // loops can be obtained by subtraction:
    //     stage_host_ms - stage_gpu_ms - (upload+encode+wait+map in that stage)
    //   = the extractor's own CPU work in that stage.
    // Without this split, "host overhead" is one opaque number and any fix
    // aimed at it is a guess.
    //
    // Same env gate as the GPU timestamps (AETHER_GPU_TIMESTAMPS=1): unset
    // means not a single extra clock read on the shipped path.
    struct HostBreakdown {
        double upload_ms = 0;       // CreateBuffer + WriteBuffer
        double encode_ms = 0;       // bind-group build + command encoding
        double submit_wait_ms = 0;  // Submit + OnSubmittedWorkDone WaitAny
        double map_ms = 0;          // MapAsync wait + copy out + Unmap
        // ⚠️ Pipeline creation on a load_compute() CACHE MISS: WGSL → MSL →
        // Metal pipeline. This is ONE-TIME per kernel for a persistent harness
        // (production holds a singleton — see the "每帧新建 harness = 2s 税"
        // regression), but a bench that constructs a fresh harness and extracts
        // a single frame charges ALL of it to that frame. Without this counter
        // the compile time hides inside the per-stage residual and reads as
        // "the extractor's own host loops are huge", which would send the next
        // optimisation at entirely the wrong code.
        double create_ms = 0;
        uint32_t n_upload = 0;
        uint32_t n_dispatch = 0;
        uint32_t n_readback = 0;
        uint32_t n_create = 0;      // cache MISSES only
    };
    const HostBreakdown& host_breakdown() const { return hb_; }
    void host_breakdown_reset() { hb_ = HostBreakdown{}; }

private:
    // Attach timestamp writes to the next compute pass, if enabled and a slot
    // pair is free. Returns the descriptor to pass to BeginComputePass (or
    // nullptr for the untouched default path).
    const wgpu::ComputePassDescriptor* ts_pass_desc(
        wgpu::ComputePassDescriptor* storage,
        wgpu::PassTimestampWrites* writes);

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
    bool has_strict_math_ = false;  // ShaderModuleCompilationOptions granted at device creation
    bool strict_math_ = false;
    bool init_called_ = false;
    // [GPU-HANG-A1 2026-08-06] Sticky device-health flag; see healthy().
    bool device_healthy_ = true;

    // [GPU-TS] 512 pass slots = 1024 timestamps. One extract frame encodes far
    // fewer (pyramid blur chain ~80 + detect per octave + sup/aff/ori/desc);
    // overflow silently stops recording rather than failing the frame, so a
    // pathological input degrades the diagnostic instead of the capture.
    static constexpr uint32_t kTsCapacity = 1024;
    bool ts_requested_ = false;
    bool ts_feature_request_to_device_ = false;
    bool ts_feature_granted_ = false;
    bool ts_enabled_ = false;
    // [HOST-BD 2026-09-08] 主机侧分解不需要 GPU 时间戳,却一直和它绑在同一个
    // 开关上 ⇒ Mali-G72(无 TimestampQuery)上永远拿不到 encode/wait 计数,
    // 而那正是最需要它的一台。拆开:OFFICIAL_AETHER_HOST_BD=1 单独打开。
    bool hb_enabled_ = false;
    uint32_t ts_drop_count_ = 0;
    uint32_t ts_capability_ = 0;
    uint32_t ts_status_ = 0;
    uint32_t ts_reason_code_ = 0;
    uint32_t ts_next_ = 0;
    uint32_t ts_resolve_attempt_count_ = 0;
    uint64_t ts_probe_instance_id_ = 0;
    uint64_t ts_extraction_ordinal_ = 0;
    bool ts_pending_ready_ = false;
    uint64_t ts_pending_probe_instance_id_ = 0;
    uint64_t ts_pending_extraction_ordinal_ = 0;
    uint32_t ts_pending_resolve_attempt_count_ = 0;
    std::vector<uint64_t> ts_pending_ticks_;
    wgpu::QuerySet ts_qset_;
    wgpu::Buffer ts_resolve_;    // QueryResolve | CopySrc
    wgpu::Buffer ts_readback_;   // MapRead | CopyDst
    HostBreakdown hb_;           // [HOST-BD] accumulated while ts_enabled_
};

}  // namespace tools
}  // namespace aether

#endif  // AETHER_CPP_TOOLS_DAWN_KERNEL_HARNESS_H
