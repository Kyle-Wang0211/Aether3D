// M1 probe: Harris + GFTT candidates on Dawn (WGSL ports of OpenCV 4.0.1 corner.cl / gftt.cl semantics),
// host post-selection ported from featureselect.cpp (sort desc, minDistance grid, maxCorners), diffed against the CPU reference dump.
#include "dawn_kernel_harness.h"
#include <webgpu/webgpu_cpp.h>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>
using aether::tools::DawnKernelHarness;
struct Params { uint32_t width, height; float scale, k, quality; uint32_t max_corners, pwq, base; };
static std::string slurp(const std::string& p) { std::ifstream f(p, std::ios::binary); std::stringstream s; s << f.rdbuf(); return s.str(); }
static std::vector<uint8_t> slurpb(const std::string& p) { auto s = slurp(p); return std::vector<uint8_t>(s.begin(), s.end()); }
int main(int argc, char** argv) {
  if (argc < 5) { fprintf(stderr, "usage: probe <wgsl_dir> <ref_out_dir> <W> <H> [max_corners=200] [minDist=20] [quality=1e-3] [k=0.04]\n"); return 1; }
  const std::string wdir = argv[1], rdir = argv[2]; const uint32_t W = atoi(argv[3]), H = atoi(argv[4]);
  const uint32_t maxCorners = argc > 5 ? atoi(argv[5]) : 200; const double minDist = argc > 6 ? atof(argv[6]) : 20.0;
  const float quality = argc > 7 ? atof(argv[7]) : 1e-3f, k = argc > 8 ? atof(argv[8]) : 0.04f;
  auto img = slurpb(rdir + "/img.u8"); if (img.size() != size_t(W) * H) { fprintf(stderr, "img.u8 size %zu != %u*%u\n", img.size(), W, H); return 1; }
  auto eig_cpu_b = slurpb(rdir + "/eig.f32"); std::vector<float> eig_cpu(W * H); memcpy(eig_cpu.data(), eig_cpu_b.data(), W * H * 4);
  const int block = 3, ksize = 3; double scale = (double)(1 << (ksize - 1)) * block * 255.0; scale = 1.0 / scale;
  DawnKernelHarness h; if (!h.init()) { fprintf(stderr, "harness init failed\n"); return 2; }
  const std::string common = slurp(wdir + "/gftt_common.wgsl");
  auto pipe = [&](const char* name) { auto p = h.load_compute(common + slurp(wdir + "/" + name + ".wgsl")); if (!p) { fprintf(stderr, "load %s failed\n", name); exit(3); } return p; };
  auto p_sobel = pipe("sobel_dxdy"), p_harris = pipe("harris_box"), p_max = pipe("gftt_max"), p_find = pipe("gftt_find");
  const uint32_t capacity = std::max<uint32_t>(1024, (W * H) / 4);
  const uint32_t PW = W + 42, PH = H + 42, PWQ = (PW + 3) / 4; Params prm{W, H, (float)scale, k, quality, capacity, PWQ, 0};   // packed padded layout
  std::vector<uint32_t> imgpad(size_t(PWQ) * PH, 0); for (uint32_t y = 0; y < H; ++y) for (uint32_t x = 0; x < W; ++x) { uint32_t c = x + 21; imgpad[size_t(y + 21) * PWQ + (c >> 2)] |= uint32_t(img[size_t(y) * W + x]) << ((c & 3) * 8); }
  auto b_img = h.upload(imgpad.data(), imgpad.size() * 4, wgpu::BufferUsage::Storage);
  auto b_prm = h.upload(&prm, sizeof prm, wgpu::BufferUsage::Uniform);
  auto b_dx = h.alloc(W * H * 4, wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);
  auto b_dy = h.alloc(W * H * 4, wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);
  auto b_eig = h.alloc(W * H * 4, wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);
  const uint32_t maxGroups = std::min<uint32_t>(1024, (W * H + 255) / 256);
  auto b_partial = h.alloc(maxGroups * 4, wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);
  float zero = 0.f; uint32_t zero_u = 0;
  auto b_thr = h.upload(&zero, 4, wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopyDst);
  auto b_cnt = h.upload(&zero_u, 4, wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc | wgpu::BufferUsage::CopyDst);
  auto b_corners = h.alloc(capacity * 8, wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);
  auto st_eig = h.alloc_staging_for_readback(W * H * 4); auto st_part = h.alloc_staging_for_readback(maxGroups * 4);
  auto st_cnt = h.alloc_staging_for_readback(4); auto st_cor = h.alloc_staging_for_readback(capacity * 8);
  const uint32_t gx = (W + 15) / 16, gy = (H + 15) / 16;
  auto t0 = std::chrono::steady_clock::now();
  h.dispatch(p_sobel, {b_img, b_dx, b_dy, b_prm}, gx, gy);
  h.dispatch(p_harris, {b_dx, b_dy, b_eig, b_prm}, gx, gy);
  { auto p_fused = pipe("harris_fused"); auto b_eig2 = h.alloc(W * H * 4, wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc); auto st2 = h.alloc_staging_for_readback(W * H * 4);
    auto tf0 = std::chrono::steady_clock::now(); h.dispatch(p_fused, {b_img, b_eig2, b_prm}, gx, gy); h.copy_to_staging(b_eig2, st2, W * H * 4); auto e2 = h.readback(st2, W * H * 4);
    auto tf1 = std::chrono::steady_clock::now(); h.copy_to_staging(b_eig, st_eig, W * H * 4); auto e1 = h.readback(st_eig, W * H * 4);
    size_t nb = 0; for (size_t i = 0; i < size_t(W) * H; ++i) if (memcmp(e1.data() + i * 4, e2.data() + i * 4, 4) != 0) ++nb;
    printf("harris_fused vs sobel+harris_box: bitwise eig mismatches=%zu of %zu (fused dispatch+readback %.1f ms)\n", nb, size_t(W) * H, std::chrono::duration<double, std::milli>(tf1 - tf0).count()); }
  h.dispatch(p_max, {b_eig, b_partial, b_prm}, maxGroups);
  h.copy_to_staging(b_partial, st_part, maxGroups * 4); auto part = h.readback(st_part, maxGroups * 4);
  float mx = -3.4e38f; for (uint32_t i = 0; i < maxGroups; ++i) { float v; memcpy(&v, part.data() + i * 4, 4); mx = std::max(mx, v); }
  float thr = mx * quality; h.device().GetQueue().WriteBuffer(b_thr, 0, &thr, 4); h.device().GetQueue().WriteBuffer(b_cnt, 0, &zero_u, 4);
  h.dispatch(p_find, {b_eig, b_thr, b_cnt, b_corners, b_prm}, (W - 2 + 15) / 16, (H - 2 + 15) / 16);
  h.copy_to_staging(b_cnt, st_cnt, 4); auto cnt_b = h.readback(st_cnt, 4); uint32_t cnt; memcpy(&cnt, cnt_b.data(), 4); cnt = std::min(cnt, capacity);
  h.copy_to_staging(b_corners, st_cor, cnt * 8); auto cor_b = h.readback(st_cor, cnt * 8);
  auto t1 = std::chrono::steady_clock::now();
  h.copy_to_staging(b_eig, st_eig, W * H * 4); auto eig_b = h.readback(st_eig, W * H * 4); std::vector<float> eig(W * H); memcpy(eig.data(), eig_b.data(), W * H * 4);
  { auto cdx = slurpb(rdir + "/dx.f32"), cdy = slurpb(rdir + "/dy.f32"); if (cdx.size() == size_t(W) * H * 4) { auto st2 = h.alloc_staging_for_readback(W * H * 4); h.copy_to_staging(b_dx, st2, W * H * 4); auto gdx = h.readback(st2, W * H * 4); h.copy_to_staging(b_dy, st2, W * H * 4); auto gdy = h.readback(st2, W * H * 4);
      size_t bx = 0, by = 0; for (size_t i = 0; i < size_t(W) * H; ++i) { bx += memcmp(gdx.data() + i * 4, cdx.data() + i * 4, 4) != 0; by += memcmp(gdy.data() + i * 4, cdy.data() + i * 4, 4) != 0; } printf("dx/dy bitwise mismatches: dx=%zu dy=%zu of %zu\n", bx, by, size_t(W) * H); } }
  std::string err; if (DawnKernelHarness::take_device_error(&err)) { fprintf(stderr, "DAWN ERROR: %s\n", err.c_str()); return 4; }
  // ── eig diff ──
  double maxabs = 0, maxrel = 0; size_t nbad = 0; double cpu_mx = 0; for (auto v : eig_cpu) cpu_mx = std::max<double>(cpu_mx, v);
  for (size_t i = 0; i < eig.size(); ++i) { double d = fabs((double)eig[i] - eig_cpu[i]); maxabs = std::max(maxabs, d); double rel = d / std::max(1e-12, fabs((double)eig_cpu[i])); if (fabs(eig_cpu[i]) > cpu_mx * 1e-3) { maxrel = std::max(maxrel, rel); if (rel > 1e-5) ++nbad; } }
  { size_t nb = 0; for (size_t i = 0; i < eig.size(); ++i) if (memcmp(&eig[i], &eig_cpu[i], 4) != 0) { if (nb < 3) printf("  bitwise eig diff at (%zu,%zu): cpu=%.9g gpu=%.9g\n", i % W, i / W, eig_cpu[i], eig[i]); ++nb; } printf("bitwise eig mismatches=%zu\n", nb); }
  printf("eig: cpu_max=%.9g gpu_max=%.9g thr=%.9g | maxabs=%.3g maxrel(above thr)=%.3g bad(rel>1e-5)=%zu/%zu\n", cpu_mx, mx, thr, maxabs, maxrel, nbad, eig.size());
  // ── host post-selection (featureselect.cpp 4.0.1) ──
  struct C { float v; int x, y; }; std::vector<C> cs(cnt);
  for (uint32_t i = 0; i < cnt; ++i) { uint32_t vb, yx; memcpy(&vb, cor_b.data() + i * 8, 4); memcpy(&yx, cor_b.data() + i * 8 + 4, 4); float v; memcpy(&v, &vb, 4); cs[i] = {v, int(yx >> 16), int(yx & 0xffff)}; }
  std::sort(cs.begin(), cs.end(), [&](const C& a, const C& b) { if (a.v != b.v) return a.v > b.v; return (a.y * (long)W + a.x) > (b.y * (long)W + b.x); }); // greaterThanPtr: value desc, ties → later address first
  std::vector<C> out;
  if (minDist >= 1) {
    int cell = (int)lround(minDist), gw = (W + cell - 1) / cell, gh = (H + cell - 1) / cell; double md2 = minDist * minDist;
    std::vector<std::vector<std::pair<float,float>>> grid(gw * gh);
    for (auto& c : cs) { bool good = true; int xc = c.x / cell, yc = c.y / cell;
      int x1 = std::max(0, xc - 1), y1 = std::max(0, yc - 1), x2 = std::min(gw - 1, xc + 1), y2 = std::min(gh - 1, yc + 1);
      for (int yy = y1; yy <= y2 && good; ++yy) for (int xx = x1; xx <= x2 && good; ++xx) for (auto& m : grid[yy * gw + xx]) { float dxx = c.x - m.first, dyy = c.y - m.second; if (dxx * dxx + dyy * dyy < md2) { good = false; break; } }
      if (good) { grid[yc * gw + xc].push_back({(float)c.x, (float)c.y}); out.push_back(c); if (out.size() >= maxCorners) break; } }
  } else { for (auto& c : cs) { out.push_back(c); if (out.size() >= maxCorners) break; } }
  // ── compare with CPU list ──
  std::ifstream cf(rdir + "/corners_cpu.txt"); std::vector<C> cpu; float x, y, v; while (cf >> x >> y >> v) cpu.push_back({v, (int)x, (int)y});
  size_t nmatch = 0, first_bad = SIZE_MAX; for (size_t i = 0; i < std::min(cpu.size(), out.size()); ++i) { if (cpu[i].x == out[i].x && cpu[i].y == out[i].y) ++nmatch; else if (first_bad == SIZE_MAX) first_bad = i; }
  printf("candidates=%u selected=%zu cpu=%zu ordered-match=%zu/%zu first_mismatch=%s\n", cnt, out.size(), cpu.size(), nmatch, cpu.size(), first_bad == SIZE_MAX ? "none" : std::to_string(first_bad).c_str());
  if (first_bad != SIZE_MAX) { auto& a = cpu[first_bad]; auto& b = out[first_bad]; printf("  cpu[%zu]=(%d,%d,%.9g) gpu[%zu]=(%d,%d,%.9g)\n", first_bad, a.x, a.y, a.v, first_bad, b.x, b.y, b.v); }
  // set match ignoring order
  size_t setm = 0; for (auto& a : cpu) for (auto& b : out) if (a.x == b.x && a.y == b.y) { ++setm; break; }
  printf("set-match=%zu/%zu  gpu(sobel+harris+max+find, incl. 2 readbacks)=%.2fms\n", setm, cpu.size(), std::chrono::duration<double, std::milli>(t1 - t0).count());
  return (setm == cpu.size() && nmatch == cpu.size()) ? 0 : 5;
}
