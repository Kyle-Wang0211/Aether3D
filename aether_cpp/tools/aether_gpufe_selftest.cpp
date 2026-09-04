// Self-test of pw_gpu_frontend against the OpenCV 4.0.1 CPU dumps (lk_cpu_ref + gftt_cpu_ref2 outputs).
#include "pw_gpu_frontend.h"
#include <chrono>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>
static std::vector<uint8_t> slurpb(const std::string& p) { std::ifstream f(p, std::ios::binary); std::stringstream s; s << f.rdbuf(); auto str = s.str(); return std::vector<uint8_t>(str.begin(), str.end()); }
int main(int argc, char** argv) {
  if (argc < 6) { fprintf(stderr, "usage: selftest <img.u8> <m2_dir> <gftt_clahe_dir> W H\n"); return 1; }
  const std::string imgp = argv[1], m2 = argv[2], gd = argv[3]; const int W = atoi(argv[4]), H = atoi(argv[5]);
  auto img = slurpb(imgp), nxt = slurpb(m2 + "/next_raw.u8"), clahe_ref = slurpb(m2 + "/prev_clahe.u8");
  std::string err; auto fe = pw::gpufe::FrontEnd::create(&err); if (!fe) { fprintf(stderr, "create failed: %s\n", err.c_str()); return 2; }
  printf("selfcheck: %s\n", fe->selfcheck().c_str());
  int rc = 0;
  std::vector<uint8_t> clahe; auto I = fe->preprocess(img.data(), W, H, W, 6.0, 8, 8, &clahe); auto J = fe->preprocess(nxt.data(), W, H, W, 6.0, 8, 8, nullptr);
  if (!I || !J) { fprintf(stderr, "preprocess failed: %s\n", fe->take_error().c_str()); return 3; }
  size_t bad = 0; for (size_t i = 0; i < clahe.size(); ++i) bad += clahe[i] != clahe_ref[i]; printf("clahe bytes mismatched=%zu/%zu\n", bad, clahe.size()); if (bad) rc = 5;
  std::vector<pw::gpufe::Keypoint> kp; if (!fe->detect(*I, 150, 1.0e-3, 20, 0.04, kp)) { fprintf(stderr, "detect: %s\n", fe->take_error().c_str()); return 4; }
  std::ifstream cf(gd + "/corners_cpu.txt"); std::vector<std::pair<int, int>> cpu; float x, y, v; while (cf >> x >> y >> v) cpu.push_back({(int)x, (int)y});
  size_t om = 0; for (size_t i = 0; i < std::min(cpu.size(), kp.size()); ++i) om += (cpu[i].first == (int)kp[i].x && cpu[i].second == (int)kp[i].y);
  printf("detect: gpu=%zu cpu=%zu ordered-match=%zu\n", kp.size(), cpu.size(), om); if (om != cpu.size() || kp.size() != cpu.size()) rc = 6;
  // LK vs lk_cpu.txt (p0 p1 st err pr str) — its p0 is the XRSLAM-path GFTT list on the CLAHE image
  std::vector<std::array<float, 2>> p0, p1, pr; std::vector<int> st, str; { std::ifstream f(m2 + "/lk_cpu.txt"); float ax, ay, bx, by, e, cx, cy; int s, sr; while (f >> ax >> ay >> bx >> by >> s >> e >> cx >> cy >> sr) { p0.push_back({ax, ay}); p1.push_back({bx, by}); st.push_back(s); pr.push_back({cx, cy}); str.push_back(sr); } }
  std::vector<std::array<float, 2>> g1 = p0; std::vector<uint8_t> gs; if (!fe->track(*I, *J, p0, g1, gs)) { fprintf(stderr, "track: %s\n", fe->take_error().c_str()); return 4; }
  size_t ex = 0; for (size_t i = 0; i < p0.size(); ++i) ex += ((gs[i] != 0) == (st[i] != 0)) && (!st[i] || (g1[i][0] == p1[i][0] && g1[i][1] == p1[i][1]));
  std::vector<std::array<float, 2>> gr = p0; std::vector<uint8_t> gsr; fe->track(*J, *I, p1, gr, gsr);
  size_t exr = 0; for (size_t i = 0; i < p0.size(); ++i) exr += ((gsr[i] != 0) == (str[i] != 0)) && (!str[i] || (gr[i][0] == pr[i][0] && gr[i][1] == pr[i][1]));
  printf("track fwd bit-exact=%zu/%zu rev=%zu/%zu\n", ex, p0.size(), exr, p0.size()); if (ex != p0.size() || exr != p0.size()) rc = 7;
  { std::vector<std::array<float, 2>> n2 = p0, r2 = p0; std::vector<uint8_t> s2, sr2; if (!fe->track_fwd_rev(*I, *J, p0, n2, s2, r2, sr2)) { fprintf(stderr, "track_fwd_rev: %s\n", fe->take_error().c_str()); return 4; }
    size_t e2 = 0, e3 = 0; for (size_t i = 0; i < p0.size(); ++i) { e2 += ((s2[i] != 0) == (st[i] != 0)) && (!st[i] || (n2[i][0] == p1[i][0] && n2[i][1] == p1[i][1])); e3 += ((sr2[i] != 0) == (str[i] != 0)) && (!str[i] || (r2[i][0] == pr[i][0] && r2[i][1] == pr[i][1])); }
    printf("track_fwd_rev bit-exact fwd=%zu/%zu rev=%zu/%zu\n", e2, p0.size(), e3, p0.size()); if (e2 != p0.size() || e3 != p0.size()) rc = 8; }
  // pipelined path: submit async, burn CPU time, finish -> must equal the synchronous results and wait ~0
  { auto t0 = std::chrono::steady_clock::now(); auto F = fe->preprocess_async(nxt.data(), W, H, W, 6.0, 8, 8, true); auto t1 = std::chrono::steady_clock::now();
    volatile double burn = 0; for (int i = 0; i < 30000000; ++i) burn += i * 1e-9;   // ~15+ ms of CPU work
    std::vector<uint8_t> c2; bool ok = fe->finish(*F, &c2); auto t2 = std::chrono::steady_clock::now();
    std::vector<pw::gpufe::Keypoint> k2; fe->detect(*F, 150, 1e-3, 20, 0.04, k2);
    std::vector<std::array<float, 2>> n2 = p0, r2 = p0; std::vector<uint8_t> s2, sr2; fe->track_fwd_rev(*I, *F, p0, n2, s2, r2, sr2);
    auto cn = slurpb(m2 + "/next_clahe.u8"); size_t badc = 0; for (size_t i = 0; i < c2.size() && i < cn.size(); ++i) badc += c2[i] != cn[i];
    size_t e2 = 0; for (size_t i = 0; i < p0.size(); ++i) e2 += ((s2[i] != 0) == (st[i] != 0)) && (!st[i] || (n2[i][0] == p1[i][0] && n2[i][1] == p1[i][1]));
    auto sA = fe->stats();
    printf("async: submit %.2f ms, finish wait %.2f ms (stats pre_wait %.2f) ok=%d clahe_bad=%zu track_exact=%zu/%zu\n", std::chrono::duration<double, std::milli>(t1 - t0).count(), std::chrono::duration<double, std::milli>(t2 - t1).count(), sA.pre_wait_ms, (int)ok, badc, e2, p0.size());
    if (!ok || badc || e2 != p0.size()) rc = 9; }
  { auto F = fe->preprocess_detect_async(img.data(), W, H, W, 6.0, 8, 8, 1e-3, 0.04); std::vector<uint8_t> c3; bool ok = F && fe->finish(*F, &c3);
    std::vector<pw::gpufe::Keypoint> k3; if (ok) ok = fe->detect(*F, 150, 1e-3, 20, 0.04, k3);
    size_t om = 0; for (size_t i = 0; i < std::min(cpu.size(), k3.size()); ++i) om += (cpu[i].first == (int)k3[i].x && cpu[i].second == (int)k3[i].y);
    size_t bc = 0; for (size_t i = 0; i < c3.size(); ++i) bc += c3[i] != clahe_ref[i];
    printf("fused clahe+detect: ok=%d clahe_bad=%zu ordered-match=%zu/%zu\n", (int)ok, bc, om, cpu.size()); if (!ok || bc || om != cpu.size()) rc = 10; }
  { std::vector<uint8_t> pk; auto F = fe->preprocess_detect(img.data(), W, H, W, 6.0, 8, 8, 1.0e-3, 0.04, &pk, true); std::vector<pw::gpufe::PyrLevel> lay;
    bool ok = F && fe->pyramid_layout(*F, lay); size_t bad = 0, tot = 0;
    for (size_t l = 0; ok && l < lay.size(); ++l) { auto ref = slurpb(m2 + "/prev_L" + std::to_string(l) + "_pad.u8"); const auto& q = lay[l];
      if (ref.size() != size_t(q.pw) * q.ph) { printf("  level %zu: ref size %zu != %d*%d\n", l, ref.size(), q.pw, q.ph); ok = false; break; }
      for (int y = 0; y < q.ph; ++y) for (int x = 0; x < q.pw; ++x) { ++tot; bad += pk[(size_t(q.base) + size_t(y) * q.pwq) * 4 + x] != ref[size_t(y) * q.pw + x]; } }
    std::vector<pw::gpufe::Keypoint> k2; if (ok) ok = fe->detect(*F, 150, 1.0e-3, 20, 0.04, k2); size_t om = 0; for (size_t i = 0; i < std::min(cpu.size(), k2.size()); ++i) om += (cpu[i].first == (int)k2[i].x && cpu[i].second == (int)k2[i].y);
    printf("gpu pyramid readback: ok=%d levels=%zu padded bytes mismatched=%zu/%zu detect ordered-match=%zu/%zu\n", (int)ok, lay.size(), bad, tot, om, cpu.size()); if (!ok || bad || om != cpu.size()) rc = 11; }
  // steady-state timing: 10 more frames
  { std::vector<std::array<float, 2>> r2 = p0; std::vector<uint8_t> sr2; std::shared_ptr<pw::gpufe::Frame> prevF = I;
    for (int i = 0; i < 20; ++i) { auto F = fe->preprocess(nxt.data(), W, H, W, 6.0, 8, 8, &clahe); fe->detect(*F, 150, 1e-3, 20, 0.04, kp); g1 = p0; r2 = p0; fe->track_fwd_rev(*prevF, *F, p0, g1, gs, r2, sr2); prevF = F; } }
  printf("gpu_kernel_ms: %s\n", fe->kernel_times().c_str());
  auto s = fe->stats(); printf("avg ms: preprocess=%.2f detect=%.2f track=%.2f (n=%llu/%llu/%llu)\n", s.preprocess_ms / s.n_preprocess, s.detect_ms / s.n_detect, s.track_ms / s.n_track, (unsigned long long)s.n_preprocess, (unsigned long long)s.n_detect, (unsigned long long)s.n_track);
  printf("rc=%d\n", rc); return rc;
}
