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

    // Copy `size` bytes from `src` (any CopySrc-tagged buffer) to `dst`
    // (must be MapRead|CopyDst). Submits + waits.
    void copy_to_staging(const wgpu::Buffer& src, const wgpu::Buffer& dst,
                         size_t size);

    // Map a MapRead-usage buffer, copy its contents to a vector<uint8_t>,
    // unmap, return the vector. Spin-waits via WaitAny (Phase 6.2.F's
    // hybrid stability strategy: spin-wait is the RARE path, acceptable
    // for one-shot smoke tests).
    std::vector<uint8_t> readback(const wgpu::Buffer& buf, size_t size);

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
};

}  // namespace tools
}  // namespace aether

#endif  // AETHER_CPP_TOOLS_DAWN_KERNEL_HARNESS_H
