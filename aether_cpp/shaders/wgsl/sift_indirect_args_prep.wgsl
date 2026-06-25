// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// sift_indirect_args_prep.wgsl — tiny "args-prep" compute pass for the BATCHED
// full-GPU DSP-SIFT pipeline (bench/extract_fullgpu_batched.cc).
//
// PURPOSE: convert a GPU atomic count (written by a preceding counting stage,
// e.g. sift_dog_extrema_test.wgsl's `count`) into an indirect-dispatch args
// triple [ceil(count/wg_size), 1, 1] so the NEXT stage can be launched with
// `dispatchWorkgroupsIndirect` — WITHOUT the CPU ever reading the count back.
// This is the radix-sort indirect-args pattern referenced in
// GPU_DSP_SIFT_PLAN.md: "engineer away the mid-pipeline count-readbacks with
// GPU atomic counters + dispatchWorkgroupsIndirect -> ONE forced round-trip /
// frame".
//
// The count is CLAMPED to `cap` (the over-allocated output buffer capacity) so
// the indirect grid can never exceed the buffer the next stage writes/reads.
//
// Bindings (@group(0)):
//   (0) count : atomic<u32> read_write — the preceding stage's atomic counter
//               (read via atomicLoad; never modified here).
//   (1) args  : array<u32> read_write   — the indirect-args buffer; this pass
//               writes args[0]=ceil(min(count,cap)/wg_size), args[1]=1, args[2]=1.
//               Buffer must carry usage = Indirect | Storage | CopyDst.
//   (2) P     : uniform { wg_size, cap, _pad0, _pad1 }
//
// ONE invocation (dispatch 1,1,1). The arithmetic is exact integer ceil-div.

struct ArgsPrepParams {
  wg_size : u32,   // workgroup_size.x of the consuming stage (e.g. 64 for refine)
  cap     : u32,   // capacity of the consuming stage's input buffer (clamp)
  _pad0   : u32,
  _pad1   : u32,
};

@group(0) @binding(0) var<storage, read_write> count : atomic<u32>;
@group(0) @binding(1) var<storage, read_write> args  : array<u32>;
@group(0) @binding(2) var<uniform>             P     : ArgsPrepParams;

@compute @workgroup_size(1, 1, 1)
fn prep(@builtin(global_invocation_id) gid : vec3<u32>) {
  if (gid.x != 0u) { return; }
  let n_raw : u32 = atomicLoad(&count);
  let n : u32 = min(n_raw, P.cap);
  let wg : u32 = max(P.wg_size, 1u);
  let groups : u32 = (n + wg - 1u) / wg;   // ceil(n / wg)
  args[0] = groups;
  args[1] = 1u;
  args[2] = 1u;
}
