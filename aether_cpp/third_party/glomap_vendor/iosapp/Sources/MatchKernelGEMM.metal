#include <metal_stdlib>
#include <metal_simdgroup_matrix>
using namespace metal;

// pw_match_gemm v5 — simdgroup_matrix descriptor matcher. A is streamed straight
// from device (no Ash threadgroup staging), which frees enough threadgroup memory
// to run kMB=128 A-rows per threadgroup (16 simdgroups). The dominant lever here
// is B-amortization: more A-rows per threadgroup => fewer device reads of B (each
// B-strip is reused across all kMB rows). dist=||a||^2+||b||^2-2(A·B^T).
//
// Sweet spot (iPhone 14 Pro / A16, 11568x11568 @ 0.7 ratio, mutual cross-check):
//   kMB= 64 -> 153 ms | kMB=128 -> 119 ms (BEST) | kMB=256 -> 130 ms (occupancy
//   loss from only ~46 resident threadgroups outweighs the halved B traffic).
//
// REQUIRES host-padded A/B query buffers: each query buffer must be allocated
// to a multiple of kMB rows (extra rows zero-filled) so the device-side
// simdgroup_load of A never reads out of bounds. The reduction still guards
// row<rows / col<numB so padding contributes nothing.
//
// Buffers: 0 A half | 1 B half | 2 out int | 3 numA | 4 numB | 5 ratioSq
//          6 normA f32* | 7 normB f32*
// threadgroup: 0 Bsh kBN*kD halfs (16*128*2=4KB) | 1 acc kMB*kBN f32 (128*16*4=8KB)
// dispatch: groups=(nA+kMB-1)/kMB, threadsPerThreadgroup=kSG*32=512.

#define COMPUTE_NORMS_INLINE 0

constant uint kD  = 128u;
constant uint kKT = 16u;           // K-tiles = 128 / 8
constant uint kSG = 16u;           // simdgroups per threadgroup (B-amortization peak)
constant uint kMB = kSG * 8u;      // = 128 A-rows per threadgroup
constant uint kBN = 16u;           // B-cols per strip (fits 32KB tg mem at kMB=128)
constant uint kNT = kBN / 8u;      // = 2 column tiles of 8
constant uint kTGT = kSG * 32u;    // = 512 threads per threadgroup

kernel void pw_match_gemm(device const half*  A       [[buffer(0)]],
                          device const half*  B       [[buffer(1)]],
                          device int*         out      [[buffer(2)]],
                          constant uint&      numA     [[buffer(3)]],
                          constant uint&      numB     [[buffer(4)]],
                          constant float&     ratioSq  [[buffer(5)]],
                          device const float* normA    [[buffer(6)]],
                          device const float* normB    [[buffer(7)]],
                          threadgroup half*   Bsh      [[threadgroup(0)]],
                          threadgroup float*  acc      [[threadgroup(1)]],
                          uint tgid  [[threadgroup_position_in_grid]],
                          uint lid   [[thread_index_in_threadgroup]],
                          uint sgid  [[simdgroup_index_in_threadgroup]]) {
  const uint row0 = tgid * kMB;
  if (row0 >= numA) { return; }
  const uint rows = min(kMB, numA - row0);

  // each simdgroup loads ITS 8-row A-tile straight from device (buffer is
  // host-padded to a multiple of kMB so this never reads OOB). 16 K-tiles.
  const uint aRow0 = row0 + sgid * 8u;
  simdgroup_matrix<half, 8, 8> aFrag[kKT];
  for (uint k = 0; k < kKT; ++k) {
    simdgroup_load(aFrag[k], A + aRow0 * kD + k * 8u, kD, ulong2(0, 0));
  }

  threadgroup float bestT[kMB];
  threadgroup float secondT[kMB];
  threadgroup int   biT[kMB];
  for (uint r = lid; r < kMB; r += kTGT) { bestT[r] = 1e30f; secondT[r] = 1e30f; biT[r] = -1; }
  threadgroup_barrier(mem_flags::mem_threadgroup);

  for (uint col0 = 0; col0 < numB; col0 += kBN) {
    const uint cols = min(kBN, numB - col0);

    for (uint e = lid; e < kBN * kD; e += kTGT) {
      uint r = e / kD, d = e % kD;
      Bsh[e] = (r < cols) ? B[(col0 + r) * kD + d] : half(0);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    for (uint nt = 0; nt < kNT; ++nt) {
      simdgroup_matrix<float, 8, 8> c = make_filled_simdgroup_matrix<float, 8, 8>(0.0f);
      for (uint k = 0; k < kKT; ++k) {
        simdgroup_matrix<half, 8, 8> bF;
        simdgroup_load(bF, Bsh + (nt * 8u) * kD + k * 8u, kD, ulong2(0, 0),
                       /*transpose_matrix=*/true);
        simdgroup_multiply_accumulate(c, aFrag[k], bF, c);
      }
      simdgroup_store(c, acc + (sgid * 8u) * kBN + nt * 8u, kBN, ulong2(0, 0));
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    // in-register top-2 reduction — all kTGT threads (4 lanes/row).
    {
      const uint row = lid / 4u;
      const uint cg  = lid % 4u;
      const uint per = kBN / 4u;     // = 12 cols/lane
      float pb = 1e30f, ps = 1e30f; int pbi = -1;
      if (row < rows) {
        const float na = normA[row0 + row];
        for (uint t = 0; t < per; ++t) {
          const uint c = cg * per + t;
          if (col0 + c >= numB) break;
          const float dist = na + normB[col0 + c] - 2.0f * acc[row * kBN + c];
          if (dist < pb) { ps = pb; pb = dist; pbi = (int)(col0 + c); }
          else if (dist < ps) { ps = dist; }
        }
      }
      for (ushort off = 1; off <= 2; off <<= 1) {
        const float ob = simd_shuffle_xor(pb, off);
        const float os = simd_shuffle_xor(ps, off);
        const int   oi = simd_shuffle_xor(pbi, off);
        if (ob < pb) { ps = min(os, pb); pb = ob; pbi = oi; }
        else         { ps = min(ps, ob); }
      }
      if (cg == 0u && row < rows) {
        float bb = bestT[row], ss = secondT[row]; int bi = biT[row];
        if (pb < bb) { ss = min(bb, ps); bb = pb; bi = pbi; }
        else         { ss = min(ss, pb); }
        bestT[row] = bb; secondT[row] = ss; biT[row] = bi;
      }
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
  }

  if (lid < kMB && lid < rows) {
    out[row0 + lid] = (bestT[lid] < ratioSq * secondT[lid]) ? biT[lid] : -1;
  }
}
