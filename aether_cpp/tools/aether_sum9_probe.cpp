#include "dawn_kernel_harness.h"
#include <webgpu/webgpu_cpp.h>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>
using aether::tools::DawnKernelHarness;
static std::string slurp(const std::string& p) { std::ifstream f(p, std::ios::binary); std::stringstream s; s << f.rdbuf(); return s.str(); }
int main(int argc, char** argv) {
  std::string wdir = argv[1]; auto cases = slurp(argv[2]); uint32_t N; memcpy(&N, cases.data(), 4);
  std::vector<float> in(N * 9), ex(N); for (uint32_t i = 0; i < N; ++i) { memcpy(&in[i * 9], cases.data() + 4 + i * 40, 36); memcpy(&ex[i], cases.data() + 4 + i * 40 + 36, 4); }
  std::string hb = slurp(wdir + "/harris_box.wgsl"); size_t a = hb.find("struct Acc"), b = hb.find("fn box3");
  std::string src = slurp(wdir + "/gftt_common.wgsl") + hb.substr(a, b - a) + R"(
@group(0) @binding(0) var<storage, read> inp: array<f32>;
@group(0) @binding(1) var<storage, read_write> outp: array<f32>;
@compute @workgroup_size(64) fn main(@builtin(global_invocation_id) gid: vec3<u32>) { let i = gid.x; if (i >= arrayLength(&outp)) { return; } let o = i * 9u; outp[i] = exact_sum9(inp[o], inp[o+1u], inp[o+2u], inp[o+3u], inp[o+4u], inp[o+5u], inp[o+6u], inp[o+7u], inp[o+8u]); })";
  DawnKernelHarness h; if (!h.init()) return 2; auto p = h.load_compute(src); std::string e; if (!p || DawnKernelHarness::take_device_error(&e)) { fprintf(stderr, "load: %s\n", e.c_str()); return 3; }
  auto bi = h.upload(in.data(), in.size() * 4, wgpu::BufferUsage::Storage); auto bo = h.alloc(N * 4, wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc); auto st = h.alloc_staging_for_readback(N * 4);
  h.dispatch(p, {bi, bo}, (N + 63) / 64); h.copy_to_staging(bo, st, N * 4); auto rb = h.readback(st, N * 4);
  int bad = 0; for (uint32_t i = 0; i < N; ++i) { float g; memcpy(&g, rb.data() + i * 4, 4); if (memcmp(&g, &ex[i], 4) != 0) { if (bad < 6) { printf("case %u: gpu=%.9g exact=%.9g  terms:", i, g, ex[i]); for (int k = 0; k < 9; ++k) printf(" %.9g", in[i * 9 + k]); printf("\n"); } ++bad; } }
  printf("sum9 mismatches: %d / %u\n", bad, N); return bad ? 1 : 0;
}
