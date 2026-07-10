// indirect_selftest.cc — GPU DSP-SIFT M1 Stage A gate.
//
// Exercises the harness's new dispatch_indirect() + alloc_indirect_args() on the
// exact pattern the keypoint pipeline needs (GPU_DSP_SIFT_PLAN_AFFINE_OFF.md §3-①):
//   1. _count   : flat grid does atomicAdd(&counter,1) with a CAP guard, and
//                 stamps each produced slot (dense permutation fill check).
//   2. _args    : single-thread pass writes args = [ceil(count/WG),1,1] (clamped
//                 to CAP) WITHOUT the count ever returning to the CPU.
//   3. _consume : launched via DispatchWorkgroupsIndirect(args) — every slot in
//                 [0,count) gets marked, proving the GPU read the dispatch dims.
//
// Gate (all must hold):
//   - counter == N
//   - stamp[0..min(N,CAP)) is a permutation of producer ids (every slot written)
//   - args (read back AFTER the fact, only to validate) == [ceil(min(N,CAP)/WG),1,1]
//   - hits[0..min(N,CAP)) all == 1, hits[>=count] untouched
//
// Build target: indirect_selftest_exe. Run: ./indirect_selftest_exe [N]

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

#include "dawn_kernel_harness.h"

namespace {

using aether::tools::DawnKernelHarness;

std::string load_wgsl(const char* filename) {
  const std::string path = std::string(AETHER_WGSL_DIR) + "/" + filename;
  FILE* f = std::fopen(path.c_str(), "rb");
  if (!f) {
    std::fprintf(stderr, "[indirect_selftest] cannot open WGSL: %s\n",
                 path.c_str());
    std::abort();
  }
  std::fseek(f, 0, SEEK_END);
  long sz = std::ftell(f);
  std::fseek(f, 0, SEEK_SET);
  std::string out(static_cast<size_t>(sz), '\0');
  size_t rd = std::fread(out.data(), 1, static_cast<size_t>(sz), f);
  std::fclose(f);
  out.resize(rd);
  return out;
}

template <typename T>
std::vector<T> read_u32(DawnKernelHarness& h, const wgpu::Buffer& buf,
                        size_t count) {
  const size_t bytes = count * sizeof(T);
  wgpu::Buffer staging = h.alloc_staging_for_readback(bytes);
  h.copy_to_staging(buf, staging, bytes);
  std::vector<uint8_t> raw = h.readback(staging, bytes);
  std::vector<T> out(count);
  std::memcpy(out.data(), raw.data(), bytes);
  return out;
}

}  // namespace

int main(int argc, char** argv) {
  const uint32_t kCap = 24000u;  // mirrors the real keypoint CAP
  const uint32_t kWG = 64u;      // indirect consumer's @workgroup_size
  uint32_t N = (argc > 1) ? static_cast<uint32_t>(std::atoi(argv[1])) : 18000u;
  std::printf("[indirect_selftest] N=%u CAP=%u WG=%u\n", N, kCap, kWG);

  DawnKernelHarness h;
  if (!h.init()) {
    std::fprintf(stderr, "[indirect_selftest] Dawn init failed\n");
    return 2;
  }

  wgpu::ComputePipeline pipe_count =
      h.load_compute(load_wgsl("sift_indirect_selftest_count.wgsl"));
  wgpu::ComputePipeline pipe_args =
      h.load_compute(load_wgsl("sift_indirect_selftest_args.wgsl"));
  wgpu::ComputePipeline pipe_consume =
      h.load_compute(load_wgsl("sift_indirect_selftest_consume.wgsl"));

  // ── Buffers ──
  uint32_t zero = 0u;
  wgpu::Buffer counter = h.upload(&zero, sizeof(zero),
                                  wgpu::BufferUsage::Storage |
                                      wgpu::BufferUsage::CopySrc);
  std::vector<uint32_t> stamp_init(kCap, 0u);
  wgpu::Buffer stamp = h.upload(stamp_init.data(),
                                stamp_init.size() * sizeof(uint32_t),
                                wgpu::BufferUsage::Storage |
                                    wgpu::BufferUsage::CopySrc);
  std::vector<uint32_t> hits_init(kCap, 0u);
  wgpu::Buffer hits = h.upload(hits_init.data(),
                               hits_init.size() * sizeof(uint32_t),
                               wgpu::BufferUsage::Storage |
                                   wgpu::BufferUsage::CopySrc);
  wgpu::Buffer args = h.alloc_indirect_args();

  struct CountParams { uint32_t n, cap; } cp{N, kCap};
  wgpu::Buffer cp_buf = h.upload(&cp, sizeof(cp), wgpu::BufferUsage::Uniform);
  struct ArgsParams { uint32_t wg, cap; } ap{kWG, kCap};
  wgpu::Buffer ap_buf = h.upload(&ap, sizeof(ap), wgpu::BufferUsage::Uniform);
  const uint32_t expect_count = std::min(N, kCap);
  struct ConsumeParams { uint32_t count; } csp{expect_count};
  wgpu::Buffer csp_buf = h.upload(&csp, sizeof(csp), wgpu::BufferUsage::Uniform);

  // ── 1. count pass (flat grid over N) ──
  const uint32_t count_groups = (N + kWG - 1u) / kWG;
  h.dispatch(pipe_count, {counter, stamp, cp_buf}, count_groups);

  // ── 2. args pass (single thread; count stays on GPU) ──
  h.dispatch(pipe_args, {counter, args, ap_buf}, 1u);

  // ── 3. consume pass (INDIRECT — dims read from `args` on the GPU) ──
  h.dispatch_indirect(pipe_consume, {hits, csp_buf}, args, /*offset=*/0);

  // ── Validate ──
  std::vector<uint32_t> counter_v = read_u32<uint32_t>(h, counter, 1);
  std::vector<uint32_t> args_v = read_u32<uint32_t>(h, args, 3);
  std::vector<uint32_t> stamp_v = read_u32<uint32_t>(h, stamp, kCap);
  std::vector<uint32_t> hits_v = read_u32<uint32_t>(h, hits, kCap);

  bool pass = true;

  // counter == N
  if (counter_v[0] != N) {
    std::printf("FAIL counter=%u expected %u\n", counter_v[0], N);
    pass = false;
  }

  // args == [ceil(min(N,CAP)/WG), 1, 1]
  const uint32_t expect_groups = (expect_count + kWG - 1u) / kWG;
  if (args_v[0] != expect_groups || args_v[1] != 1u || args_v[2] != 1u) {
    std::printf("FAIL args=[%u,%u,%u] expected [%u,1,1]\n", args_v[0], args_v[1],
                args_v[2], expect_groups);
    pass = false;
  }

  // stamp[0..expect_count) is a permutation of [1, N]: every slot written, all
  // distinct, each value in [1, N]. (Only valid when N <= CAP; if N > CAP the
  // dropped producers leave the fill non-bijective by design — just check
  // density + range.)
  {
    std::vector<char> seen(N + 1u, 0);
    size_t holes = 0, dups = 0, oob = 0;
    for (uint32_t i = 0; i < expect_count; ++i) {
      uint32_t v = stamp_v[i];
      if (v == 0u) { ++holes; continue; }
      if (v > N) { ++oob; continue; }
      if (seen[v]) ++dups; else seen[v] = 1;
    }
    if (holes || oob) {
      std::printf("FAIL stamp fill: holes=%zu oob=%zu (expect_count=%u)\n",
                  holes, oob, expect_count);
      pass = false;
    }
    if (N <= kCap && dups) {
      std::printf("FAIL stamp not a permutation: dups=%zu\n", dups);
      pass = false;
    }
  }

  // hits[0..expect_count) all 1; hits[expect_count..CAP) all 0.
  {
    size_t missing = 0, leaked = 0;
    for (uint32_t i = 0; i < kCap; ++i) {
      if (i < expect_count) { if (hits_v[i] != 1u) ++missing; }
      else { if (hits_v[i] != 0u) ++leaked; }
    }
    if (missing || leaked) {
      std::printf("FAIL hits: missing=%zu leaked=%zu (expect_count=%u)\n",
                  missing, leaked, expect_count);
      pass = false;
    }
  }

  std::printf("[indirect_selftest] counter=%u args=[%u,%u,%u] expect_count=%u\n",
              counter_v[0], args_v[0], args_v[1], args_v[2], expect_count);
  std::printf("%s\n", pass ? "PASS M1-A dispatch_indirect"
                           : "FAIL M1-A dispatch_indirect");
  return pass ? 0 : 1;
}
