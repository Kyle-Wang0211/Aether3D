// sift_indirect_selftest_args.wgsl — Stage-A indirect-args builder (kernel 2).
//
// GPU DSP-SIFT M1 Stage A (GPU_DSP_SIFT_PLAN_AFFINE_OFF.md §3-①). Single-thread
// "tiny pass" that converts the atomic counter into a DispatchWorkgroupsIndirect
// argument triple: args = [ceil(count/WG), 1, 1], clamped to cap. This is the
// real keypoint pipeline's bridge between S3 (atomic append) and S4/S5 (indirect
// launch over exactly the detected keypoints) — the count NEVER returns to CPU.

struct Params {
  wg  : u32,   // workgroup size the indirect consumer launches with
  cap : u32,   // capacity guard
};

@group(0) @binding(0) var<storage, read>       counter : u32;       // read the count back
@group(0) @binding(1) var<storage, read_write> args    : array<u32>; // [3] dispatch dims
@group(0) @binding(2) var<uniform>             P       : Params;

@compute @workgroup_size(1, 1, 1)
fn main() {
  var c : u32 = counter;
  if (c > P.cap) { c = P.cap; }
  let groups : u32 = (c + P.wg - 1u) / P.wg;
  args[0] = groups;
  args[1] = 1u;
  args[2] = 1u;
}
