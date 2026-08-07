// pwofficial_gpu_match_v2.mm — pocketworld-vendored Metal descriptor matcher,
// v2 candidate: KNIFE-A/B single-pass dual-direction fused kernel layered on
// top of the shipped v1 (tiled-GEMM two-pass + KNIFE-C chunked dispatch).
//
// ── v2 design (parity-audited on M3 Pro host, 2026-07-26) ────────────────
// One traversal of the numA x numB dot grid computes BOTH directions:
//   * row-wise top-2 (A→B) tracked in registers, gated in-kernel exactly as
//     v1 (angular acos domain plain / normalized-L2 + 131072 sentinel
//     guided), written to outAB;
//   * column-wise top-2 partials per (row-block, column) written to a small
//     SoA device buffer (best/second fp32 + row idx int32, ~6 MB @ 8192²);
//     a tiny merge kernel (pw_match_merge_cols) reduces the partials over
//     row-blocks in ASCENDING order and applies the SAME final gates,
//     reproducing the standalone B→A pass bit-exactly. The fully redundant
//     second GEMM of v1 is eliminated (~2x), and the 32-wide column tile +
//     per-simdgroup accumulator staging cuts threadgroup barriers from 6 to
//     2 per 32 columns (measured 3.05x total, 256,418/256,418 matches
//     byte-identical on the 402-pair K12 device-capture fixture).
// Tie-break semantics (no epsilon: dots are exact integers < 2^24 in fp32):
// best = max dot, LOWEST index wins ties; second = max of the remaining
// multiset. Every scan iterates ascending index with strict `>`; every merge
// level (lcg butterfly, ascending-sgid loop, ascending row-block loop)
// combines an ordered lower-index chunk with a higher-index chunk keeping
// "ours" on ties — so the global tie-break matches v1's single ascending
// scan exactly.
// Zero-padding invariant: the host pads BOTH descriptor buffers (and, when
// guided, both keypoint buffers) to 128-row multiples, zero-filled, and
// over-allocates outAB to the padded row count. Padded rows/columns produce
// dot == 0 candidates which under strict-`>` insertion against best/second
// initialized to 0 can never become best nor raise second — constructively
// harmless — so the hot loops carry NO per-candidate bounds guards (guards
// measurably cost ~1.4 ms/pair via lost unrolling). Verified on truncated
// odd-count fixtures.
// Guided mode: function-constant-specialized pipelines. The plain pipeline
// (kGuideMode=0) keeps the unguarded hot loop — zero cost. Guided pipelines
// insert the v1 geometry gate before top-2 insertion in BOTH trackers:
//   row (A→B):    q = pointsA[row], d = pointsB[col], M = matrixAB;
//   column (B→A): q = pointsB[col], d = pointsA[row], M = matrixBA —
// exactly what v1's second pass computes with its swapped arguments.
// ⚠️ GUIDED DEFAULTS TO THE V1 PATH. The gate's nom is a near-cancellation,
// so its float value is hypersensitive to the compiler's fast-math algebra,
// which differs between the two kernels' compilations (loop shapes drive
// different contraction/reassociation). Host-probed on M3 Pro: 1,575
// mul/add/fma recombination hypotheses of the gate formula, extracted
// against 1,112 black-box borderline probes of the compiled v1 pipeline —
// ZERO reproduce v1's accept bits (best 62/712 mismatches; mode-2 also hits
// non-emulable approximate native division). Bit-parity of a fused guided
// gate against v1 is therefore NOT achievable by construction; divergence is
// confined to candidates within ~1e-3 relative of the residual threshold
// (measured: only razor-thin res=0.05 fixtures flip, ±1 match/pair). Until
// a bit-stability strategy exists, guided calls route to the proven v1
// two-pass kernel (bit-exact trivially); the fused guided pipelines remain
// implemented and opt-in for device evaluation.
// Kill switches (env, cached per process like the other knobs):
//   OFFICIAL_AETHER_MATCH_V2       default 1; 0 = shipped v1 path verbatim.
//   OFFICIAL_AETHER_MATCH_V2_HALF  default 0; 1 = half-storage ABI instead
//                                  of the default packed-u8 ABI (triage).
//   OFFICIAL_AETHER_MATCH_V2_GUIDED_FUSED default 0 (guided → v1 path);
//                                  1 = fused guided kernel (near-parity:
//                                  boundary-only divergence, see above).
//   OFFICIAL_AETHER_MATCH_CHUNK_TARGET_MS keeps its KNIFE-C meaning for v2:
//   0 = one command buffer (fused + merge); >0 = row-block chunks sized by
//   the same self-calibrating cost model with the same thermal duty-cycle
//   gaps, merge dispatched once after the last chunk. Row blocks are
//   independent and partials are indexed by ABSOLUTE row-block, so any
//   chunking is bit-identical (host-verified chunked-vs-monolithic cmp).
// Whole match calls are serialized behind a mutex (buffer pools are
// grow-only shared state; GPU work is serial anyway).
//
// ── v1 heritage (kept verbatim below, selectable at runtime) ─────────────
// Adapted from the research harness's GpuMatch.m (iosapp/Sources,
// bench-proven on iPhone 14 Pro: 11568×11568 @ 0.7 ratio, mutual cross-check
// in 119 ms). Two deltas vs the harness original:
//
//   1. Kernel loads via newLibraryWithSource (embedded MSL below, compiled
//      once and cached) instead of newDefaultLibrary — the harness relied on
//      its app target compiling MatchKernelGEMM.metal into the main bundle's
//      default.metallib, which a CocoaPods static-lib target does not do.
//   2. Exports a PAIRS variant (aether_gpu_match_gemm_pairs) that emits the
//      mutually cross-checked [idxA, idxB] list — the streaming SfM
//      add_frame persists these via WriteMatches/WriteTwoViewGeometry.
//      Mutual B→A verification is kept EXACTLY (one-directional matching
//      feeds many-to-one false matches → block drift; hard constraint).
//
// aether_sfm_add_frame (libglomap_core.a) references this symbol WEAKLY and
// falls back to the CPU matcher when it is absent or errors — so host
// benches and any target without this TU keep working unchanged.

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <atomic>
#include <chrono>              // [GPU-HANG-A1] bounded command-buffer wait
#include <condition_variable>  // [GPU-HANG-A1] std::condition_variable (跨端)
#include <cstdlib>
#include <memory>
#include <mutex>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unordered_map>
#include <unistd.h>

#if __has_include("aether/sfm/descriptor_residency_policy_v1.h")
#include "aether/sfm/descriptor_residency_policy_v1.h"
#else
#include "../include/aether/sfm/descriptor_residency_policy_v1.h"
#endif

static void ClearAllDescriptorResidencyForDeviceError(void);

// ── [RC7-FILELOG 2026-07-11] Last command-buffer error stash ─────────────
// The Metal error object (domain/code/description, e.g.
// IOGPUCommandQueueErrorDomain "GPU hang under thermal pressure") is only
// visible HERE, but the pair id + capture context live in the caller
// (aether_sfm_c.cc NoteGpuMatchFailure, which writes the timestamped
// sfm_match_fail.jsonl next to the capture db). Bridge: stash the latest
// error text; the caller pulls it via aether_gpu_match_last_error (declared
// WEAK there, so host builds without this TU keep working).
static std::mutex gLastErrLock;
static char gLastErr[192] = {0};

static void stashLastError(NSError* error) {
  NSString* text =
      error ? [NSString stringWithFormat:@"%@ code=%ld %@", error.domain,
                                         (long)error.code,
                                         error.localizedDescription ?: @""]
            : @"(nil error)";
  std::lock_guard<std::mutex> lk(gLastErrLock);
  strlcpy(gLastErr, text.UTF8String ?: "(utf8 failed)", sizeof(gLastErr));
}

// Copies the last stashed command-buffer error into buf (NUL-terminated).
// Returns the number of bytes copied excluding the NUL (0 = nothing stashed).
extern "C" int aether_gpu_match_last_error(char* buf, int cap) {
  if (!buf || cap <= 0) return 0;
  std::lock_guard<std::mutex> lk(gLastErrLock);
  const size_t n = strlcpy(buf, gLastErr, (size_t)cap);
  return (int)(n < (size_t)cap ? n : (size_t)cap - 1);
}

// [MATCH-FAIL TELEMETRY 2026-07-11] rc=7 is the ONLY "GPU command
// failed" code — distinct from rc=0 with *out_num_matches==0 (a
// legitimate zero-match pair) — so callers can bucket failures by rc.
// Log the underlying Metal error rate-limited (a thermal collapse fails
// hundreds of pairs back-to-back; capture 43 lost a 66-frame block this
// way) so device logs show WHY (e.g. IOGPUCommandQueueErrorDomain /
// GPU hang under thermal pressure).
// [RC7-FILELOG 2026-07-11] Also stash the Metal error for the caller's
// timestamped sfm_match_fail.jsonl line (NSLog is lost on detached/拔线
// runs; the jsonl in the app container is recovered by devicectl copy).
// Shared by the v1 and v2 paths so the rate limit covers the process.
static void NoteCmdError(id<MTLCommandBuffer> cmd) {
  static std::atomic<long> gCmdErrCount{0};
  const long k = ++gCmdErrCount;
  if (k <= 5 || (k % 100) == 0) {
    NSLog(@"[pwofficial_gpu_match] command buffer error #%ld (rc=7): %@", k,
          cmd.error);
  }
  stashLastError(cmd.error);
  ClearAllDescriptorResidencyForDeviceError();
}

// ── [GPU-HANG-A1 2026-08-06] 带超时的 command buffer 等待 ────────────────
// MoltenVK handleMTLCommandBufferError 分类学 + Chromium GPU watchdog 有限
// 超时(挂死的 GPU 等待绝不无限期)。等待用 std::condition_variable::wait_for
// (标准库,iOS/安卓/鸿蒙三端同一语义;不用 dispatch_semaphore —— 跨端铁律)。
// Apple 专属代码仅在下方 Metal 错误码 → 可移植返回值分类的映射处;Vulkan
// 后端(安卓/鸿蒙)将 VK_ERROR_DEVICE_LOST 等映射到同一返回值分类。
// 返回:0=成功 7=可重试(超时/瞬态错误——上层 GpuMatchGemmPairsRetry 只
// 重试 7) 8=永久(设备拉黑/后台受限——上层不得重试,fail-closed 跳过)。
// helper 自己 commit;addCompletedHandler 必须在 commit 之前注册。
static uint64_t CmdWaitTimeoutMs(void) {
  // 默认 30s,env OFFICIAL_AETHER_GPU_MATCH_WAIT_MS 覆盖(>0 生效,一次性缓存)。
  static const uint64_t v = [] {
    const char* e = getenv("OFFICIAL_AETHER_GPU_MATCH_WAIT_MS");
    if (e != nullptr) {
      const long long ms = atoll(e);
      if (ms > 0) return (uint64_t)ms;
    }
    return (uint64_t)30000;
  }();
  return v;
}

static int WaitCmdWithTimeout(id<MTLCommandBuffer> cmd, uint64_t timeout_ms) {
  // shared_ptr:超时返回后 handler 仍可能晚到,状态必须活到 handler 之后。
  struct WaitState {
    std::mutex mu;
    std::condition_variable cv;
    bool done = false;
  };
  auto state = std::make_shared<WaitState>();
  // handler 只置位,不做重活(MoltenVK 同款:重活留在等待线程)。
  [cmd addCompletedHandler:^(id<MTLCommandBuffer>) {
    std::lock_guard<std::mutex> lk(state->mu);
    state->done = true;
    state->cv.notify_all();
  }];
  [cmd commit];
  {
    std::unique_lock<std::mutex> lk(state->mu);
    if (!state->cv.wait_for(lk, std::chrono::milliseconds(timeout_ms),
                            [&] { return state->done; })) {
      // 超时:**不要**继续等(Chromium watchdog 语义)。NoteCmdError 风格的
      // 日志 + 错误 stash,判为可重试(上层退避重试或最终跳过该 pair)。
      static std::atomic<long> gCmdTimeoutCount{0};
      const long k = ++gCmdTimeoutCount;
      if (k <= 5 || (k % 100) == 0) {
        NSLog(@"[pwofficial_gpu_match] command buffer wait TIMEOUT #%ld after "
              @"%llu ms (rc=7): status=%ld",
              k, (unsigned long long)timeout_ms, (long)cmd.status);
      }
      stashLastError([NSError
          errorWithDomain:MTLCommandBufferErrorDomain
                     code:MTLCommandBufferErrorTimeout
                 userInfo:@{
                   NSLocalizedDescriptionKey : [NSString
                       stringWithFormat:@"host-side wait timeout after %llu ms",
                                        (unsigned long long)timeout_ms]
                 }]);
      ClearAllDescriptorResidencyForDeviceError();
      return 7;
    }
  }
  // 完成:按 MoltenVK handleMTLCommandBufferError 映射表分类 status/error。
  if (cmd.status == MTLCommandBufferStatusError || cmd.error != nil) {
    NSError* err = cmd.error;
    NoteCmdError(cmd);  // 既有遥测/stash/残留清理照旧
    if (err != nil &&
        [err.domain isEqualToString:MTLCommandBufferErrorDomain]) {
      switch (err.code) {
        case MTLCommandBufferErrorAccessRevoked:
          // 即旧名 MTLCommandBufferErrorBlacklisted(同值 4,macOS 13/iOS 16
          // 改名):设备被系统拉黑 → 永久失败,上层不得重试。
          return 8;
        case MTLCommandBufferErrorNotPermitted:
          // iOS 后台无 entitlement 跑 GPU 的错误码 —— 配合后台续跑要单独
          // 分档:不是硬件死,但当前进程状态下重试必然再失败,判永久。
          return 8;
        case MTLCommandBufferErrorTimeout:
          // GPU 侧超时(如热压 GPU hang)→ 可重试。
          return 7;
        default:
          break;
      }
    }
    return 7;  // 其余错误按瞬态处理(与既有 rc=7 语义一致)
  }
  return 0;
}

// ── pw_match_gemm v6 kernel — COLMAP-faithful angular matcher (v1) ───────
// Bit-parity with FindBestMatchesOneWayBruteForce (colmap/feature/sift.cc:770):
// best/second are selected by MAXIMUM dot product (the GEMM output), and the
// ratio + absolute thresholds are applied in the acos(dot/512^2) ANGULAR
// domain — NOT squared-L2. This closes the audited divergences vs the
// COLMAP-native reference that produced cloud_k12_mutual.ply:
//   1. metric domain: angular acos, not squared-L2;
//   2. absolute max_distance gate (default 0.7) — was missing entirely;
//   3. single-candidate rows: second_dot stays 0 → second_dist = acos(0) =
//      pi/2, exactly as COLMAP (its second_best_dot_product init is 0).
// Descriptors are SIFT-normalized to L2 norm 512, so dot/512^2 = cosine and
// kInvSqNorm = 1/kSqSiftDescriptorNorm = 1/262144. No per-descriptor norms
// are needed (COLMAP uses the idealized 512^2 normalization constant).
static const char* kGemmKernelSrc = R"MSL(
#include <metal_stdlib>
#include <metal_simdgroup_matrix>
using namespace metal;

constant uint kD  = 128u;
constant uint kKT = 16u;
constant uint kSG = 16u;
constant uint kMB = kSG * 8u;
constant uint kBN = 16u;
constant uint kNT = kBN / 8u;
constant uint kTGT = kSG * 32u;
constant float kInvSqNorm = 1.0f / 262144.0f;  // 1 / kSqSiftDescriptorNorm (512^2)

kernel void pw_match_gemm(device const half*  A          [[buffer(0)]],
                          device const half*  B          [[buffer(1)]],
                          device int*         out         [[buffer(2)]],
                          constant uint&      numA        [[buffer(3)]],
                          constant uint&      numB        [[buffer(4)]],
                          constant float&     maxRatio    [[buffer(5)]],
                          constant float&     maxDistance [[buffer(6)]],
                          device const float2* pointsA     [[buffer(7)]],
                          device const float2* pointsB     [[buffer(8)]],
                          device const float*  guideMatrix [[buffer(9)]],
                          constant uint&       guideMode   [[buffer(10)]],
                          constant float&      maxResidual [[buffer(11)]],
                          constant uint&       rowBase     [[buffer(12)]],
                          threadgroup half*   Bsh         [[threadgroup(0)]],
                          threadgroup float*  acc         [[threadgroup(1)]],
                          uint tgid  [[threadgroup_position_in_grid]],
                          uint lid   [[thread_index_in_threadgroup]],
                          uint sgid  [[simdgroup_index_in_threadgroup]]) {
  // rowBase: first row-block of this chunk. Chunked dispatch splits one
  // logical (numA x numB) pass into several small command buffers so a
  // single dispatch never occupies the GPU long enough to starve the
  // ARKit camera/render pipeline (rc=7 pathology). Row blocks are
  // independent — per-row results are identical for any chunking.
  const uint row0 = (rowBase + tgid) * kMB;
  if (row0 >= numA) { return; }
  const uint rows = min(kMB, numA - row0);

  const uint aRow0 = row0 + sgid * 8u;
  simdgroup_matrix<half, 8, 8> aFrag[kKT];
  for (uint k = 0; k < kKT; ++k) {
    simdgroup_load(aFrag[k], A + aRow0 * kD + k * 8u, kD, ulong2(0, 0));
  }

  // Track the two LARGEST dot products per row (COLMAP: best = max dot,
  // init 0 so only positive dots become candidates; index -1 if none).
  threadgroup float bestT[kMB];
  threadgroup float secondT[kMB];
  threadgroup int   biT[kMB];
  for (uint r = lid; r < kMB; r += kTGT) { bestT[r] = 0.0f; secondT[r] = 0.0f; biT[r] = -1; }
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
                       true);
        simdgroup_multiply_accumulate(c, aFrag[k], bF, c);
      }
      simdgroup_store(c, acc + (sgid * 8u) * kBN + nt * 8u, kBN, ulong2(0, 0));
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    {
      const uint row = lid / 4u;
      const uint cg  = lid % 4u;
      const uint per = kBN / 4u;
      float pb = 0.0f, ps = 0.0f; int pbi = -1;  // best/second DOT (max)
      if (row < rows) {
        for (uint t = 0; t < per; ++t) {
          const uint c = cg * per + t;
          if (col0 + c >= numB) break;
          bool geometryOK = true;
          if (guideMode == 1u) {
            const float2 q = pointsA[row0 + row];
            const float2 d = pointsB[col0 + c];
            const float3 p1 = float3(q, 1.0f);
            const float3 p2 = float3(d, 1.0f);
            const float3 line2 = float3(
                guideMatrix[0] * p1.x + guideMatrix[1] * p1.y + guideMatrix[2],
                guideMatrix[3] * p1.x + guideMatrix[4] * p1.y + guideMatrix[5],
                guideMatrix[6] * p1.x + guideMatrix[7] * p1.y + guideMatrix[8]);
            const float3 line1 = float3(
                guideMatrix[0] * p2.x + guideMatrix[3] * p2.y + guideMatrix[6],
                guideMatrix[1] * p2.x + guideMatrix[4] * p2.y + guideMatrix[7],
                guideMatrix[2] * p2.x + guideMatrix[5] * p2.y + guideMatrix[8]);
            const float nom = dot(p2, line2);
            const float denom = dot(line2.xy, line2.xy) +
                                dot(line1.xy, line1.xy);
            geometryOK = denom > 1e-12f &&
                         nom * nom <= maxResidual * denom;
          } else if (guideMode == 2u) {
            const float2 q = pointsA[row0 + row];
            const float2 d = pointsB[col0 + c];
            const float hx = guideMatrix[0] * q.x + guideMatrix[1] * q.y +
                             guideMatrix[2];
            const float hy = guideMatrix[3] * q.x + guideMatrix[4] * q.y +
                             guideMatrix[5];
            const float hz = guideMatrix[6] * q.x + guideMatrix[7] * q.y +
                             guideMatrix[8];
            if (abs(hz) <= 1e-8f) {
              geometryOK = false;
            } else {
              const float2 delta = float2(hx / hz, hy / hz) - d;
              geometryOK = dot(delta, delta) <= maxResidual;
            }
          }
          if (!geometryOK) continue;
          const float dot = acc[row * kBN + c];
          if (dot > pb) { ps = pb; pb = dot; pbi = (int)(col0 + c); }
          else if (dot > ps) { ps = dot; }
        }
      }
      for (ushort off = 1; off <= 2; off <<= 1) {
        const float ob = simd_shuffle_xor(pb, off);
        const float os = simd_shuffle_xor(ps, off);
        const int   oi = simd_shuffle_xor(pbi, off);
        if (ob > pb) { ps = max(os, pb); pb = ob; pbi = oi; }
        else         { ps = max(ps, ob); }
      }
      if (cg == 0u && row < rows) {
        float bb = bestT[row], ss = secondT[row]; int bi = biT[row];
        if (pb > bb) { ss = max(bb, ps); bb = pb; bi = pbi; }
        else         { ss = max(ss, pb); }
        bestT[row] = bb; secondT[row] = ss; biT[row] = bi;
      }
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
  }

  if (lid < kMB && lid < rows) {
    const int bi = biT[lid];
    if (bi < 0) { out[row0 + lid] = -1; return; }
    // COLMAP FindBestMatchesOneWayBruteForce (sift.cc:801-816):
    //   best_dist = acos(min(best_dot/512^2, 1));  reject if best_dist > max_distance
    //   second_dist = acos(min(second_dot/512^2, 1));
    //   reject if best_dist >= max_ratio * second_dist  (>= keeps best==second out)
    float bd;
    float sd;
    if (guideMode == 0u) {
      bd = acos(min(bestT[lid] * kInvSqNorm, 1.0f));
      sd = acos(min(secondT[lid] * kInvSqNorm, 1.0f));
    } else {
      // COLMAP's guided CPU path applies the thresholds in normalized L2.
      // With fixed-norm 512 SIFT descriptors, L2^2 / 512^2 = 2 - 2*cos.
      // A filtered candidate has COLMAP's sentinel distance 512, so it also
      // serves as the second-best baseline when only one candidate lies in the
      // geometry band.
      const float secondDot = max(secondT[lid], 131072.0f);
      bd = sqrt(max(0.0f, 2.0f - 2.0f * bestT[lid] * kInvSqNorm));
      sd = sqrt(max(0.0f, 2.0f - 2.0f * secondDot * kInvSqNorm));
    }
    const bool keep = (bd <= maxDistance) && (bd < maxRatio * sd);
    out[row0 + lid] = keep ? bi : -1;
  }
}
)MSL";

// ── [KNIFE-C 2026-07-26, signed] Chunked dispatch + thermal duty-cycle ───
// cap45 pathology: under thermal-serious a monolithic 8192² dispatch
// (~25ms cool, ~160ms+ downclocked) monopolizes the GPU and ARKit loses
// Metal command buffers (rc=7) → camera freeze. Apple's documented remedy
// for long compute coexisting with rendering is splitting work into small
// chunks and interleaving (developer.apple.com/forums/thread/87964);
// MTLCommandQueue has no priority/QoS API. So: split each direction's
// row range into chunks sized to ~OFFICIAL_AETHER_MATCH_CHUNK_TARGET_MS
// of GPU time (default 6ms, 0 = legacy monolithic dispatch), keep exactly
// one command buffer in flight, and under thermal serious/critical insert
// a gap between chunks (duty-cycle) so the camera pipeline always has GPU
// headroom. Row blocks are independent in the kernel, so the match set is
// bit-identical for any chunking (host-verified by parity diff).
static double ChunkTargetMs(void) {
  static double v = -1.0;
  if (v < 0.0) {
    const char* e = getenv("OFFICIAL_AETHER_MATCH_CHUNK_TARGET_MS");
    v = e ? atof(e) : 6.0;
    if (v < 0.0) v = 0.0;
  }
  return v;
}
// Cool-state (nominal/fair) chunk target. Contention only bites under
// thermal serious/critical, and each chunk costs a CPU↔GPU sync round-trip
// (host-measured ~19% at 6ms chunks), so when cool we use bigger chunks and
// only tighten to ChunkTargetMs() when the device heats up.
static double ChunkTargetCoolMs(void) {
  static double v = -1.0;
  if (v < 0.0) {
    const char* e = getenv("OFFICIAL_AETHER_MATCH_CHUNK_TARGET_COOL_MS");
    v = e ? atof(e) : 16.0;
    if (v < 0.0) v = 0.0;
  }
  const double hot = ChunkTargetMs();
  return v > hot ? v : hot;
}
// ── [SPRINT-MODE 2026-07-26, signed] Capture-active flag ─────────────────
// The duty-cycle gaps and small hot chunks exist ONLY to keep the ARKit
// camera/render pipeline fed while capturing. Once the user taps finish the
// camera session stops and there is nothing left to yield to — yet the
// queued-frame drain and the finalize enrichment (full quadratic) used to
// keep running at thermal half-speed. The Swift plugin flips this flag on
// AR-session start/stop (@_silgen_name binding); while inactive the matcher
// runs full speed: no duty gaps, cool-size chunks. Pure scheduling — the
// match set is bit-identical either way. Default 1 (capture semantics) so
// host tools and any caller that never flips it keep today's behaviour on a
// thermally-serious machine.
static std::atomic<int> gCaptureActive{1};
extern "C" void aether_gpu_match_set_capture_active(int active) {
  gCaptureActive.store(active ? 1 : 0, std::memory_order_relaxed);
}
// [SPRINT-RACE 2026-07-26, signed] Read side for the Dart worker: the
// finish_pending message travels the same FIFO as frame events, so a finish
// tapped while a frame event is mid-flight cannot flip the Dart flag in time
// to stop that event's preview BA (cap_1785070530166049 lost 9.5s exactly
// this way). Swift flips gCaptureActive synchronously in stopSession, so an
// FFI read here closes the race window.
// `used` + default visibility: the only referencer is the Dart worker's
// runtime dlsym — without a static reference the linker dead-strips the
// symbol and the race gate silently degrades to message-only.
extern "C" __attribute__((used, visibility("default"))) int
aether_gpu_match_get_capture_active(void) {
  return gCaptureActive.load(std::memory_order_relaxed);
}
static bool ThermalHot(void) {
  if (gCaptureActive.load(std::memory_order_relaxed) == 0) return false;
  if (@available(iOS 11.0, macOS 10.10.3, *)) {
    const NSProcessInfoThermalState st =
        NSProcessInfo.processInfo.thermalState;
    return st == NSProcessInfoThermalStateSerious ||
           st == NSProcessInfoThermalStateCritical;
  }
  return false;
}
// Extra idle gap between chunks as % of the last chunk's GPU time.
// serious default 100 (≈50% duty), critical default 300 (≈25% duty).
// Sprint mode (capture inactive) always returns 0 — nothing to yield to.
static double ThermalGapPct(void) {
  if (gCaptureActive.load(std::memory_order_relaxed) == 0) return 0.0;
  if (@available(iOS 11.0, macOS 10.10.3, *)) {
    const NSProcessInfoThermalState st =
        NSProcessInfo.processInfo.thermalState;
    if (st == NSProcessInfoThermalStateSerious) {
      static double v = -1.0;
      if (v < 0.0) {
        const char* e = getenv("OFFICIAL_AETHER_MATCH_GAP_SERIOUS_PCT");
        v = e ? atof(e) : 100.0;
        if (v < 0.0) v = 0.0;
      }
      return v;
    }
    if (st == NSProcessInfoThermalStateCritical) {
      static double v = -1.0;
      if (v < 0.0) {
        const char* e = getenv("OFFICIAL_AETHER_MATCH_GAP_CRITICAL_PCT");
        v = e ? atof(e) : 300.0;
        if (v < 0.0) v = 0.0;
      }
      return v;
    }
  }
  return 0.0;
}
// EMA of measured GPU ms per (row threadgroup × 1024 database columns) —
// the chunk sizer's cost model. Self-calibrates across thermal states.
// v1 and v2 keep separate EMAs (a v2 fused threadgroup costs ~2x a v1
// per-direction threadgroup; the model self-calibrates either way).
static std::atomic<double> gMsPerTgKCol{0.0};
static std::atomic<double> gMsPerTgKColV2{0.0};

// Lazily-built shared Metal context (v1).
static id<MTLDevice> gDev;
static id<MTLCommandQueue> gQueue;
static id<MTLComputePipelineState> gGemm;

static BOOL ensureMetal(void) {
  if (gGemm) return YES;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    gDev = MTLCreateSystemDefaultDevice();
    if (!gDev) return;
    gQueue = [gDev newCommandQueue];
    NSError* e = nil;
    id<MTLLibrary> lib = [gDev
        newLibraryWithSource:[NSString stringWithUTF8String:kGemmKernelSrc]
                     options:nil
                       error:&e];
    if (!lib) {
      NSLog(@"[pwofficial_gpu_match] kernel compile failed: %@", e);
      return;
    }
    id<MTLFunction> f = [lib newFunctionWithName:@"pw_match_gemm"];
    if (f) gGemm = [gDev newComputePipelineStateWithFunction:f error:&e];
    if (!gGemm) NSLog(@"[pwofficial_gpu_match] pipeline failed: %@", e);
  });
  return gGemm != nil;
}

// Shared GEMM implementation (v1, shipped path — kept verbatim; selected by
// OFFICIAL_AETHER_MATCH_V2=0). guideMode=0 is the original matcher;
// guideMode=1 constrains candidates by E/F and guideMode=2 by H. The reverse
// pass receives matrixBA (E/F transpose or H inverse), preserving the same
// mutual cross-check as the unconstrained path.
static int matchPairsImpl(const uint8_t* dA, int nA, const float* xyA,
                          const uint8_t* dB, int nB, const float* xyB,
                          double max_ratio, const float* matrixAB,
                          const float* matrixBA, uint32_t guideMode,
                          float maxResidual, uint32_t* out_pairs,
                          int max_pairs, int* out_num_matches) {
  @autoreleasepool {
    if (out_num_matches) *out_num_matches = 0;
    if (!dA || !dB || nA <= 0 || nB <= 0) return 1;
    if (out_pairs != nullptr && max_pairs <= 0) return 1;
    if (guideMode > 2u) return 1;
    if (guideMode != 0u &&
        (!xyA || !xyB || !matrixAB || !matrixBA || maxResidual <= 0.0f)) {
      return 1;
    }
    if (!ensureMetal()) return 2;
    const int D = 128;
    // Host-padded query buffers: multiple of kMB(128) rows, zero-filled,
    // so the kernel's device-side simdgroup_load never reads OOB.
    NSUInteger nApad = (((NSUInteger)nA + 127) / 128) * 128;
    NSUInteger nBpad = (((NSUInteger)nB + 127) / 128) * 128;
    id<MTLBuffer> aBuf = [gDev newBufferWithLength:nApad * D * sizeof(__fp16)
                                           options:MTLResourceStorageModeShared];
    id<MTLBuffer> bBuf = [gDev newBufferWithLength:nBpad * D * sizeof(__fp16)
                                           options:MTLResourceStorageModeShared];
    if (!aBuf || !bBuf) return 5;
    __fp16* af = (__fp16*)aBuf.contents;
    for (NSUInteger i = 0; i < (NSUInteger)nA * D; ++i) af[i] = (__fp16)dA[i];
    for (NSUInteger i = (NSUInteger)nA * D; i < nApad * D; ++i) af[i] = 0;
    __fp16* bf = (__fp16*)bBuf.contents;
    for (NSUInteger i = 0; i < (NSUInteger)nB * D; ++i) bf[i] = (__fp16)dB[i];
    for (NSUInteger i = (NSUInteger)nB * D; i < nBpad * D; ++i) bf[i] = 0;
    id<MTLBuffer> outAB = [gDev newBufferWithLength:(NSUInteger)nA * sizeof(int)
                                            options:MTLResourceStorageModeShared];
    id<MTLBuffer> outBA = [gDev newBufferWithLength:(NSUInteger)nB * sizeof(int)
                                            options:MTLResourceStorageModeShared];
    if (!outAB || !outBA) return 6;
    static const float kDummyPoints[2] = {0.0f, 0.0f};
    static const float kDummyMatrix[9] = {1.0f, 0.0f, 0.0f,
                                          0.0f, 1.0f, 0.0f,
                                          0.0f, 0.0f, 1.0f};
    const float* pointsA = guideMode == 0u ? kDummyPoints : xyA;
    const float* pointsB = guideMode == 0u ? kDummyPoints : xyB;
    const float* matrixAtoB = guideMode == 0u ? kDummyMatrix : matrixAB;
    const float* matrixBtoA = guideMode == 0u ? kDummyMatrix : matrixBA;
    const NSUInteger pointsALength =
        guideMode == 0u ? sizeof(kDummyPoints)
                        : (NSUInteger)nA * 2 * sizeof(float);
    const NSUInteger pointsBLength =
        guideMode == 0u ? sizeof(kDummyPoints)
                        : (NSUInteger)nB * 2 * sizeof(float);
    id<MTLBuffer> pointsABuf =
        [gDev newBufferWithBytes:pointsA
                          length:pointsALength
                         options:MTLResourceStorageModeShared];
    id<MTLBuffer> pointsBBuf =
        [gDev newBufferWithBytes:pointsB
                          length:pointsBLength
                         options:MTLResourceStorageModeShared];
    id<MTLBuffer> matrixABBuf =
        [gDev newBufferWithBytes:matrixAtoB
                          length:9 * sizeof(float)
                         options:MTLResourceStorageModeShared];
    id<MTLBuffer> matrixBABuf =
        [gDev newBufferWithBytes:matrixBtoA
                          length:9 * sizeof(float)
                         options:MTLResourceStorageModeShared];
    if (!pointsABuf || !pointsBBuf || !matrixABBuf || !matrixBABuf) return 6;
    // COLMAP thresholds passed straight through (angular domain in-kernel):
    // max_ratio from the caller (product default 0.8), max_distance = COLMAP's
    // SiftMatchingOptions default 0.7. The angular kernel needs no
    // per-descriptor norms — it uses the idealized 512^2 normalization.
    float maxRatio = (float)max_ratio;
    if (maxRatio <= 0.0f) maxRatio = 0.8f;
    float maxDistance = 0.7f;  // colmap::SiftMatchingOptions::max_distance default
    const NSUInteger bshLen = 16 * 128 * sizeof(__fp16);
    const NSUInteger accLen = 128 * 16 * sizeof(float);
    // Encodes one row-chunk of one direction (rowBase..rowBase+groups blocks).
    auto encChunk = [&](id<MTLCommandBuffer> cmd, id<MTLBuffer> Q,
                        id<MTLBuffer> Db, id<MTLBuffer> O, id<MTLBuffer> Qxy,
                        id<MTLBuffer> Dbxy, id<MTLBuffer> M, uint32_t nQ,
                        uint32_t nDb, uint32_t rowBase, NSUInteger groups) {
      id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
      [enc setComputePipelineState:gGemm];
      [enc setBuffer:Q offset:0 atIndex:0];
      [enc setBuffer:Db offset:0 atIndex:1];
      [enc setBuffer:O offset:0 atIndex:2];
      [enc setBytes:&nQ length:4 atIndex:3];
      [enc setBytes:&nDb length:4 atIndex:4];
      [enc setBytes:&maxRatio length:4 atIndex:5];
      [enc setBytes:&maxDistance length:4 atIndex:6];
      [enc setBuffer:Qxy offset:0 atIndex:7];
      [enc setBuffer:Dbxy offset:0 atIndex:8];
      [enc setBuffer:M offset:0 atIndex:9];
      [enc setBytes:&guideMode length:4 atIndex:10];
      [enc setBytes:&maxResidual length:4 atIndex:11];
      [enc setBytes:&rowBase length:4 atIndex:12];
      [enc setThreadgroupMemoryLength:bshLen atIndex:0];
      [enc setThreadgroupMemoryLength:accLen atIndex:1];
      [enc dispatchThreadgroups:MTLSizeMake(groups, 1, 1)
          threadsPerThreadgroup:MTLSizeMake(512, 1, 1)];
      [enc endEncoding];
    };
    const double chunkTargetMs = ChunkTargetMs();
    if (chunkTargetMs <= 0.0) {
      // Legacy monolithic path (kill switch): both directions in a single
      // command buffer — the exact pre-KNIFE-C scheduling.
      id<MTLCommandBuffer> cmd = [gQueue commandBuffer];
      encChunk(cmd, aBuf, bBuf, outAB, pointsABuf, pointsBBuf, matrixABBuf,
               (uint32_t)nA, (uint32_t)nB, 0u,
               ((NSUInteger)nA + 127) / 128);  // A→B
      encChunk(cmd, bBuf, aBuf, outBA, pointsBBuf, pointsABuf, matrixBABuf,
               (uint32_t)nB, (uint32_t)nA, 0u,
               ((NSUInteger)nB + 127) / 128);  // B→A
      // [GPU-HANG-A1 2026-08-06] 有限超时等待(commit 在 helper 内;7=可重试
      // 保持原位语义,8=永久直接透传——上层 retry 封装只重试 7)。
      const int wrc = WaitCmdWithTimeout(cmd, CmdWaitTimeoutMs());
      if (wrc != 0) return wrc;
    } else {
      // [KNIFE-C] Chunked path: one small command buffer at a time, sized
      // from the measured cost model to ~chunkTargetMs of GPU time, with a
      // thermal duty-cycle gap between chunks. Numerically identical output
      // for any chunking (row blocks are independent in the kernel).
      auto runDirection = [&](id<MTLBuffer> Q, id<MTLBuffer> Db,
                              id<MTLBuffer> O, id<MTLBuffer> Qxy,
                              id<MTLBuffer> Dbxy, id<MTLBuffer> M, uint32_t nQ,
                              uint32_t nDb) -> int {
        const NSUInteger totalGroups = ((NSUInteger)nQ + 127) / 128;
        NSUInteger tg0 = 0;
        while (tg0 < totalGroups) {
          // Re-evaluated per chunk so a thermal transition mid-pair
          // immediately tightens/relaxes the chunk size.
          const double target =
              ThermalHot() ? chunkTargetMs : ChunkTargetCoolMs();
          const double unit = gMsPerTgKCol.load();
          NSUInteger want = 8;  // first probe: 1024 rows (~few ms cool)
          if (unit > 0.0) {
            const double perTg = unit * ((double)nDb / 1024.0);
            const double ideal = target / (perTg > 1e-6 ? perTg : 1e-6);
            want = ideal < 1.0 ? 1 : (NSUInteger)ideal;
          }
          const NSUInteger groups =
              want < totalGroups - tg0 ? want : totalGroups - tg0;
          id<MTLCommandBuffer> cmd = [gQueue commandBuffer];
          encChunk(cmd, Q, Db, O, Qxy, Dbxy, M, nQ, nDb, (uint32_t)tg0,
                   groups);
          // [GPU-HANG-A1 2026-08-06] 有限超时等待(commit 在 helper 内)。
          const int wrc = WaitCmdWithTimeout(cmd, CmdWaitTimeoutMs());
          if (wrc != 0) return wrc;
          const double gpuMs = (cmd.GPUEndTime - cmd.GPUStartTime) * 1000.0;
          if (gpuMs > 0.0 && gpuMs < 10000.0) {
            const double u = gpuMs / ((double)groups * ((double)nDb / 1024.0));
            const double prev = gMsPerTgKCol.load();
            gMsPerTgKCol.store(prev <= 0.0 ? u : prev * 0.7 + u * 0.3);
          }
          const double gapPct = ThermalGapPct();
          if (gapPct > 0.0 && gpuMs > 0.0) {
            // Cap the idle gap so a pathologically slow chunk (deep
            // downclock) cannot stall the matcher for seconds.
            double gapMs = gpuMs * gapPct / 100.0;
            if (gapMs > 250.0) gapMs = 250.0;
            usleep((useconds_t)(gapMs * 1000.0));
          }
          tg0 += groups;
        }
        return 0;
      };
      int rc = runDirection(aBuf, bBuf, outAB, pointsABuf, pointsBBuf,
                            matrixABBuf, (uint32_t)nA, (uint32_t)nB);  // A→B
      if (rc == 0) {
        rc = runDirection(bBuf, aBuf, outBA, pointsBBuf, pointsABuf,
                          matrixBABuf, (uint32_t)nB, (uint32_t)nA);  // B→A
      }
      if (rc != 0) return rc;
    }

    // Mutual cross-check, emitting pairs.
    const int* mAB = (const int*)outAB.contents;
    const int* mBA = (const int*)outBA.contents;
    int n_out = 0;
    for (int i = 0; i < nA; ++i) {
      int j = mAB[i];
      if (j >= 0 && j < nB && mBA[j] == i) {
        if (out_pairs != nullptr) {
          if (n_out >= max_pairs) break;  // unreachable per contract
          out_pairs[2 * n_out] = (uint32_t)i;
          out_pairs[2 * n_out + 1] = (uint32_t)j;
        }
        ++n_out;
      }
    }
    if (out_num_matches) *out_num_matches = n_out;
    return 0;
  }
}

// ═════════════════════════ v2: fused dual-direction ═════════════════════

// Kill switches — cached per process like every other knob in this file
// (parity harnesses must therefore use one process per env config).
static bool MatchV2Enabled(void) {
  static int v = -1;
  if (v < 0) {
    const char* e = getenv("OFFICIAL_AETHER_MATCH_V2");
    v = (e && atoi(e) == 0) ? 0 : 1;  // default ON
  }
  return v != 0;
}
static bool MatchV2ForceHalf(void) {
  static int v = -1;
  if (v < 0) {
    const char* e = getenv("OFFICIAL_AETHER_MATCH_V2_HALF");
    v = (e && atoi(e) != 0) ? 1 : 0;  // default packed-u8 ABI
  }
  return v != 0;
}
// Guided calls default to the v1 two-pass path: the fused guided gate cannot
// be made bit-identical to v1's compiled gate (fast-math algebra is compile-
// context-dependent and the gate is cancellation-amplified — see header).
static bool MatchV2GuidedFused(void) {
  static int v = -1;
  if (v < 0) {
    const char* e = getenv("OFFICIAL_AETHER_MATCH_V2_GUIDED_FUSED");
    v = (e && atoi(e) != 0) ? 1 : 0;  // default OFF
  }
  return v != 0;
}

// ── pw_match_gemm2 kernel — fused dual-direction, v2 ────────────────────
// Same COLMAP-faithful selection + gates as pw_match_gemm v6 (see that
// kernel's comment); the deltas are structural: 32-wide column tiles,
// per-simdgroup accumulator staging (2 threadgroup barriers per tile instead
// of 6), row results finished in-kernel, column direction emitted as
// per-row-block partials for pw_match_merge_cols. Specialized via function
// constants: kPacked (u8-packed vs half descriptor ABI — u8→half is exact so
// both are bit-identical) and kGuideMode (0 keeps the hot loops entirely
// gate-free; 1/2 insert the v1 geometry gate before top-2 insertion in BOTH
// trackers).
static const char* kGemm2KernelSrc = R"MSL(
#include <metal_stdlib>
#include <metal_simdgroup_matrix>
using namespace metal;

constant bool kPacked    [[function_constant(0)]];
constant uint kGuideMode [[function_constant(1)]];

constant uint kD  = 128u;         // descriptor dim
constant uint kKT = 16u;          // K tiles of 8
constant uint kSG = 16u;          // simdgroups per threadgroup
constant uint kMB = kSG * 8u;     // 128 query rows per threadgroup
constant uint kBN = 32u;          // database columns per tile (v1: 16)
constant uint kNT = kBN / 8u;     // 8x8 col blocks per tile
constant uint kTGT = kSG * 32u;   // 512 threads
constant float kInvSqNorm = 1.0f / 262144.0f;  // 1/512^2 (exact power of two)

// v1's geometry gate (E/F Sampson-style band, H transfer error), open-coded
// verbatim at both tracker sites below. PARITY-CRITICAL: `nom` suffers
// near-cancellation for candidates close to the epipolar line, so single-ulp
// differences in intermediate rounding (fma contraction choices) amplify to
// ~1e-3 relative residual shifts and flip borderline gates. The gate is
// therefore kept TEXTUALLY identical to v1 — same expression trees, same
// device address spaces for points and matrix, loads inside the candidate
// loop — so the Metal compiler makes the same contraction choices it makes
// for v1 (host-verified: guided fixtures cmp byte-identical). Do NOT
// refactor into a helper taking values or hoist the loads.
// PW_GUIDE_OK expands v1's gate body: sets `geometryOK` from (Q, DPT, M).
#define PW_GUIDE_OK(Q, DPT, M)                                            \
  bool geometryOK = true;                                                 \
  if (kGuideMode == 1u) {                                                 \
    const float2 q = (Q);                                                 \
    const float2 d = (DPT);                                               \
    const float3 p1 = float3(q, 1.0f);                                    \
    const float3 p2 = float3(d, 1.0f);                                    \
    const float3 line2 = float3(                                          \
        M[0] * p1.x + M[1] * p1.y + M[2],                                 \
        M[3] * p1.x + M[4] * p1.y + M[5],                                 \
        M[6] * p1.x + M[7] * p1.y + M[8]);                                \
    const float3 line1 = float3(                                          \
        M[0] * p2.x + M[3] * p2.y + M[6],                                 \
        M[1] * p2.x + M[4] * p2.y + M[7],                                 \
        M[2] * p2.x + M[5] * p2.y + M[8]);                                \
    const float nom = dot(p2, line2);                                     \
    const float denom = dot(line2.xy, line2.xy) +                         \
                        dot(line1.xy, line1.xy);                          \
    geometryOK = denom > 1e-12f &&                                        \
                 nom * nom <= maxResidual * denom;                        \
  } else if (kGuideMode == 2u) {                                          \
    const float2 q = (Q);                                                 \
    const float2 d = (DPT);                                               \
    const float hx = M[0] * q.x + M[1] * q.y + M[2];                      \
    const float hy = M[3] * q.x + M[4] * q.y + M[5];                      \
    const float hz = M[6] * q.x + M[7] * q.y + M[8];                      \
    if (abs(hz) <= 1e-8f) {                                               \
      geometryOK = false;                                                 \
    } else {                                                              \
      const float2 delta = float2(hx / hz, hy / hz) - d;                  \
      geometryOK = dot(delta, delta) <= maxResidual;                      \
    }                                                                     \
  }

kernel void pw_match_gemm2(
    device const half*  Ah          [[buffer(0)]],
    device const half*  Bh          [[buffer(1)]],
    device int*         outAB       [[buffer(2)]],
    constant uint&      numA        [[buffer(3)]],
    constant uint&      numB        [[buffer(4)]],
    constant float&     maxRatio    [[buffer(5)]],
    constant float&     maxDistance [[buffer(6)]],
    constant uint&      rowBase     [[buffer(7)]],
    device float*       colBestOut  [[buffer(8)]],
    device float*       colSecondOut[[buffer(9)]],
    device int*         colIdxOut   [[buffer(10)]],
    constant uint&      colStride   [[buffer(11)]],
    device const uint*  Ap          [[buffer(12)]],
    device const uint*  Bp          [[buffer(13)]],
    device const float2* pointsA    [[buffer(14)]],
    device const float2* pointsB    [[buffer(15)]],
    device const float* matAB       [[buffer(16)]],
    device const float* matBA       [[buffer(17)]],
    constant float&     maxResidual [[buffer(18)]],
    uint tgid [[threadgroup_position_in_grid]],
    uint lid  [[thread_index_in_threadgroup]],
    uint sgid [[simdgroup_index_in_threadgroup]],
    uint lane [[thread_index_in_simdgroup]]) {
  // Threadgroup budget: 8 KB + 16 KB + 3*2 KB = 30 KB (< 32 KB limit).
  threadgroup half4 Bsh4[kBN * kD / 4u];       //  8 KB staged B tile
  threadgroup float accSG[kSG * 8u * kBN];     // 16 KB per-SG 8 x kBN scratch
  threadgroup float cpBest[kSG * kBN];         //  2 KB per-SG column partials
  threadgroup float cpSecond[kSG * kBN];       //  2 KB
  threadgroup int   cpIdx[kSG * kBN];          //  2 KB
  threadgroup half* Bsh = (threadgroup half*)Bsh4;

  // rowBase: first row-block of this chunk (KNIFE-C). Row blocks are
  // independent and column partials are indexed by the ABSOLUTE row-block,
  // so per-row and per-column results are identical for any chunking.
  const uint rb   = rowBase + tgid;   // absolute row-block index
  const uint row0 = rb * kMB;
  if (row0 >= numA) { return; }  // dispatch-overshoot safety (uniform)

  const uint lrow = lane >> 2u;                // 0..7: row within simdgroup
  const uint lcg  = lane & 3u;                 // 0..3: column group
  const uint gRow = row0 + sgid * 8u + lrow;   // global (padded) A row

  // Load this simdgroup's 8 query rows into registers (16 x 8x8 half frags).
  const uint aRow0 = row0 + sgid * 8u;
  simdgroup_matrix<half, 8, 8> aFrag[kKT];
  if (!kPacked) {
    for (uint k = 0; k < kKT; ++k) {
      simdgroup_load(aFrag[k], Ah + aRow0 * kD + k * 8u, kD, ulong2(0, 0));
    }
  } else {
    // Packed A: unpack this SG's 8 rows (256 uints) into a Bsh quadrant, in
    // 4 waves of 4 simdgroups (Bsh = 4096 halfs = exactly 4 x (8*128)).
    const uint wave = sgid >> 2u, slot = sgid & 3u;
    threadgroup half* scratch = Bsh + slot * (8u * kD);
    for (uint w = 0; w < 4u; ++w) {
      if (w == wave) {
        device const uint* src = Ap + (aRow0 * kD) / 4u;
        threadgroup half4* s4 = (threadgroup half4*)scratch;
        for (uint e = lane; e < 256u; e += 32u) {
          const uint u = src[e];
          s4[e] = half4(half(u & 0xFFu), half((u >> 8u) & 0xFFu),
                        half((u >> 16u) & 0xFFu), half(u >> 24u));
        }
        simdgroup_barrier(mem_flags::mem_threadgroup);
        for (uint k = 0; k < kKT; ++k) {
          simdgroup_load(aFrag[k], scratch + k * 8u, kD, ulong2(0, 0));
        }
      }
      threadgroup_barrier(mem_flags::mem_threadgroup);
    }
  }

  // Running A->B top-2 for row `gRow`, held by the lcg==0 lane.
  float rowBestD = 0.0f, rowSecondD = 0.0f;
  int   rowBestI = -1;

  for (uint col0 = 0; col0 < numB; col0 += kBN) {
    // Cooperative contiguous B-tile load (host pads B to a 128-multiple,
    // zero-filled, so the tile read never goes OOB).
    if (!kPacked) {
      device const half4* src4 = (device const half4*)(Bh + col0 * kD);
      for (uint e = lid; e < kBN * kD / 4u; e += kTGT) { Bsh4[e] = src4[e]; }
    } else {
      device const uint* src = Bp + (col0 * kD) / 4u;
      for (uint e = lid; e < kBN * kD / 4u; e += kTGT) {
        const uint u = src[e];
        Bsh4[e] = half4(half(u & 0xFFu), half((u >> 8u) & 0xFFu),
                        half((u >> 16u) & 0xFFu), half(u >> 24u));
      }
    }
    // Barrier (A): Bsh ready; also fences last tile's cp readers vs the
    // cp writes below (merge threads re-join here).
    threadgroup_barrier(mem_flags::mem_threadgroup);

    // GEMM: this SG's 8 rows x the 32-column tile, staged per-SG (no
    // cross-SG sharing -> simdgroup_barrier only).
    for (uint nt = 0; nt < kNT; ++nt) {
      simdgroup_matrix<float, 8, 8> c =
          make_filled_simdgroup_matrix<float, 8, 8>(0.0f);
      for (uint k = 0; k < kKT; ++k) {
        simdgroup_matrix<half, 8, 8> bF;
        simdgroup_load(bF, Bsh + (nt * 8u) * kD + k * 8u, kD, ulong2(0, 0),
                       true);
        simdgroup_multiply_accumulate(c, aFrag[k], bF, c);
      }
      simdgroup_store(c, accSG + sgid * (8u * kBN) + nt * 8u, kBN,
                      ulong2(0, 0));
    }
    simdgroup_barrier(mem_flags::mem_threadgroup);

    // ── Row direction (A->B): lane lcg scans 8 consecutive columns
    //    ascending with strict `>` (v1 semantics), then a 2-stage lcg
    //    butterfly (ours-on-tie, ascending groups) reduces to lcg==0.
    {
      threadgroup const float* accRow =
          accSG + sgid * (8u * kBN) + lrow * kBN;
      const uint per = kBN / 4u;
      float pb = 0.0f, ps = 0.0f;
      int pbi = -1;
      for (uint t = 0; t < per; ++t) {
        const uint cLoc = lcg * per + t;
        if (kGuideMode != 0u) {
          // Row gate: q = pointsA[query row], d = pointsB[candidate col],
          // M = matrixAB — v1 pass-1 verbatim.
          PW_GUIDE_OK(pointsA[gRow], pointsB[col0 + cLoc], matAB)
          if (!geometryOK) continue;
        }
        const float d = accRow[cLoc];
        if (d > pb) { ps = pb; pb = d; pbi = (int)(col0 + cLoc); }
        else if (d > ps) { ps = d; }
      }
      for (ushort off = 1; off <= 2; off <<= 1) {
        const float ob = simd_shuffle_xor(pb, off);
        const float os = simd_shuffle_xor(ps, off);
        const int   oi = simd_shuffle_xor(pbi, off);
        if (ob > pb) { ps = max(os, pb); pb = ob; pbi = oi; }
        else         { ps = max(ps, ob); }
      }
      if (lcg == 0u) {
        if (pb > rowBestD) {
          rowSecondD = max(rowBestD, ps); rowBestD = pb; rowBestI = pbi;
        } else {
          rowSecondD = max(rowSecondD, pb);
        }
      }
    }

    // ── Column direction (B->A): each lane owns one column of the tile
    //    (kBN == simd width == 32) and scans this SG's 8 rows ascending with
    //    strict `>` — literally the standalone B->A per-query scan
    //    restricted to an 8-row slice.
    {
      const uint cc = lane;  // requires kBN == 32
      float cb = 0.0f, cs = 0.0f;
      int ci = -1;
      threadgroup const float* accCol = accSG + sgid * (8u * kBN) + cc;
      for (uint r = 0; r < 8u; ++r) {
        if (kGuideMode != 0u) {
          // Column gate: q = pointsB[query col], d = pointsA[candidate row],
          // M = matrixBA — exactly v1's pass-2 with its swapped arguments.
          PW_GUIDE_OK(pointsB[col0 + cc], pointsA[row0 + sgid * 8u + r],
                      matBA)
          if (!geometryOK) continue;
        }
        const float d = accCol[r * kBN];
        if (d > cb) { cs = cb; cb = d; ci = (int)(row0 + sgid * 8u + r); }
        else if (d > cs) { cs = d; }
      }
      cpBest[sgid * kBN + cc] = cb;
      cpSecond[sgid * kBN + cc] = cs;
      cpIdx[sgid * kBN + cc] = ci;
    }

    // Barrier (B): cp complete from all SGs; all Bsh readers done.
    threadgroup_barrier(mem_flags::mem_threadgroup);

    // Cross-SG merge, ascending sgid == ascending global row (tie-break
    // preserved). Runs on 32 threads and overlaps with the other 480
    // threads' next-tile Bsh load (they only sync at barrier A). A parallel
    // shuffle-tree merge was probed and measured SLOWER — the serial form
    // hides behind the other threads' progress. Padded columns of the last
    // tile write harmless partials (stride covers them).
    if (lid < kBN) {
      float b = cpBest[lid], s = cpSecond[lid];
      int bi = cpIdx[lid];
      for (uint sg = 1u; sg < kSG; ++sg) {
        const float ob = cpBest[sg * kBN + lid];
        const float os = cpSecond[sg * kBN + lid];
        const int   oi = cpIdx[sg * kBN + lid];
        if (ob > b) { s = max(b, os); b = ob; bi = oi; }
        else        { s = max(s, ob); }
      }
      const uint j = col0 + lid;
      colBestOut[rb * colStride + j] = b;
      colSecondOut[rb * colStride + j] = s;
      colIdxOut[rb * colStride + j] = bi;
    }
  }

  // Final A->B gates — identical expressions to pw_match_gemm v6 (angular
  // acos domain plain; normalized-L2 + 131072 sentinel guided). Padded rows
  // also write (outAB is over-allocated to the padded row count; the CPU
  // cross-check reads only the first numA entries).
  if (lcg == 0u) {
    if (rowBestI < 0) {
      outAB[gRow] = -1;
    } else {
      float bd;
      float sd;
      if (kGuideMode == 0u) {
        bd = acos(min(rowBestD * kInvSqNorm, 1.0f));
        sd = acos(min(rowSecondD * kInvSqNorm, 1.0f));
      } else {
        const float secondDot = max(rowSecondD, 131072.0f);
        bd = sqrt(max(0.0f, 2.0f - 2.0f * rowBestD * kInvSqNorm));
        sd = sqrt(max(0.0f, 2.0f - 2.0f * secondDot * kInvSqNorm));
      }
      const bool keep = (bd <= maxDistance) && (bd < maxRatio * sd);
      outAB[gRow] = keep ? rowBestI : -1;
    }
  }
}

// Reduces the per-row-block column partials over row-blocks in ascending
// order (== ascending global A row), then applies the SAME final gates as
// the standalone B->A pass (v1 second run). One thread per B column.
kernel void pw_match_merge_cols(
    device const float* colBest   [[buffer(0)]],
    device const float* colSecond [[buffer(1)]],
    device const int*   colIdx    [[buffer(2)]],
    device int*         outBA     [[buffer(3)]],
    constant uint&      numB      [[buffer(4)]],
    constant uint&      colStride [[buffer(5)]],
    constant uint&      numBlocks [[buffer(6)]],
    constant float&     maxRatio  [[buffer(7)]],
    constant float&     maxDistance [[buffer(8)]],
    constant uint&      guideMode [[buffer(9)]],
    uint gid [[thread_position_in_grid]]) {
  if (gid >= numB) return;
  float b = 0.0f, s = 0.0f;
  int bi = -1;
  for (uint rbk = 0; rbk < numBlocks; ++rbk) {
    const uint o = rbk * colStride + gid;
    const float ob = colBest[o];
    const float os = colSecond[o];
    const int   oi = colIdx[o];
    if (ob > b) { s = max(b, os); b = ob; bi = oi; }
    else        { s = max(s, ob); }
  }
  if (bi < 0) { outBA[gid] = -1; return; }
  float bd;
  float sd;
  if (guideMode == 0u) {
    bd = acos(min(b * kInvSqNorm, 1.0f));
    sd = acos(min(s * kInvSqNorm, 1.0f));
  } else {
    const float secondDot = max(s, 131072.0f);
    bd = sqrt(max(0.0f, 2.0f - 2.0f * b * kInvSqNorm));
    sd = sqrt(max(0.0f, 2.0f - 2.0f * secondDot * kInvSqNorm));
  }
  const bool keep = (bd <= maxDistance) && (bd < maxRatio * sd);
  outBA[gid] = keep ? bi : -1;
}
)MSL";

// Lazily-built shared Metal context (v2). Pipelines are specialized per
// (packed, guideMode) on first use; the library compiles once.
static id<MTLDevice> gV2Dev;
static id<MTLCommandQueue> gV2Queue;
static id<MTLLibrary> gV2Lib;
static id<MTLComputePipelineState> gV2Fused[2][3];  // [packed][guideMode]
static id<MTLComputePipelineState> gV2Merge;
static id<MTLBuffer> gV2Dummy;  // 16-byte filler for unused point bindings

static BOOL ensureMetalV2(void) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    gV2Dev = MTLCreateSystemDefaultDevice();
    if (!gV2Dev) return;
    gV2Queue = [gV2Dev newCommandQueue];
    NSError* e = nil;
    gV2Lib = [gV2Dev
        newLibraryWithSource:[NSString stringWithUTF8String:kGemm2KernelSrc]
                     options:nil  // same defaults as v1 (fast-math on)
                       error:&e];
    if (!gV2Lib) {
      NSLog(@"[pwofficial_gpu_match] v2 kernel compile failed: %@", e);
      return;
    }
    id<MTLFunction> fm = [gV2Lib newFunctionWithName:@"pw_match_merge_cols"];
    if (fm) gV2Merge = [gV2Dev newComputePipelineStateWithFunction:fm error:&e];
    if (!gV2Merge) {
      NSLog(@"[pwofficial_gpu_match] v2 merge pipeline failed: %@", e);
      gV2Lib = nil;
      return;
    }
    gV2Dummy = [gV2Dev newBufferWithLength:16
                                   options:MTLResourceStorageModeShared];
  });
  return gV2Lib != nil && gV2Merge != nil && gV2Dummy != nil;
}

// Callers hold the global match mutex, so plain lazy init is safe.
static id<MTLComputePipelineState> v2FusedPipeline(bool packed,
                                                   uint32_t guideMode) {
  const int p = packed ? 1 : 0;
  if (gV2Fused[p][guideMode]) return gV2Fused[p][guideMode];
  MTLFunctionConstantValues* fc = [MTLFunctionConstantValues new];
  bool pv = packed;
  [fc setConstantValue:&pv type:MTLDataTypeBool atIndex:0];
  [fc setConstantValue:&guideMode type:MTLDataTypeUInt atIndex:1];
  NSError* e = nil;
  id<MTLFunction> f = [gV2Lib newFunctionWithName:@"pw_match_gemm2"
                                   constantValues:fc
                                            error:&e];
  id<MTLComputePipelineState> pso =
      f ? [gV2Dev newComputePipelineStateWithFunction:f error:&e] : nil;
  if (!pso) {
    NSLog(@"[pwofficial_gpu_match] v2 pipeline (packed=%d guide=%u) "
          @"failed: %@", p, guideMode, e);
    return nil;
  }
  if (pso.maxTotalThreadsPerThreadgroup < 512) {
    // Register pressure sank below the 512-thread dispatch shape — refuse
    // the specialization (caller falls out with rc=2; the v1 kill switch
    // remains available).
    NSLog(@"[pwofficial_gpu_match] v2 pipeline (packed=%d guide=%u) "
          @"maxThreads=%lu < 512 — refusing", p, guideMode,
          (unsigned long)pso.maxTotalThreadsPerThreadgroup);
    return nil;
  }
  gV2Fused[p][guideMode] = pso;
  return pso;
}

// Grow-only buffer pool (persistent across calls: freshly allocated
// MTLBuffers pay a first-GPU-touch mapping cost, ~1 ms/pair measured, and
// the chunked path shares the column-partial buffers across chunks).
// Guarded by the global match mutex.
static id<MTLBuffer> gV2A, gV2B, gV2OutAB, gV2OutBA, gV2PtsA, gV2PtsB;
static id<MTLBuffer> gV2ColBest, gV2ColSecond, gV2ColIdx;
static id<MTLBuffer> gV2MatAB, gV2MatBA;  // 9 floats each, device-space
static NSUInteger gV2ACap, gV2BCap, gV2OutACap, gV2OutBCap, gV2PtsACap,
    gV2PtsBCap, gV2ColCap, gV2MatABCap, gV2MatBACap;

static id<MTLBuffer> v2PoolBuf(id<MTLBuffer> __strong* slot, NSUInteger* cap,
                               NSUInteger need, MTLResourceOptions opt) {
  if (*cap < need || !*slot) {
    *slot = [gV2Dev newBufferWithLength:need options:opt];
    *cap = *slot ? need : 0;
  }
  return *slot;
}

// ── Descriptor Residency V1 (default-off, exact raw-u8 reuse) ───────────
// The shared policy owns identity/LRU/byte accounting. This Metal TU owns only
// backend handles. The matcher kernel and output path below are unchanged.
using aether::sfm::DescriptorFormatV1;
using aether::sfm::DescriptorResidencyKeyHashV1;
using aether::sfm::DescriptorResidencyKeyV1;
using aether::sfm::DescriptorResidencyMetadataV1;
using aether::sfm::DescriptorResidencyPolicyV1;

static bool DescriptorResidencyEnabled(void) {
  static const bool enabled = [] {
    const char* value = std::getenv("OFFICIAL_AETHER_DESCRIPTOR_RESIDENCY_V1");
    return value && value[0] == '1' && value[1] == '\0';
  }();
  return enabled;
}

static uint64_t DescriptorResidencyBudgetBytes(void) {
  static const uint64_t budget = [] {
    constexpr uint64_t kDefault = UINT64_C(48) * 1024 * 1024;
    const char* value =
        std::getenv("OFFICIAL_AETHER_DESCRIPTOR_RESIDENCY_BYTES");
    if (!value || !value[0]) return kDefault;
    char* end = nullptr;
    const unsigned long long parsed = std::strtoull(value, &end, 10);
    if (!end || *end != '\0') return kDefault;
    return static_cast<uint64_t>(parsed);
  }();
  return budget;
}

struct DescriptorResidencyMetalSessionV1 {
  explicit DescriptorResidencyMetalSessionV1(uint64_t budget)
      : policy(budget) {}

  DescriptorResidencyPolicyV1 policy;
  std::unordered_map<DescriptorResidencyKeyV1, id<MTLBuffer>,
                     DescriptorResidencyKeyHashV1>
      buffers;
  uint64_t upload_bytes = 0;
  uint64_t allocation_failures = 0;
  uint64_t device_resets = 0;
};

static std::unordered_map<uint64_t,
                          std::unique_ptr<DescriptorResidencyMetalSessionV1>>
    gDescriptorResidencySessions;

static DescriptorResidencyMetalSessionV1* DescriptorResidencySession(
    uint64_t nonce) {
  auto found = gDescriptorResidencySessions.find(nonce);
  if (found != gDescriptorResidencySessions.end()) return found->second.get();
  auto inserted = gDescriptorResidencySessions.emplace(
      nonce, std::make_unique<DescriptorResidencyMetalSessionV1>(
                 DescriptorResidencyBudgetBytes()));
  return inserted.first->second.get();
}

static void EraseResidentBuffers(
    DescriptorResidencyMetalSessionV1* session,
    const std::vector<DescriptorResidencyKeyV1>& keys) {
  if (!session) return;
  for (const auto& key : keys) session->buffers.erase(key);
}

static id<MTLBuffer> v2ResidentRawU8Buffer(
    uint64_t session_nonce, uint32_t frame_ordinal, uint32_t generation,
    const uint8_t* descriptors, uint32_t descriptor_count,
    NSUInteger padded_rows) {
  if (!DescriptorResidencyEnabled() || session_nonce == 0 || !descriptors ||
      descriptor_count == 0 || padded_rows < descriptor_count) {
    return nil;
  }
  DescriptorResidencyMetalSessionV1* session =
      DescriptorResidencySession(session_nonce);
  const DescriptorResidencyKeyV1 key{session_nonce, frame_ordinal, generation};
  const uint64_t bytes = static_cast<uint64_t>(padded_rows) * 128;
  const DescriptorResidencyMetadataV1 metadata{
      descriptor_count, DescriptorFormatV1::kRawU8, bytes};
  auto access = session->policy.Access(key, metadata);
  EraseResidentBuffers(session, access.evicted);
  if (access.hit) {
    const auto found = session->buffers.find(key);
    if (found != session->buffers.end() && found->second) return found->second;
    // Policy/backend divergence is fail-safe: forget this frame and rebuild it
    // as an ordinary miss. This branch is not expected in a healthy process.
    EraseResidentBuffers(
        session,
        session->policy.InvalidateFrame(session_nonce, frame_ordinal));
    access = session->policy.Access(key, metadata);
    EraseResidentBuffers(session, access.evicted);
  }
  if (!access.admitted) return nil;

  id<MTLBuffer> buffer =
      [gV2Dev newBufferWithLength:static_cast<NSUInteger>(bytes)
                          options:MTLResourceStorageModeShared];
  if (!buffer) {
    ++session->allocation_failures;
    EraseResidentBuffers(
        session,
        session->policy.InvalidateFrame(session_nonce, frame_ordinal));
    return nil;
  }
  const size_t live_bytes = static_cast<size_t>(descriptor_count) * 128;
  std::memcpy(buffer.contents, descriptors, live_bytes);
  std::memset(static_cast<uint8_t*>(buffer.contents) + live_bytes, 0,
              static_cast<size_t>(bytes) - live_bytes);
  session->upload_bytes += bytes;
  session->buffers[key] = buffer;
  return buffer;
}

static void ClearAllDescriptorResidencyForDeviceError(void) {
  for (auto& [nonce, session] : gDescriptorResidencySessions) {
    (void)nonce;
    session->policy.ClearAll();
    session->buffers.clear();
    ++session->device_resets;
  }
}

// v2 fused implementation. Same argument contract and rc semantics as
// matchPairsImpl: 1 = bad args, 2 = Metal unavailable/pipeline refused,
// 5 = descriptor buffer alloc failed, 6 = aux buffer alloc failed,
// 7 = GPU command buffer error (rate-limited NSLog + stashLastError).
static int matchPairsImplV2(const uint8_t* dA, int nA, const float* xyA,
                            const uint8_t* dB, int nB, const float* xyB,
                            double max_ratio, const float* matrixAB,
                            const float* matrixBA, uint32_t guideMode,
                            float maxResidual, uint32_t* out_pairs,
                            int max_pairs, int* out_num_matches,
                            uint64_t residency_session_nonce = 0,
                            uint32_t residency_frame_a = 0,
                            uint32_t residency_generation_a = 0,
                            uint32_t residency_frame_b = 0,
                            uint32_t residency_generation_b = 0) {
  @autoreleasepool {
    if (out_num_matches) *out_num_matches = 0;
    if (!dA || !dB || nA <= 0 || nB <= 0) return 1;
    if (out_pairs != nullptr && max_pairs <= 0) return 1;
    if (guideMode > 2u) return 1;
    if (guideMode != 0u &&
        (!xyA || !xyB || !matrixAB || !matrixBA || maxResidual <= 0.0f)) {
      return 1;
    }
    if (!ensureMetalV2()) return 2;
    const bool packed = !MatchV2ForceHalf();
    id<MTLComputePipelineState> fused = v2FusedPipeline(packed, guideMode);
    if (!fused) return 2;
    const int D = 128;
    // Host-padded buffers: multiple of kMB(128) rows, zero-filled — the
    // guard-free kernel relies on this (see header invariant).
    const NSUInteger nApad = (((NSUInteger)nA + 127) / 128) * 128;
    const NSUInteger nBpad = (((NSUInteger)nB + 127) / 128) * 128;
    id<MTLBuffer> aBuf, bBuf;
    if (!packed) {
      aBuf = v2PoolBuf(&gV2A, &gV2ACap, nApad * D * sizeof(__fp16),
                       MTLResourceStorageModeShared);
      bBuf = v2PoolBuf(&gV2B, &gV2BCap, nBpad * D * sizeof(__fp16),
                       MTLResourceStorageModeShared);
      if (!aBuf || !bBuf) return 5;
      __fp16* af = (__fp16*)aBuf.contents;
      for (NSUInteger i = 0; i < (NSUInteger)nA * D; ++i) af[i] = (__fp16)dA[i];
      for (NSUInteger i = (NSUInteger)nA * D; i < nApad * D; ++i) af[i] = 0;
      __fp16* bf = (__fp16*)bBuf.contents;
      for (NSUInteger i = 0; i < (NSUInteger)nB * D; ++i) bf[i] = (__fp16)dB[i];
      for (NSUInteger i = (NSUInteger)nB * D; i < nBpad * D; ++i) bf[i] = 0;
    } else {
      // Packed ABI: raw u8 bytes ARE the packed little-endian uint32 layout
      // (matches the future WGSL dot4U8Packed layout); u8→half unpack
      // in-kernel is exact, so bit-identical to the half path.
      aBuf = v2ResidentRawU8Buffer(
          residency_session_nonce, residency_frame_a,
          residency_generation_a, dA, static_cast<uint32_t>(nA), nApad);
      bBuf = v2ResidentRawU8Buffer(
          residency_session_nonce, residency_frame_b,
          residency_generation_b, dB, static_cast<uint32_t>(nB), nBpad);
      const bool aResident = aBuf != nil;
      const bool bResident = bBuf != nil;
      if (!aBuf) {
        aBuf = v2PoolBuf(&gV2A, &gV2ACap, nApad * D,
                         MTLResourceStorageModeShared);
      }
      if (!bBuf) {
        bBuf = v2PoolBuf(&gV2B, &gV2BCap, nBpad * D,
                         MTLResourceStorageModeShared);
      }
      if (!aBuf || !bBuf) return 5;
      if (!aResident) {
        memcpy(aBuf.contents, dA, (size_t)nA * D);
        memset((uint8_t*)aBuf.contents + (size_t)nA * D, 0,
               (size_t)(nApad - (NSUInteger)nA) * D);
      }
      if (!bResident) {
        memcpy(bBuf.contents, dB, (size_t)nB * D);
        memset((uint8_t*)bBuf.contents + (size_t)nB * D, 0,
               (size_t)(nBpad - (NSUInteger)nB) * D);
      }
    }
    // outAB over-allocated to the padded row count (guard-free kernel also
    // writes padded rows; the cross-check below reads only the first nA).
    id<MTLBuffer> outAB = v2PoolBuf(&gV2OutAB, &gV2OutACap,
                                    nApad * sizeof(int),
                                    MTLResourceStorageModeShared);
    id<MTLBuffer> outBA = v2PoolBuf(&gV2OutBA, &gV2OutBCap,
                                    (NSUInteger)nB * sizeof(int),
                                    MTLResourceStorageModeShared);
    if (!outAB || !outBA) return 6;
    id<MTLBuffer> ptsA = gV2Dummy;
    id<MTLBuffer> ptsB = gV2Dummy;
    if (guideMode != 0u) {
      // Keypoint buffers padded like the descriptors (zero-filled): padded
      // rows/cols read in-bounds garbage-free points whose gate verdict is
      // irrelevant (their dot==0 candidates are uninsertable).
      ptsA = v2PoolBuf(&gV2PtsA, &gV2PtsACap, nApad * 2 * sizeof(float),
                       MTLResourceStorageModeShared);
      ptsB = v2PoolBuf(&gV2PtsB, &gV2PtsBCap, nBpad * 2 * sizeof(float),
                       MTLResourceStorageModeShared);
      if (!ptsA || !ptsB) return 6;
      memcpy(ptsA.contents, xyA, (size_t)nA * 2 * sizeof(float));
      memset((uint8_t*)ptsA.contents + (size_t)nA * 2 * sizeof(float), 0,
             (size_t)(nApad - (NSUInteger)nA) * 2 * sizeof(float));
      memcpy(ptsB.contents, xyB, (size_t)nB * 2 * sizeof(float));
      memset((uint8_t*)ptsB.contents + (size_t)nB * 2 * sizeof(float), 0,
             (size_t)(nBpad - (NSUInteger)nB) * 2 * sizeof(float));
    }
    const NSUInteger numBlocksA = nApad / 128;
    const NSUInteger colBytes = numBlocksA * nBpad * 4;
    if (gV2ColCap < colBytes) {
      gV2ColBest = [gV2Dev newBufferWithLength:colBytes
                                       options:MTLResourceStorageModePrivate];
      gV2ColSecond = [gV2Dev newBufferWithLength:colBytes
                                         options:MTLResourceStorageModePrivate];
      gV2ColIdx = [gV2Dev newBufferWithLength:colBytes
                                      options:MTLResourceStorageModePrivate];
      gV2ColCap = (gV2ColBest && gV2ColSecond && gV2ColIdx) ? colBytes : 0;
      if (gV2ColCap == 0) return 6;
    }
    static const float kIdentity[9] = {1.0f, 0.0f, 0.0f, 0.0f, 1.0f,
                                       0.0f, 0.0f, 0.0f, 1.0f};
    const float* matAtoB = guideMode == 0u ? kIdentity : matrixAB;
    const float* matBtoA = guideMode == 0u ? kIdentity : matrixBA;
    // Device-space matrix buffers (NOT setBytes/constant space): the gate is
    // codegen-sensitive (see kernel comment) and v1 reads its matrix from a
    // device buffer, so v2 must too.
    id<MTLBuffer> matABBuf = v2PoolBuf(&gV2MatAB, &gV2MatABCap,
                                       9 * sizeof(float),
                                       MTLResourceStorageModeShared);
    id<MTLBuffer> matBABuf = v2PoolBuf(&gV2MatBA, &gV2MatBACap,
                                       9 * sizeof(float),
                                       MTLResourceStorageModeShared);
    if (!matABBuf || !matBABuf) return 6;
    memcpy(matABBuf.contents, matAtoB, 9 * sizeof(float));
    memcpy(matBABuf.contents, matBtoA, 9 * sizeof(float));
    float maxRatio = (float)max_ratio;
    if (maxRatio <= 0.0f) maxRatio = 0.8f;
    float maxDistance = 0.7f;  // colmap::SiftMatchingOptions::max_distance default
    const uint32_t numAU = (uint32_t)nA, numBU = (uint32_t)nB;
    const uint32_t colStride = (uint32_t)nBpad;
    const uint32_t numBlocksU = (uint32_t)numBlocksA;

    auto encFused = [&](id<MTLCommandBuffer> cmd, uint32_t rowBase,
                        NSUInteger groups) {
      id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
      [enc setComputePipelineState:fused];
      [enc setBuffer:aBuf offset:0 atIndex:0];
      [enc setBuffer:bBuf offset:0 atIndex:1];
      [enc setBuffer:outAB offset:0 atIndex:2];
      [enc setBytes:&numAU length:4 atIndex:3];
      [enc setBytes:&numBU length:4 atIndex:4];
      [enc setBytes:&maxRatio length:4 atIndex:5];
      [enc setBytes:&maxDistance length:4 atIndex:6];
      [enc setBytes:&rowBase length:4 atIndex:7];
      [enc setBuffer:gV2ColBest offset:0 atIndex:8];
      [enc setBuffer:gV2ColSecond offset:0 atIndex:9];
      [enc setBuffer:gV2ColIdx offset:0 atIndex:10];
      [enc setBytes:&colStride length:4 atIndex:11];
      [enc setBuffer:aBuf offset:0 atIndex:12];  // packed alias (untyped)
      [enc setBuffer:bBuf offset:0 atIndex:13];
      [enc setBuffer:ptsA offset:0 atIndex:14];
      [enc setBuffer:ptsB offset:0 atIndex:15];
      [enc setBuffer:matABBuf offset:0 atIndex:16];
      [enc setBuffer:matBABuf offset:0 atIndex:17];
      [enc setBytes:&maxResidual length:4 atIndex:18];
      [enc dispatchThreadgroups:MTLSizeMake(groups, 1, 1)
          threadsPerThreadgroup:MTLSizeMake(512, 1, 1)];
      [enc endEncoding];
    };
    auto encMerge = [&](id<MTLCommandBuffer> cmd) {
      id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
      [enc setComputePipelineState:gV2Merge];
      [enc setBuffer:gV2ColBest offset:0 atIndex:0];
      [enc setBuffer:gV2ColSecond offset:0 atIndex:1];
      [enc setBuffer:gV2ColIdx offset:0 atIndex:2];
      [enc setBuffer:outBA offset:0 atIndex:3];
      [enc setBytes:&numBU length:4 atIndex:4];
      [enc setBytes:&colStride length:4 atIndex:5];
      [enc setBytes:&numBlocksU length:4 atIndex:6];
      [enc setBytes:&maxRatio length:4 atIndex:7];
      [enc setBytes:&maxDistance length:4 atIndex:8];
      [enc setBytes:&guideMode length:4 atIndex:9];
      [enc dispatchThreadgroups:MTLSizeMake(((NSUInteger)nB + 255) / 256, 1, 1)
          threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
      [enc endEncoding];
    };

    const double chunkTargetMs = ChunkTargetMs();
    if (chunkTargetMs <= 0.0) {
      // Monolithic: the whole fused pass + merge in one command buffer.
      id<MTLCommandBuffer> cmd = [gV2Queue commandBuffer];
      encFused(cmd, 0u, numBlocksA);
      encMerge(cmd);
      // [GPU-HANG-A1 2026-08-06] 有限超时等待(commit 在 helper 内;7=可重试
      // 保持原位语义,8=永久直接透传)。
      const int wrc = WaitCmdWithTimeout(cmd, CmdWaitTimeoutMs());
      if (wrc != 0) return wrc;
    } else {
      // [KNIFE-C] Chunked: same sizing loop and thermal duty-cycle as v1,
      // over the SINGLE fused pass (both directions at once). The merge
      // kernel runs after the last chunk. Bit-identical for any chunking.
      const NSUInteger totalGroups = numBlocksA;
      NSUInteger tg0 = 0;
      while (tg0 < totalGroups) {
        const double target =
            ThermalHot() ? chunkTargetMs : ChunkTargetCoolMs();
        const double unit = gMsPerTgKColV2.load();
        NSUInteger want = 8;  // first probe: 1024 rows (~few ms cool)
        if (unit > 0.0) {
          const double perTg = unit * ((double)numBU / 1024.0);
          const double ideal = target / (perTg > 1e-6 ? perTg : 1e-6);
          want = ideal < 1.0 ? 1 : (NSUInteger)ideal;
        }
        const NSUInteger groups =
            want < totalGroups - tg0 ? want : totalGroups - tg0;
        id<MTLCommandBuffer> cmd = [gV2Queue commandBuffer];
        encFused(cmd, (uint32_t)tg0, groups);
        // [GPU-HANG-A1 2026-08-06] 有限超时等待(commit 在 helper 内)。
        const int wrc = WaitCmdWithTimeout(cmd, CmdWaitTimeoutMs());
        if (wrc != 0) return wrc;
        const double gpuMs = (cmd.GPUEndTime - cmd.GPUStartTime) * 1000.0;
        if (gpuMs > 0.0 && gpuMs < 10000.0) {
          const double u = gpuMs / ((double)groups * ((double)numBU / 1024.0));
          const double prev = gMsPerTgKColV2.load();
          gMsPerTgKColV2.store(prev <= 0.0 ? u : prev * 0.7 + u * 0.3);
        }
        const double gapPct = ThermalGapPct();
        if (gapPct > 0.0 && gpuMs > 0.0) {
          double gapMs = gpuMs * gapPct / 100.0;
          if (gapMs > 250.0) gapMs = 250.0;
          usleep((useconds_t)(gapMs * 1000.0));
        }
        tg0 += groups;
      }
      id<MTLCommandBuffer> cmd = [gV2Queue commandBuffer];
      encMerge(cmd);
      // [GPU-HANG-A1 2026-08-06] 有限超时等待(commit 在 helper 内;7=可重试
      // 保持原位语义,8=永久直接透传)。
      const int wrc = WaitCmdWithTimeout(cmd, CmdWaitTimeoutMs());
      if (wrc != 0) return wrc;
    }

    // Mutual cross-check, emitting pairs (identical loop to v1).
    const int* mAB = (const int*)outAB.contents;
    const int* mBA = (const int*)outBA.contents;
    int n_out = 0;
    for (int i = 0; i < nA; ++i) {
      int j = mAB[i];
      if (j >= 0 && j < nB && mBA[j] == i) {
        if (out_pairs != nullptr) {
          if (n_out >= max_pairs) break;  // unreachable per contract
          out_pairs[2 * n_out] = (uint32_t)i;
          out_pairs[2 * n_out + 1] = (uint32_t)j;
        }
        ++n_out;
      }
    }
    if (out_num_matches) *out_num_matches = n_out;
    return 0;
  }
}

// ── Exported entry points ────────────────────────────────────────────────
// Whole calls serialized (grow-only pools are shared state; GPU work is
// serial anyway). Dispatch to v2 unless OFFICIAL_AETHER_MATCH_V2=0.
static std::mutex gMatchCallLock;

// GEMM matcher with mutual cross-check, emitting index pairs.
// out_pairs is caller-allocated as 2*max_pairs uint32 entries. Cross-checked
// matches are unique per idxA, so max_pairs=min(nA,nB) cannot truncate.
extern "C" int aether_gpu_match_gemm_pairs(const uint8_t* dA, int nA,
                                           const uint8_t* dB, int nB,
                                           double max_ratio,
                                           uint32_t* out_pairs, int max_pairs,
                                           int* out_num_matches) {
  std::lock_guard<std::mutex> lk(gMatchCallLock);
  if (MatchV2Enabled()) {
    return matchPairsImplV2(dA, nA, nullptr, dB, nB, nullptr, max_ratio,
                            nullptr, nullptr, 0u, 0.0f, out_pairs, max_pairs,
                            out_num_matches);
  }
  return matchPairsImpl(dA, nA, nullptr, dB, nB, nullptr, max_ratio, nullptr,
                        nullptr, 0u, 0.0f, out_pairs, max_pairs,
                        out_num_matches);
}

// Same matcher semantics with explicit runtime resource identity. When the
// experiment is disabled, v2 is unavailable, or half-storage is forced, this
// is the old path verbatim. Generation V1 is currently 1 for immutable
// per-frame descriptor tables and is still explicit so replacement is safe.
extern "C" int aether_gpu_match_gemm_pairs_resident(
    uint64_t session_nonce, uint32_t frame_a, uint32_t generation_a,
    const uint8_t* dA, int nA, uint32_t frame_b, uint32_t generation_b,
    const uint8_t* dB, int nB, double max_ratio, uint32_t* out_pairs,
    int max_pairs, int* out_num_matches) {
  std::lock_guard<std::mutex> lk(gMatchCallLock);
  if (MatchV2Enabled()) {
    return matchPairsImplV2(
        dA, nA, nullptr, dB, nB, nullptr, max_ratio, nullptr, nullptr, 0u,
        0.0f, out_pairs, max_pairs, out_num_matches, session_nonce, frame_a,
        generation_a, frame_b, generation_b);
  }
  return matchPairsImpl(dA, nA, nullptr, dB, nB, nullptr, max_ratio, nullptr,
                        nullptr, 0u, 0.0f, out_pairs, max_pairs,
                        out_num_matches);
}

extern "C" void aether_gpu_match_descriptor_residency_invalidate(
    uint64_t session_nonce, uint32_t frame_ordinal) {
  std::lock_guard<std::mutex> lk(gMatchCallLock);
  const auto found = gDescriptorResidencySessions.find(session_nonce);
  if (found == gDescriptorResidencySessions.end()) return;
  EraseResidentBuffers(
      found->second.get(),
      found->second->policy.InvalidateFrame(session_nonce, frame_ordinal));
}

extern "C" void aether_gpu_match_descriptor_residency_clear_session(
    uint64_t session_nonce) {
  std::lock_guard<std::mutex> lk(gMatchCallLock);
  const auto found = gDescriptorResidencySessions.find(session_nonce);
  if (found == gDescriptorResidencySessions.end()) return;
  found->second->policy.ClearSession(session_nonce);
  found->second->buffers.clear();
  gDescriptorResidencySessions.erase(found);
}

extern "C" int aether_gpu_match_descriptor_residency_stats(
    uint64_t session_nonce, uint64_t* hits, uint64_t* misses,
    uint64_t* evictions, uint64_t* stale_replacements,
    uint64_t* upload_bytes, uint64_t* resident_bytes,
    uint64_t* resident_entries, uint64_t* allocation_failures,
    uint64_t* device_resets) {
  std::lock_guard<std::mutex> lk(gMatchCallLock);
  uint64_t values[9] = {0};
  const auto found = gDescriptorResidencySessions.find(session_nonce);
  if (found != gDescriptorResidencySessions.end()) {
    const auto stats = found->second->policy.stats();
    values[0] = stats.hits;
    values[1] = stats.misses;
    values[2] = stats.evictions;
    values[3] = stats.stale_replacements;
    values[4] = found->second->upload_bytes;
    values[5] = found->second->policy.resident_bytes();
    values[6] = found->second->policy.size();
    values[7] = found->second->allocation_failures;
    values[8] = found->second->device_resets;
  }
  uint64_t* outputs[9] = {hits,
                          misses,
                          evictions,
                          stale_replacements,
                          upload_bytes,
                          resident_bytes,
                          resident_entries,
                          allocation_failures,
                          device_resets};
  for (size_t i = 0; i < 9; ++i) {
    if (outputs[i]) *outputs[i] = values[i];
  }
  return found == gDescriptorResidencySessions.end() ? 0 : 1;
}

// COLMAP-style geometry-guided matcher. xy arrays contain two floats per
// keypoint. matrixAB/matrixBA are row-major 3x3 matrices; guide_mode 1 means
// epipolar E/F and 2 means homography H. A non-zero return is fail-closed by
// native finalize and never triggers CPU matching on the device.
extern "C" int aether_gpu_match_gemm_pairs_guided(
    const uint8_t* dA, int nA, const float* xyA, const uint8_t* dB, int nB,
    const float* xyB, double max_ratio, const float* matrixAB,
    const float* matrixBA, int guide_mode, float max_residual,
    uint32_t* out_pairs, int max_pairs, int* out_num_matches) {
  std::lock_guard<std::mutex> lk(gMatchCallLock);
  // Guided fused path is opt-in only (near-parity, boundary-only divergence
  // — see header); default routes guided matching through the proven v1
  // two-pass kernel for constructive bit-exactness.
  if (MatchV2Enabled() && MatchV2GuidedFused()) {
    return matchPairsImplV2(dA, nA, xyA, dB, nB, xyB, max_ratio, matrixAB,
                            matrixBA, (uint32_t)guide_mode, max_residual,
                            out_pairs, max_pairs, out_num_matches);
  }
  return matchPairsImpl(dA, nA, xyA, dB, nB, xyB, max_ratio, matrixAB,
                        matrixBA, (uint32_t)guide_mode, max_residual,
                        out_pairs, max_pairs, out_num_matches);
}
