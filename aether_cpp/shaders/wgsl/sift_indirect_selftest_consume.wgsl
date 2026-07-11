// sift_indirect_selftest_consume.wgsl — Stage-A indirect-consumer (kernel 3).
//
// GPU DSP-SIFT M1 Stage A (GPU_DSP_SIFT_PLAN_AFFINE_OFF.md §3-①). Launched via
// DispatchWorkgroupsIndirect with the args produced by the _args pass. Each
// invocation whose linear id < count records its id, so the host can verify the
// indirect grid actually covered [0, count) workgroups — i.e. the GPU read the
// dispatch dims from the buffer, never the CPU. Mirrors how S4/S5 will launch
// one (or a few) workgroups per detected keypoint without a count round-trip.

struct Params {
  count : u32,   // the (already-clamped) keypoint count, for the bound check
};

@group(0) @binding(0) var<storage, read_write> hits : array<u32>; // [count] markers
@group(0) @binding(1) var<uniform>             P    : Params;

@compute @workgroup_size(64, 1, 1)
fn main(@builtin(global_invocation_id) gid : vec3<u32>) {
  let idx : u32 = gid.x;
  if (idx >= P.count) { return; }
  hits[idx] = 1u;
}
