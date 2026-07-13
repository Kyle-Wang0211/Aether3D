// mirror_cull_cap50_test.cc — host test for aether_mirror_cull on the cap50
// device cloud. PROVES the multi-evidence conjunction correctly ABSTAINS on the
// "真玻璃门/走廊簇"(candidate B):删真门洞=0。既是功能测试也是【误伤护栏生效】
// 的证据。此测试【不启用生产删门、不装机、不 wire 进交付路径】。
//
// 数据(scratchpad,来自 cap50 真机 pull):
//   sfm_sparse.ply(92849 点,float xyz + uchar rgb) + ghost_view_mask.bin
//   (每点 flag:band15=0x02 cell_ghost=0x04 band10=0x10 rescued=0x20) +
//   ghost_mask.json(plane_n=重力/地板法向) + sfm_sparse_meta.json(相机位姿)。
//
// 候选(B)= 后墙外墙高真点(real ∧ sd>0.3m ∧ Z<−4.2m):对抗复核认定的"看着像
// 8.1σ 镜面、实为真玻璃门通相邻走廊"的簇。期望:模块 ABSTAIN → n_deleted=0。
//
// Build(standalone,不进 CMakeLists):
//   clang++ -std=c++17 -O2 -ffp-contract=off -I <repo>/aether_cpp/third_party/eigen \
//       -o mirror_cull_cap50_test \
//       bench/mirror_cull_cap50_test.cc bench/aether_mirror_cull.cc
// Run:
//   mirror_cull_cap50_test <cap50_pull_dir> <cap50_diag_dir>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

#include "aether_mirror_cull.h"

namespace {

std::string ReadFile(const std::string& path) {
  std::ifstream f(path, std::ios::binary);
  if (!f) {
    std::fprintf(stderr, "FATAL: cannot open %s\n", path.c_str());
    std::exit(2);
  }
  return std::string((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
}

// 解析 "key":[a,b,c,...] 后的 n 个 double(从 blob 中 pos 之后第一处出现的 key)。
size_t FindKey(const std::string& s, const std::string& key, size_t from) {
  size_t p = s.find("\"" + key + "\"", from);
  return p;
}

// 从 '[' 之后连读 count 个浮点数。返回 ']' 之后位置。
size_t ReadArray(const std::string& s, size_t bracket, std::vector<double>* out, int count) {
  size_t i = bracket + 1;
  out->clear();
  while (out->size() < static_cast<size_t>(count)) {
    // 跳过非数字字符。
    while (i < s.size() && (s[i] == ' ' || s[i] == ',' || s[i] == '\n' || s[i] == '\t')) ++i;
    char* end = nullptr;
    double v = std::strtod(s.c_str() + i, &end);
    if (end == s.c_str() + i) break;
    out->push_back(v);
    i = end - s.c_str();
  }
  size_t rb = s.find(']', i);
  return rb == std::string::npos ? i : rb + 1;
}

double Percentile(std::vector<double> v, double q) {
  std::sort(v.begin(), v.end());
  if (v.empty()) return 0.0;
  const double idx = (q / 100.0) * (v.size() - 1);
  const size_t lo = static_cast<size_t>(std::floor(idx));
  const size_t hi = static_cast<size_t>(std::ceil(idx));
  if (lo == hi) return v[lo];
  const double frac = idx - lo;
  return v[lo] * (1.0 - frac) + v[hi] * frac;
}

// 复刻 glass_recon.py 的 robust_floor_level(与 quant candidate 构造逐字一致)。
double RobustFloorLevel(const std::vector<double>& h, double tol = 0.015) {
  const double lo = Percentile(h, 0.5), hi = Percentile(h, 99.5);
  std::vector<double> cand;
  for (double c = lo; c < lo + 0.45 * (hi - lo); c += 0.005) cand.push_back(c);
  std::vector<long> counts(cand.size(), 0);
  long cmax = 1;
  for (size_t k = 0; k < cand.size(); ++k) {
    long cnt = 0;
    for (double x : h)
      if (std::abs(x - cand[k]) < tol) ++cnt;
    counts[k] = cnt;
    cmax = std::max(cmax, cnt);
  }
  size_t li = 0;
  for (size_t k = 0; k < counts.size(); ++k)
    if (counts[k] >= static_cast<long>(0.60 * cmax)) {
      li = k;
      break;
    }
  const double c0 = cand[li];
  double sum = 0;
  long n = 0;
  for (double x : h)
    if (std::abs(x - c0) < tol) {
      sum += x;
      ++n;
    }
  return n > 0 ? sum / n : c0;
}

void QuatWxyzToR(const double q[4], double R[9]) {
  double w = q[0], x = q[1], y = q[2], z = q[3];
  const double nrm = std::sqrt(w * w + x * x + y * y + z * z);
  w /= nrm; x /= nrm; y /= nrm; z /= nrm;
  R[0] = 1 - 2 * (y * y + z * z); R[1] = 2 * (x * y - w * z);     R[2] = 2 * (x * z + w * y);
  R[3] = 2 * (x * y + w * z);     R[4] = 1 - 2 * (x * x + z * z); R[5] = 2 * (y * z - w * x);
  R[6] = 2 * (x * z - w * y);     R[7] = 2 * (y * z + w * x);     R[8] = 1 - 2 * (x * x + y * y);
}

}  // namespace

int main(int argc, char** argv) {
  const std::string pull = argc > 1 ? argv[1] : ".";
  const std::string diag = argc > 2 ? argv[2] : ".";

  // ── 载入 PLY(xyz float32 → double, rgb uchar)────────────────────────────
  const std::string ply = ReadFile(pull + "/sfm_sparse.ply");
  const size_t he = ply.find("end_header\n") + std::string("end_header\n").size();
  const size_t nbytes = ply.size() - he;
  const int N = static_cast<int>(nbytes / 15);
  std::vector<double> xyz(3 * N);
  std::vector<uint8_t> rgb(3 * N);
  const uint8_t* body = reinterpret_cast<const uint8_t*>(ply.data() + he);
  for (int i = 0; i < N; ++i) {
    float f[3];
    std::memcpy(f, body + i * 15, 12);
    for (int c = 0; c < 3; ++c) xyz[3 * i + c] = static_cast<double>(f[c]);
    for (int c = 0; c < 3; ++c) rgb[3 * i + c] = body[i * 15 + 12 + c];
  }

  // ── 载入 ghost_view_mask.bin(每点 flag)──────────────────────────────────
  const std::string flags = ReadFile(pull + "/ghost_view_mask.bin");
  if (static_cast<int>(flags.size()) != N) {
    std::fprintf(stderr, "FATAL: flag count %zu != point count %d\n", flags.size(), N);
    return 2;
  }
  const uint8_t* fl = reinterpret_cast<const uint8_t*>(flags.data());

  // ── 载入 ghost_mask.json → plane_n(重力 up)──────────────────────────────
  const std::string gj = ReadFile(diag + "/ghost_mask.json");
  std::vector<double> pn;
  {
    size_t k = FindKey(gj, "plane_n", 0);
    size_t br = gj.find('[', k);
    ReadArray(gj, br, &pn, 3);
  }
  double up[3] = {pn[0], pn[1], pn[2]};
  const double upn = std::sqrt(up[0] * up[0] + up[1] * up[1] + up[2] * up[2]);
  for (int c = 0; c < 3; ++c) up[c] /= upn;

  // ── 载入 meta poses → 相机中心 C = −Rᵀt(仅 registered)──────────────────
  const std::string mj = ReadFile(diag + "/sfm_sparse_meta.json");
  std::vector<double> cam;  // 3 * n_cam
  {
    size_t pos = 0;
    while (true) {
      size_t rk = FindKey(mj, "registered", pos);
      if (rk == std::string::npos) break;
      size_t colon = mj.find(':', rk);
      bool reg = mj.compare(colon + 1, 4, "true") == 0;
      size_t qk = FindKey(mj, "quat_wxyz", colon);
      if (qk == std::string::npos) break;
      size_t qbr = mj.find('[', qk);
      std::vector<double> q;
      size_t after = ReadArray(mj, qbr, &q, 4);
      size_t tk = FindKey(mj, "t", after);
      size_t tbr = mj.find('[', tk);
      std::vector<double> t;
      ReadArray(mj, tbr, &t, 3);
      pos = tbr + 1;
      if (!reg || q.size() < 4 || t.size() < 3) continue;
      double R[9];
      QuatWxyzToR(q.data(), R);
      // C = -R^T t
      double C[3];
      for (int r = 0; r < 3; ++r)
        C[r] = -(R[r] * t[0] + R[3 + r] * t[1] + R[6 + r] * t[2]);
      cam.push_back(C[0]);
      cam.push_back(C[1]);
      cam.push_back(C[2]);
    }
  }
  const int n_cam = static_cast<int>(cam.size() / 3);

  // ── 派生:sd = xyz·up − floor_level;real = ¬(band15|cell_ghost|band10)────
  std::vector<double> h(N);
  for (int i = 0; i < N; ++i)
    h[i] = xyz[3 * i] * up[0] + xyz[3 * i + 1] * up[1] + xyz[3 * i + 2] * up[2];
  const double lvl = RobustFloorLevel(h);

  auto is_real = [&](int i) {
    const uint8_t f = fl[i];
    const bool ghost = (f & 0x02) || (f & 0x04) || (f & 0x10);
    return !ghost;
  };

  // 候选(B):real ∧ sd>0.3 ∧ Z(axis 2)<−4.2 —— 后墙外墙高真点(真门洞/走廊簇)。
  // 目标:real ∧ sd>0.3 —— 房内真墙结构。
  std::vector<double> cand_xyz, target_xyz;
  std::vector<uint8_t> cand_rgb, target_rgb, cand_flags;
  for (int i = 0; i < N; ++i) {
    if (!is_real(i)) continue;
    const double sd = h[i] - lvl;
    if (sd <= 0.3) continue;
    target_xyz.push_back(xyz[3 * i]);
    target_xyz.push_back(xyz[3 * i + 1]);
    target_xyz.push_back(xyz[3 * i + 2]);
    target_rgb.push_back(rgb[3 * i]);
    target_rgb.push_back(rgb[3 * i + 1]);
    target_rgb.push_back(rgb[3 * i + 2]);
    if (xyz[3 * i + 2] < -4.2) {
      cand_xyz.push_back(xyz[3 * i]);
      cand_xyz.push_back(xyz[3 * i + 1]);
      cand_xyz.push_back(xyz[3 * i + 2]);
      cand_rgb.push_back(rgb[3 * i]);
      cand_rgb.push_back(rgb[3 * i + 1]);
      cand_rgb.push_back(rgb[3 * i + 2]);
      cand_flags.push_back(fl[i]);
    }
  }
  const int n_cand = static_cast<int>(cand_xyz.size() / 3);
  const int n_real = static_cast<int>(target_xyz.size() / 3);

  std::printf("== cap50 mirror-cull ABSTAIN test ==\n");
  std::printf("points=%d  cameras=%d  floor_lvl=%.4f  up=[%.4f,%.4f,%.4f]\n", N, n_cam, lvl,
              up[0], up[1], up[2]);
  std::printf("candidate(B) n=%d  target(wall) n=%d\n", n_cand, n_real);
  if (n_cand < 50 || n_real < 100 || n_cam < 1) {
    std::fprintf(stderr, "FATAL: cap50 candidate/target/camera set unexpectedly small\n");
    return 2;
  }

  aether::mirror::MirrorCullInput in;
  in.cand_xyz = cand_xyz.data();
  in.cand_rgb = cand_rgb.data();
  in.cand_flags = cand_flags.data();
  in.n_cand = n_cand;
  in.real_xyz = target_xyz.data();
  in.real_rgb = target_rgb.data();
  in.n_real = n_real;
  in.cam_xyz = cam.data();
  in.n_cam = n_cam;
  for (int c = 0; c < 3; ++c) in.up[c] = up[c];

  aether::mirror::MirrorCullConfig cfg;  // 全默认(物理容差)。
  int failures = 0;

  // ── TEST 1:env 未设 → 硬 no-op(默认关铁律)────────────────────────────
  unsetenv("AETHER_MIRROR_DELETE");
  {
    aether::mirror::MirrorCullStats st;
    auto del = aether::mirror::ArbitrateMirrorCull(in, cfg, &st);
    const bool ok = del.empty() && st.n_deleted == 0 && !st.env_enabled && !st.plane_found;
    std::printf("\n[TEST 1] env unset → hard no-op\n");
    std::printf("  env_enabled=%d  plane_found=%d  n_deleted=%d  reason='%s'\n", st.env_enabled,
                st.plane_found, st.n_deleted, st.abstain_reason);
    std::printf("  %s\n", ok ? "PASS (default off, display-only, zero analysis)" : "FAIL");
    if (!ok) ++failures;
  }

  // ── TEST 2:env=1 强制运行分析 → 仍 ABSTAIN(证据合取否决)────────────────
  setenv("AETHER_MIRROR_DELETE", "1", 1);
  {
    aether::mirror::MirrorCullStats st;
    auto del = aether::mirror::ArbitrateMirrorCull(in, cfg, &st);
    std::printf("\n[TEST 2] AETHER_MIRROR_DELETE=1 → run full analysis, expect ABSTAIN\n");
    std::printf("  plane_n=[%.4f,%.4f,%.4f] d=%.4f  |n·up|=%.4f (sin15=%.4f)\n", st.plane_n[0],
                st.plane_n[1], st.plane_n[2], st.plane_d,
                std::abs(st.plane_n[0] * up[0] + st.plane_n[1] * up[1] + st.plane_n[2] * up[2]),
                cfg.normal_horiz_sin);
    std::printf("  sym_support=%.1f%% (@eps=%.0fcm, need>=%.0f%%)  color_consistent=%.1f%% "
                "(need>=%.0f%%)\n",
                st.sym_support_frac * 100.0, cfg.eps_sym_m * 100.0,
                cfg.min_sym_support_frac * 100.0, st.color_consistent_frac * 100.0,
                cfg.min_color_consistent_frac * 100.0);
    std::printf("  footprint=%.2fx%.2fm  wall=%.2fx%.2fm  (bounded-frame needs <%.2fm & <%.0f%% "
                "wall)\n",
                st.footprint_u_m, st.footprint_v_m, st.wall_u_m, st.wall_v_m,
                cfg.frame_max_extent_m, cfg.frame_max_wall_frac * 100.0);
    std::printf("  cameras room-side=%d ghost-side=%d  real_self_sym_baseline=%.1f%%\n",
                st.cam_room_side, st.cam_ghost_side, st.real_self_symmetry_baseline * 100.0);
    std::printf("  GATES: normal_h=%d  symmetry=%d  color=%d  bounded_frame=%d  ghost_no_cam=%d  "
                "self_margin=%d\n",
                st.gate_normal_horizontal, st.gate_symmetry_support, st.gate_color_consistency,
                st.gate_bounded_frame, st.gate_ghost_no_camera, st.gate_self_symmetry_margin);
    std::printf("  n_sym_inlier=%d  n_confirmed_mirror=%d  n_exempted_rescue=%d  n_deleted=%d\n",
                st.n_sym_inlier, st.n_confirmed_mirror, st.n_exempted_rescue, st.n_deleted);
    std::printf("  reason='%s'\n", st.abstain_reason);

    // 主断言:误删真门洞 = 0。
    const bool abstained = del.empty() && st.n_deleted == 0 && !st.all_plane_gates_passed;
    std::printf("  [ASSERT] n_deleted==0 (误删真门洞=0): %s\n", abstained ? "PASS" : "FAIL");
    if (!abstained) ++failures;

    // 护栏证据:证明这是【稳健】abstain —— 多条独立门各自否决,而非侥幸。
    // 会被后墙几何骗过的两门(法向水平 + 鬼侧无相机)本会放行;是合取里的其余
    // 门(紧对称 / 颜色 / 有界镜框)各自 veto,才守住误伤=0。
    const bool fooled_gates_pass = st.gate_normal_horizontal && st.gate_ghost_no_camera;
    const bool veto_symmetry = !st.gate_symmetry_support;
    const bool veto_color = !st.gate_color_consistency;
    const bool veto_bounded = !st.gate_bounded_frame;
    std::printf("  [ASSERT] 单信号会被骗的门(normal_h & ghost_no_cam)确会放行: %s\n",
                fooled_gates_pass ? "PASS" : "FAIL");
    std::printf("  [ASSERT] 紧对称门 veto: %s\n", veto_symmetry ? "PASS" : "FAIL");
    std::printf("  [ASSERT] 颜色门 veto: %s\n", veto_color ? "PASS" : "FAIL");
    std::printf("  [ASSERT] 有界镜框门 veto(满墙铺开): %s\n", veto_bounded ? "PASS" : "FAIL");
    if (!fooled_gates_pass) ++failures;
    if (!veto_symmetry) ++failures;
    if (!veto_color) ++failures;
    if (!veto_bounded) ++failures;
  }

  // ── TEST 3:合成【干净有界镜子】正对照 —— 证明护栏【有判别力】,不是恒 abstain。
  // 若模块对任何输入都返回空,则 cap50 的 abstain 毫无意义。这里造一面理想镜子
  // (稠密忠实反射 + 颜色匹配 + 足迹紧致 + 相机全在一侧),模块【应当】确认删除。
  // 仅合成数据,不碰任何生产/交付点云。
  {
    std::vector<double> sc, sr, scam;  // syn cand xyz / real xyz / cam
    std::vector<uint8_t> sc_rgb, sr_rgb;
    uint32_t seed = 12345;
    auto rnd = [&]() {  // 确定性 LCG ∈ [0,1)
      seed = seed * 1664525u + 1013904223u;
      return (seed >> 8) / 16777216.0;
    };
    const double mo = 1.0;  // 镜面 x = 1.0,法向 +X
    // 家具:房间侧小簇(x<1),200 点,足迹 ~0.3m。
    for (int k = 0; k < 200; ++k) {
      const double x = 0.60 + (rnd() - 0.5) * 0.30;
      const double y = 1.00 + (rnd() - 0.5) * 0.30;
      const double z = -0.50 + (rnd() - 0.5) * 0.30;
      const uint8_t cr = static_cast<uint8_t>(40 + 200 * rnd());
      const uint8_t cg = static_cast<uint8_t>(40 + 200 * rnd());
      const uint8_t cb = static_cast<uint8_t>(40 + 200 * rnd());
      sr.push_back(x); sr.push_back(y); sr.push_back(z);
      sr_rgb.push_back(cr); sr_rgb.push_back(cg); sr_rgb.push_back(cb);
      // 虚像 = 关于 x=1 的镜像(x' = 2·mo − x),颜色一致 → 候选删点。
      sc.push_back(2.0 * mo - x); sc.push_back(y); sc.push_back(z);
      sc_rgb.push_back(cr); sc_rgb.push_back(cg); sc_rgb.push_back(cb);
    }
    // 大墙:提供大 wall-span 且不关于 x=1 自对称(z=−2, x∈[−1,0.9]),800 点。
    for (int k = 0; k < 800; ++k) {
      const double x = -1.0 + 1.9 * rnd();
      const double y = 0.0 + 2.5 * rnd();
      sr.push_back(x); sr.push_back(y); sr.push_back(-2.0);
      sr_rgb.push_back(128); sr_rgb.push_back(128); sr_rgb.push_back(128);
    }
    // 相机:全在房间侧 x<1。
    for (int k = 0; k < 5; ++k) {
      scam.push_back(-0.5 + 0.25 * k); scam.push_back(1.0); scam.push_back(0.0);
    }
    aether::mirror::MirrorCullInput syn;
    syn.cand_xyz = sc.data(); syn.cand_rgb = sc_rgb.data(); syn.n_cand = 200;
    syn.real_xyz = sr.data(); syn.real_rgb = sr_rgb.data();
    syn.n_real = static_cast<int>(sr.size() / 3);
    syn.cam_xyz = scam.data(); syn.n_cam = 5;
    syn.up[0] = 0.0; syn.up[1] = 1.0; syn.up[2] = 0.0;

    aether::mirror::MirrorCullConfig cfg3;
    aether::mirror::MirrorCullStats st;
    auto del = aether::mirror::ArbitrateMirrorCull(syn, cfg3, &st);  // env 仍=1
    std::printf("\n[TEST 3] synthetic CLEAN bounded mirror → expect CONFIRM (delete)\n");
    std::printf("  DBG plane_n=[%.4f,%.4f,%.4f] d=%.4f\n", st.plane_n[0], st.plane_n[1],
                st.plane_n[2], st.plane_d);
    std::printf("  GATES: normal_h=%d symmetry=%d(%.1f%%) color=%d(%.1f%%) bounded_frame=%d"
                "(%.2fx%.2fm/wall %.2fx%.2fm) ghost_no_cam=%d self_margin=%d(base %.1f%%)\n",
                st.gate_normal_horizontal, st.gate_symmetry_support, st.sym_support_frac * 100.0,
                st.gate_color_consistency, st.color_consistent_frac * 100.0, st.gate_bounded_frame,
                st.footprint_u_m, st.footprint_v_m, st.wall_u_m, st.wall_v_m,
                st.gate_ghost_no_camera, st.gate_self_symmetry_margin,
                st.real_self_symmetry_baseline * 100.0);
    std::printf("  n_confirmed_mirror=%d  n_deleted=%d  reason='%s'\n", st.n_confirmed_mirror,
                st.n_deleted, st.abstain_reason);
    const bool confirmed = st.all_plane_gates_passed && st.n_deleted > 0 &&
                           static_cast<int>(del.size()) == st.n_deleted;
    std::printf("  [ASSERT] 干净镜子会被确认删除(护栏有判别力,非恒 abstain): %s\n",
                confirmed ? "PASS" : "FAIL");
    if (!confirmed) ++failures;
  }

  std::printf("\n=== %s (failures=%d) ===\n", failures == 0 ? "ALL PASS" : "FAILED", failures);
  return failures == 0 ? 0 : 1;
}
