// M2+M3 probe. M2: CLAHE -> padded pyramid -> Scharr on Dawn, byte-diffed against OpenCV CPU dumps
// (xrslam-gpu-detect/tools/lk_cpu_ref.cpp). M3: pyramidal LK (fwd + reverse) diffed against lk_cpu.txt.
// Modes: default = GPU-built pyramids (end-to-end), --cpu-pyr = upload the CPU dumps (isolates LK numerics).
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
struct P { uint32_t w, h, pw, ph, w2, h2, pw2, ph2, tiles_x, tiles_y, tw, th; float inv_tw, inv_th, lut_scale; uint32_t clip, base, base2, dbase, pad0; };
struct LKP { uint32_t n, levels, maxlevel, flags; uint32_t lv[4][4]; uint32_t dlv[4][4]; };
static std::string slurp(const std::string& p) { std::ifstream f(p, std::ios::binary); std::stringstream s; s << f.rdbuf(); return s.str(); }
static std::vector<uint8_t> slurpb(const std::string& p) { auto s = slurp(p); return std::vector<uint8_t>(s.begin(), s.end()); }
static const int PAD = 21, MAXL = 3, TILES = 8;
struct Pyr { int L = 0; std::vector<P> prm; std::vector<wgpu::Buffer> b_prm; wgpu::Buffer img, der; size_t n_img = 0; };
static DawnKernelHarness* H;
static wgpu::ComputePipeline p_hist, p_lut, p_interp, p_pad, p_down, p_scharr, p_lk;
static uint32_t g16(uint32_t n) { return (n + 15) / 16; }
static Pyr geometry(uint32_t W, uint32_t H_) {
  Pyr y; std::vector<uint32_t> lw{W}, lh{H_};
  for (int l = 1; l <= MAXL; ++l) { uint32_t nw = (lw.back() + 1) / 2, nh = (lh.back() + 1) / 2; if (nw <= 21 || nh <= 21) break; lw.push_back(nw); lh.push_back(nh); }
  y.L = (int)lw.size(); y.prm.resize(y.L);
  const uint32_t tw = W / TILES, th = H_ / TILES, tileTotal = tw * th; const float lutScale = 255.f / (float)tileTotal;
  int clip = (int)(6.0 * tileTotal / 256); clip = clip < 1 ? 1 : clip;
  uint32_t base = 0;
  for (int l = 0; l < y.L; ++l) {
    P& q = y.prm[l]; q.w = lw[l]; q.h = lh[l]; q.pw = lw[l] + 2 * PAD; q.ph = lh[l] + 2 * PAD; q.base = base; q.dbase = base; base += q.pw * q.ph;
    if (l + 1 < y.L) { q.w2 = lw[l + 1]; q.h2 = lh[l + 1]; q.pw2 = lw[l + 1] + 2 * PAD; q.ph2 = lh[l + 1] + 2 * PAD; q.base2 = base; }
    q.tiles_x = TILES; q.tiles_y = TILES; q.tw = tw; q.th = th; q.inv_tw = 1.0f / (float)tw; q.inv_th = 1.0f / (float)th; q.lut_scale = lutScale; q.clip = clip;
  }
  y.n_img = base; return y;
}
static void alloc_pyr(Pyr& y) {
  for (int l = 0; l < y.L; ++l) y.b_prm.push_back(H->upload(&y.prm[l], sizeof(P), wgpu::BufferUsage::Uniform));
  y.img = H->alloc(y.n_img * 4, wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc | wgpu::BufferUsage::CopyDst);
  y.der = H->alloc(y.n_img * 8, wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc | wgpu::BufferUsage::CopyDst);
}
static wgpu::Buffer g_lut;
static Pyr build_gpu(const std::vector<uint8_t>& img, uint32_t W, uint32_t H_) {
  Pyr y = geometry(W, H_); alloc_pyr(y);
  std::vector<uint32_t> src32((size_t(W) * H_ + 3) / 4, 0); for (size_t i = 0; i < size_t(W) * H_; ++i) src32[i >> 2] |= uint32_t(img[i]) << ((i & 3) * 8);
  auto b_src = H->upload(src32.data(), src32.size() * 4, wgpu::BufferUsage::Storage);
  std::vector<uint32_t> zeros(TILES * TILES * 256, 0);
  auto b_hist = H->upload(zeros.data(), zeros.size() * 4, wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopyDst);
  auto b_lut = H->alloc(zeros.size() * 4, wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);
  g_lut = b_lut;
  H->dispatch(p_hist, {b_src, b_hist, y.b_prm[0]}, TILES, TILES);
  H->dispatch(p_lut, {b_hist, b_lut, y.b_prm[0]}, (TILES * TILES + 63) / 64);
  // CLAHE_Interpolation_Body ctor tables, float exactly as 4.0.1 (this TU is compiled with -ffp-contract=off)
  std::vector<float> colt(W * 4), rowt(H_ * 4);
  { const float inv_tw = 1.0f / y.prm[0].tw; for (uint32_t x = 0; x < W; ++x) { float txf = x * inv_tw - 0.5f; int tx1 = (int)std::floor(txf); int tx2 = tx1 + 1; float xa = txf - tx1, xa1 = 1.0f - xa; tx1 = std::max(tx1, 0); tx2 = std::min(tx2, TILES - 1); colt[x * 4] = (float)(tx1 * 256); colt[x * 4 + 1] = (float)(tx2 * 256); colt[x * 4 + 2] = xa; colt[x * 4 + 3] = xa1; } }
  { const float inv_th = 1.0f / y.prm[0].th; for (uint32_t yy = 0; yy < H_; ++yy) { float tyf = yy * inv_th - 0.5f; int ty1 = (int)std::floor(tyf); int ty2 = ty1 + 1; float ya = tyf - ty1, ya1 = 1.0f - ya; ty1 = std::max(ty1, 0); ty2 = std::min(ty2, TILES - 1); rowt[yy * 4] = (float)(ty1 * TILES * 256); rowt[yy * 4 + 1] = (float)(ty2 * TILES * 256); rowt[yy * 4 + 2] = ya; rowt[yy * 4 + 3] = ya1; } }
  auto b_colt = H->upload(colt.data(), colt.size() * 4, wgpu::BufferUsage::Storage); auto b_rowt = H->upload(rowt.data(), rowt.size() * 4, wgpu::BufferUsage::Storage);
  H->dispatch(p_interp, {b_src, b_lut, y.img, y.b_prm[0], b_colt, b_rowt}, g16(W), g16(H_));
  H->dispatch(p_pad, {y.img, y.b_prm[0]}, g16(y.prm[0].pw), g16(y.prm[0].ph));
  for (int l = 0; l + 1 < y.L; ++l) {
    H->dispatch(p_down, {y.img, y.b_prm[l]}, g16(y.prm[l].w2), g16(y.prm[l].h2));
    H->dispatch(p_pad, {y.img, y.b_prm[l + 1]}, g16(y.prm[l + 1].pw), g16(y.prm[l + 1].ph));
  }
  for (int l = 0; l < y.L; ++l) H->dispatch(p_scharr, {y.img, y.der, y.b_prm[l]}, g16(y.prm[l].pw), g16(y.prm[l].ph));
  return y;
}
static Pyr build_from_cpu_l0(const std::string& rdir, const std::string& prefix, uint32_t W, uint32_t H_) {
  Pyr y = geometry(W, H_); alloc_pyr(y);
  const P& q0 = y.prm[0]; const size_t n0 = size_t(q0.pw) * q0.ph;
  auto ci = slurpb(rdir + "/" + prefix + "_L0_pad.u8"); if (ci.size() != n0) { fprintf(stderr, "bad L0 dump\n"); exit(7); }
  std::vector<uint32_t> img(n0); for (size_t i = 0; i < n0; ++i) img[i] = ci[i];
  H->device().GetQueue().WriteBuffer(y.img, 0, img.data(), img.size() * 4);
  for (int l = 0; l + 1 < y.L; ++l) { H->dispatch(p_down, {y.img, y.b_prm[l]}, g16(y.prm[l].w2), g16(y.prm[l].h2)); H->dispatch(p_pad, {y.img, y.b_prm[l + 1]}, g16(y.prm[l + 1].pw), g16(y.prm[l + 1].ph)); }
  for (int l = 0; l < y.L; ++l) H->dispatch(p_scharr, {y.img, y.der, y.b_prm[l]}, g16(y.prm[l].pw), g16(y.prm[l].ph));
  return y;
}
static Pyr upload_cpu(const std::string& rdir, const std::string& prefix, uint32_t W, uint32_t H_, bool with_deriv) {
  Pyr y = geometry(W, H_); alloc_pyr(y);
  std::vector<uint32_t> img(y.n_img, 0); std::vector<int32_t> der(y.n_img * 2, 0);
  for (int l = 0; l < y.L; ++l) {
    const P& q = y.prm[l]; const size_t n = size_t(q.pw) * q.ph;
    auto ci = slurpb(rdir + "/" + prefix + "_L" + std::to_string(l) + "_pad.u8"); if (ci.size() != n) { fprintf(stderr, "bad dump %s L%d\n", prefix.c_str(), l); exit(7); }
    for (size_t i = 0; i < n; ++i) img[q.base + i] = ci[i];
    if (with_deriv) { auto cd = slurpb(rdir + "/" + prefix + "_D" + std::to_string(l) + "_pad.i16x2"); if (cd.size() != n * 4) { fprintf(stderr, "bad deriv dump L%d\n", l); exit(7); }
      for (size_t i = 0; i < n; ++i) { int16_t cx, cy; memcpy(&cx, cd.data() + i * 4, 2); memcpy(&cy, cd.data() + i * 4 + 2, 2); der[(q.dbase + i) * 2] = cx; der[(q.dbase + i) * 2 + 1] = cy; } }
  }
  H->device().GetQueue().WriteBuffer(y.img, 0, img.data(), img.size() * 4);
  if (with_deriv) H->device().GetQueue().WriteBuffer(y.der, 0, der.data(), der.size() * 4);
  return y;
}
// ── M2 diff: GPU pyramid vs CPU dumps (also writes gpu_L{l}_pad.u8 for offline diagnosis)
static int diff_pyr(const Pyr& y, const std::string& rdir, const std::string& prefix, bool dump) {
  auto st_i = H->alloc_staging_for_readback(y.n_img * 4), st_d = H->alloc_staging_for_readback(y.n_img * 8);
  H->copy_to_staging(y.img, st_i, y.n_img * 4); auto gi = H->readback(st_i, y.n_img * 4);
  H->copy_to_staging(y.der, st_d, y.n_img * 8); auto gd = H->readback(st_d, y.n_img * 8);
  int rc = 0;
  for (int l = 0; l < y.L; ++l) {
    const P& q = y.prm[l]; const size_t n = size_t(q.pw) * q.ph;
    auto ci = slurpb(rdir + "/" + prefix + "_L" + std::to_string(l) + "_pad.u8"); auto cd = slurpb(rdir + "/" + prefix + "_D" + std::to_string(l) + "_pad.i16x2");
    if (ci.size() != n || cd.size() != n * 4) { printf("L%d: ref size mismatch\n", l); rc = 6; continue; }
    size_t bad_i = 0, bad_d = 0; int maxd_i = 0, maxd_d = 0; long first_i = -1, first_d = -1; std::vector<uint8_t> g8(n);
    for (size_t i = 0; i < n; ++i) {
      uint32_t g; memcpy(&g, gi.data() + (q.base + i) * 4, 4); g8[i] = (uint8_t)g; int d = abs((int)g - (int)ci[i]); if (d) { ++bad_i; if (first_i < 0) first_i = (long)i; if (d > maxd_i) maxd_i = d; }
      int32_t gx, gy; memcpy(&gx, gd.data() + (q.dbase + i) * 8, 4); memcpy(&gy, gd.data() + (q.dbase + i) * 8 + 4, 4);
      int16_t cx, cy; memcpy(&cx, cd.data() + i * 4, 2); memcpy(&cy, cd.data() + i * 4 + 2, 2);
      int dd = std::max(abs(gx - cx), abs(gy - cy)); if (dd) { ++bad_d; if (first_d < 0) first_d = (long)i; if (dd > maxd_d) maxd_d = dd; }
    }
    if (dump) { std::ofstream f(rdir + "/gpu_" + prefix + "_L" + std::to_string(l) + "_pad.u8", std::ios::binary); f.write((const char*)g8.data(), n); }
    printf("%s L%d %ux%u pad %ux%u: img mismatches=%zu maxdiff=%d first=(%ld,%ld) | deriv mismatches=%zu maxdiff=%d first=(%ld,%ld)\n", prefix.c_str(), l, q.w, q.h, q.pw, q.ph, bad_i, maxd_i, first_i < 0 ? -1 : first_i % q.pw, first_i < 0 ? -1 : first_i / q.pw, bad_d, maxd_d, first_d < 0 ? -1 : first_d % q.pw, first_d < 0 ? -1 : first_d / q.pw);
    if (bad_i || bad_d) rc = 5;
  }
  return rc;
}
struct Pt { float x, y; };
static void run_lk(const Pyr& I, const Pyr& J, const std::vector<Pt>& prev, std::vector<Pt>& next, std::vector<uint32_t>& status) {
  LKP q{}; q.n = (uint32_t)prev.size(); q.levels = I.L; q.maxlevel = I.L - 1; q.flags = 0;
  for (int l = 0; l < I.L; ++l) { q.lv[l][0] = I.prm[l].w; q.lv[l][1] = I.prm[l].h; q.lv[l][2] = I.prm[l].pw; q.lv[l][3] = I.prm[l].base; q.dlv[l][0] = I.prm[l].w; q.dlv[l][1] = I.prm[l].h; q.dlv[l][2] = I.prm[l].pw; q.dlv[l][3] = I.prm[l].dbase; }
  auto b_q = H->upload(&q, sizeof q, wgpu::BufferUsage::Uniform);
  auto b_prev = H->upload(prev.data(), prev.size() * 8, wgpu::BufferUsage::Storage);
  auto b_next = H->upload(next.data(), next.size() * 8, wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);
  auto b_st = H->alloc(prev.size() * 4, wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);
  H->dispatch(p_lk, {I.img, J.img, I.der, b_prev, b_next, b_st, b_q}, (q.n + 31) / 32);
  auto st_n = H->alloc_staging_for_readback(prev.size() * 8), st_s = H->alloc_staging_for_readback(prev.size() * 4);
  H->copy_to_staging(b_next, st_n, prev.size() * 8); auto nb = H->readback(st_n, prev.size() * 8); memcpy(next.data(), nb.data(), prev.size() * 8);
  H->copy_to_staging(b_st, st_s, prev.size() * 4); auto sb = H->readback(st_s, prev.size() * 4); status.resize(prev.size()); memcpy(status.data(), sb.data(), prev.size() * 4);
}
static void report(const char* tag, const std::vector<Pt>& gpu, const std::vector<uint32_t>& gst, const std::vector<Pt>& cpu, const std::vector<int>& cst) {
  size_t exact = 0, st_ok = 0, close = 0; double maxd = 0; long first = -1;
  for (size_t i = 0; i < gpu.size(); ++i) {
    bool se = (gst[i] != 0) == (cst[i] != 0); st_ok += se;
    if (!cst[i] && !gst[i]) { ++exact; ++close; continue; }
    double d = std::max(fabs((double)gpu[i].x - cpu[i].x), fabs((double)gpu[i].y - cpu[i].y));
    if (se && gpu[i].x == cpu[i].x && gpu[i].y == cpu[i].y) ++exact; else if (first < 0) first = (long)i;
    if (se && d <= 1e-3) ++close; if (se) maxd = std::max(maxd, d);
  }
  printf("%s: n=%zu bit-exact=%zu within1e-3=%zu status-match=%zu maxdiff=%.3g", tag, gpu.size(), exact, close, st_ok, maxd);
  if (first >= 0) printf(" first_mismatch[%ld] gpu=(%.7g,%.7g,st%u) cpu=(%.7g,%.7g,st%d)", first, gpu[first].x, gpu[first].y, gst[first], cpu[first].x, cpu[first].y, cst[first]);
  printf("\n");
}
int main(int argc, char** argv) {
  if (argc < 6) { fprintf(stderr, "usage: probe <wgsl_dir> <img.u8> <ref_dir> <W> <H> [--cpu-pyr]\n"); return 1; }
  const std::string wdir = argv[1], imgp = argv[2], rdir = argv[3]; const uint32_t W = atoi(argv[4]), Hh = atoi(argv[5]);
  const bool cpu_pyr = argc > 6 && std::string(argv[6]) == "--cpu-pyr"; const bool cpu_l0 = argc > 6 && std::string(argv[6]) == "--cpu-l0";
  auto img = slurpb(imgp); auto nxt = slurpb(rdir + "/next_raw.u8");
  if (img.size() != size_t(W) * Hh || nxt.size() != img.size()) { fprintf(stderr, "img/next size mismatch\n"); return 1; }
  if (W % TILES || Hh % TILES) { fprintf(stderr, "requires W,H divisible by %d\n", TILES); return 1; }
  DawnKernelHarness h; if (!h.init()) { fprintf(stderr, "harness init failed\n"); return 2; } H = &h;
  const std::string common = slurp(wdir + "/lk_common.wgsl");
  auto pipe = [&](const char* name, bool with_common) { auto p = h.load_compute((with_common ? common : std::string()) + slurp(wdir + "/" + name + ".wgsl")); std::string e; if (!p || DawnKernelHarness::take_device_error(&e)) { fprintf(stderr, "load %s failed: %s\n", name, e.c_str()); exit(3); } return p; };
  p_hist = pipe("clahe_hist", true); p_lut = pipe("clahe_lut", true); p_interp = pipe("clahe_interp", true); p_pad = pipe("pad_reflect101", true); p_down = pipe("pyrdown", true); p_scharr = pipe("scharr", true); p_lk = pipe("lk_track", false);
  int rc = 0;
  Pyr I, J;
  if (cpu_pyr) { I = upload_cpu(rdir, "prev", W, Hh, true); J = upload_cpu(rdir, "next", W, Hh, true); printf("mode=cpu-pyr (CPU dumps uploaded; tests LK only)\n"); }
  else if (cpu_l0) { I = build_from_cpu_l0(rdir, "prev", W, Hh); J = build_from_cpu_l0(rdir, "next", W, Hh); printf("mode=cpu-l0 (CPU CLAHE uploaded; tests pad+pyrdown+scharr+LK)\n"); rc = std::max(rc, diff_pyr(I, rdir, "prev", false)); rc = std::max(rc, diff_pyr(J, rdir, "next", false)); }
  else {
    auto t0 = std::chrono::steady_clock::now();
    I = build_gpu(img, W, Hh); J = build_gpu(nxt, W, Hh);
    auto st = h.alloc_staging_for_readback(4); h.copy_to_staging(I.img, st, 4); h.readback(st, 4);
    auto t1 = std::chrono::steady_clock::now();
    std::string err; if (DawnKernelHarness::take_device_error(&err)) { fprintf(stderr, "DAWN ERROR: %s\n", err.c_str()); return 4; }
    printf("mode=gpu levels=%d gpu(2x clahe+pyr+scharr, 1 readback)=%.2fms\n", I.L, std::chrono::duration<double, std::milli>(t1 - t0).count());
    rc = std::max(rc, diff_pyr(I, rdir, "prev", true));
    { auto stl = h.alloc_staging_for_readback(TILES * TILES * 256 * 4); h.copy_to_staging(g_lut, stl, TILES * TILES * 256 * 4); auto lb = h.readback(stl, TILES * TILES * 256 * 4);
      std::ofstream f(rdir + "/gpu_lut.u32", std::ios::binary); f.write((const char*)lb.data(), lb.size()); }

  }
  // ── M3: LK forward + reverse vs lk_cpu.txt (p0 p1 st err pr str)
  std::vector<Pt> p0, p1, pr; std::vector<int> st, str; { std::ifstream f(rdir + "/lk_cpu.txt"); float ax, ay, bx, by, e, cx, cy; int s, sr; while (f >> ax >> ay >> bx >> by >> s >> e >> cx >> cy >> sr) { p0.push_back({ax, ay}); p1.push_back({bx, by}); st.push_back(s); pr.push_back({cx, cy}); str.push_back(sr); } }
  if (p0.empty()) { fprintf(stderr, "no lk_cpu.txt\n"); return 1; }
  std::vector<Pt> g1 = p0; std::vector<uint32_t> gs;
  run_lk(I, J, p0, g1, gs); g1 = p0;   // warm-up (pipeline/first-use costs)
  auto t2 = std::chrono::steady_clock::now(); run_lk(I, J, p0, g1, gs); auto t3 = std::chrono::steady_clock::now();
  std::string err; if (DawnKernelHarness::take_device_error(&err)) { fprintf(stderr, "DAWN ERROR (lk): %s\n", err.c_str()); return 4; }
  report("LK fwd ", g1, gs, p1, st);
  std::vector<Pt> gr = p0; std::vector<uint32_t> gsr; run_lk(J, I, p1, gr, gsr);   // reverse from CPU's p1 (same as XRSLAM: next_cvpoints -> back), isolates the reverse pass
  report("LK rev ", gr, gsr, pr, str);
  printf("lk fwd gpu time (incl. readback) = %.2fms for %zu pts\n", std::chrono::duration<double, std::milli>(t3 - t2).count(), p0.size());
  size_t ex = 0; for (size_t i = 0; i < p0.size(); ++i) if ((gs[i] != 0) == (st[i] != 0) && (!st[i] || (g1[i].x == p1[i].x && g1[i].y == p1[i].y))) ++ex;
  if (ex != p0.size()) rc = std::max(rc, 8);
  printf("rc=%d\n", rc); return rc;
}
