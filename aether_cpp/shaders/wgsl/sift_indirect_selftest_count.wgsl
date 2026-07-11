// sift_indirect_selftest_count.wgsl — Stage-A atomic-counter self-test (kernel 1).
//
// GPU DSP-SIFT M1 Stage A (GPU_DSP_SIFT_PLAN_AFFINE_OFF.md §3-①). This is NOT a
// production pass — it exercises exactly the harness path the real keypoint
// collector needs: an atomic<u32> counter incremented by a flat grid, with a
// capacity guard. The real S3 collector does `let i = atomicAdd(&counter,1u);
// if (i < CAP) { buf[i] = rec; }`; here we just count to prove atomics + the
// indirect plumbing before any real detector exists.
//
// Each invocation whose linear id < P.n does one atomicAdd. Final counter must
// equal P.n (the host gate checks this exactly).

struct Params {
  n   : u32,   // number of "active" elements to count
  cap : u32,   // capacity guard (mirrors the real CAP=24000 keypoint cap)
};

@group(0) @binding(0) var<storage, read_write> counter : atomic<u32>;
@group(0) @binding(1) var<storage, read_write> stamp   : array<u32>; // [CAP] sentinel writes
@group(0) @binding(2) var<uniform>             P       : Params;

@compute @workgroup_size(64, 1, 1)
fn main(@builtin(global_invocation_id) gid : vec3<u32>) {
  let idx : u32 = gid.x;
  if (idx >= P.n) { return; }
  let i : u32 = atomicAdd(&counter, 1u);
  if (i < P.cap) {
    // Write the producing thread's id+1 so the host can confirm a dense,
    // permutation-of-[0,n) fill (every slot written exactly once, no holes).
    stamp[i] = idx + 1u;
  }
}
