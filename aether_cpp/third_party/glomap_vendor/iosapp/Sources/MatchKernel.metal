#include <metal_stdlib>
using namespace metal;

// ─────────────────────────────────────────────────────────────────────────
// v0: naive brute-force, fp32 storage + fp32 math. One thread per query in A,
// scans all of B from device memory. Kept as the baseline for the A/B speedup.
// ─────────────────────────────────────────────────────────────────────────
kernel void pw_match_kernel(device const float* A       [[buffer(0)]],
                            device const float* B       [[buffer(1)]],
                            device int*         out      [[buffer(2)]],
                            constant uint&      numA     [[buffer(3)]],
                            constant uint&      numB     [[buffer(4)]],
                            constant float&     ratioSq  [[buffer(5)]],
                            uint                gid      [[thread_position_in_grid]]) {
  if (gid >= numA) { return; }
  const uint D = 128u;
  device const float* a = A + (uint)gid * D;
  float best = 1e30f, second = 1e30f;
  int bi = -1;
  for (uint j = 0; j < numB; ++j) {
    device const float* b = B + j * D;
    float dist = 0.0f;
    for (uint d = 0; d < D; ++d) { float df = a[d] - b[d]; dist += df * df; }
    if (dist < best) { second = best; best = dist; bi = (int)j; }
    else if (dist < second) { second = dist; }
  }
  out[gid] = (best < ratioSq * second) ? bi : -1;
}

// ─────────────────────────────────────────────────────────────────────────
// v1: fp16 STORAGE + threadgroup TILING + fp32 MATH.
//
// • Descriptors are half (uint8 0-255 → half is LOSSLESS: 255 < 2048). Halving
//   the bytes read from device + threadgroup memory ≈ 2× on this bandwidth-bound
//   kernel.
// • Each threadgroup cooperatively loads TILE db descriptors into threadgroup
//   memory once, then every query thread in the group reuses that cached tile —
//   B device reads drop from O(numA·numB) to ~O(numB) (≈ once per group, not per
//   thread). This kills the redundant-read bottleneck (the 36× gap vs theory).
// • All arithmetic (Δ, Δ², accumulate) promoted to float → exact (half square
//   would round for |Δ|>45). The half ALU gain is intentionally skipped; the win
//   here is bandwidth, which fp16 storage already captures.
//
// Threadgroup memory `tile` is sized by the host: TILE*128 halfs.
// ─────────────────────────────────────────────────────────────────────────
constant uint kD = 128u;
constant uint kTILE = 32u;   // db descriptors cached per tile

// v1: query AND db tiles both in threadgroup memory (no per-thread register
// array → no spill). shmem layout: [0 .. TG*128) query tile (one query per
// thread, written once), [TG*128 .. TG*128 + kTILE*128) db tile (cooperatively
// reloaded each iter). Host sets threadgroup length = (TG + kTILE)*128*2 bytes.
kernel void pw_match_tiled(device const half*   A       [[buffer(0)]],
                           device const half*   B       [[buffer(1)]],
                           device int*          out      [[buffer(2)]],
                           constant uint&       numA     [[buffer(3)]],
                           constant uint&       numB     [[buffer(4)]],
                           constant float&      ratioSq  [[buffer(5)]],
                           threadgroup half*    shmem    [[threadgroup(0)]],
                           uint  gid    [[thread_position_in_grid]],
                           uint  lid    [[thread_position_in_threadgroup]],
                           uint  tgsize [[threads_per_threadgroup]]) {
  threadgroup half* qtile = shmem;                 // tgsize * kD
  threadgroup half* btile = shmem + tgsize * kD;   // kTILE * kD

  const bool active = (gid < numA);
  if (active) {                                     // each thread loads its own query
    device const half* a = A + (uint)gid * kD;
    for (uint d = 0; d < kD; ++d) { qtile[lid * kD + d] = a[d]; }
  }
  threadgroup_barrier(mem_flags::mem_threadgroup);

  float best = 1e30f, second = 1e30f;
  int bi = -1;
  threadgroup const half* q = qtile + lid * kD;

  for (uint base = 0; base < numB; base += kTILE) {
    const uint tileCount = min(kTILE, numB - base);
    for (uint idx = lid; idx < tileCount * kD; idx += tgsize) {  // cooperative db load
      btile[idx] = B[base * kD + idx];
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    if (active) {
      for (uint t = 0; t < tileCount; ++t) {
        threadgroup const half* b = btile + t * kD;
        float dist = 0.0f;
        for (uint d = 0; d < kD; ++d) {
          float df = (float)q[d] - (float)b[d];
          dist += df * df;
        }
        if (dist < best) { second = best; best = dist; bi = (int)(base + t); }
        else if (dist < second) { second = dist; }
      }
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);  // btile reused next iter
  }

  if (active) { out[gid] = (best < ratioSq * second) ? bi : -1; }
}
