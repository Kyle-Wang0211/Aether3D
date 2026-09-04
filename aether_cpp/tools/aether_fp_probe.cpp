#include "dawn_kernel_harness.h"
#include <webgpu/webgpu_cpp.h>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <random>
#include <sstream>
#include <vector>
using aether::tools::DawnKernelHarness;
static std::string slurp(const std::string& p) { std::ifstream f(p, std::ios::binary); std::stringstream s; s << f.rdbuf(); return s.str(); }
int main(int argc, char** argv) {
  const int N = 1 << 16; std::vector<float> in(N * 10); std::mt19937 rng(7); std::uniform_real_distribution<float> U(0.f, 255.f), F(0.f, 1.f);
  for (int i = 0; i < N; ++i) { float* p = &in[i * 10]; p[0] = std::floor(U(rng)); p[1] = F(rng); p[2] = std::floor(U(rng)); p[3] = 1.f - p[1]; p[4] = F(rng); p[5] = std::floor(U(rng)); p[6] = p[1]; p[7] = std::floor(U(rng)); p[8] = p[3]; p[9] = 1.f - p[4]; }
  DawnKernelHarness h; if (!h.init()) return 2; printf("strict_math=%d\n", (int)h.strict_math());
  auto pipe = h.load_compute(slurp(std::string(argv[1]) + "/fp_probe.wgsl")); std::string e; if (!pipe || DawnKernelHarness::take_device_error(&e)) { fprintf(stderr, "load failed %s\n", e.c_str()); return 3; }
  auto bi = h.upload(in.data(), in.size() * 4, wgpu::BufferUsage::Storage); auto bo = h.alloc(N * 24, wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc); auto st = h.alloc_staging_for_readback(N * 24);
  h.dispatch(pipe, {bi, bo}, N / 64); h.copy_to_staging(bo, st, N * 24); auto ob = h.readback(st, N * 24); std::vector<float> out(N * 6); memcpy(out.data(), ob.data(), N * 24);
  int m0 = 0, m1 = 0, m2 = 0, m3 = 0, m4 = 0, m5 = 0;
  for (int i = 0; i < N; ++i) { const float* p = &in[i * 10]; volatile float a = p[0], b = p[1], c = p[2], d = p[3], e2 = p[4], f = p[5], g = p[6], hh = p[7], k = p[8], j = p[9];
    float ab = a * b, cd = c * d, fg = f * g, hk = hh * k; float t1 = ab + cd, t2 = fg + hk; float t1e = t1 * e2, t2j = t2 * j; float r3 = t1e + t2j;
    m0 += (out[i * 6] == t1); m1 += (out[i * 6 + 1] == t1); m2 += (out[i * 6 + 2] == t1); m3 += (out[i * 6 + 3] == r3);
    m4 += (out[i * 6 + 4] == std::nearbyint(a + 0.5f));
    uint32_t u = (uint32_t)a * 16777215u + (uint32_t)c; m5 += (out[i * 6 + 5] == (float)u); }
  printf("N=%d plain_expr=%d fma0_guard=%d bitcast_guard=%d nested_guard=%d round_half_even=%d u32_to_f32=%d\n", N, m0, m1, m2, m3, m4, m5);
  return 0;
}
