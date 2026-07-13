// aether_mirror_cull.cc — implementation of the glass "mirror world" cull.
// 🔴 真删=有损=不可逆。默认关(AETHER_MIRROR_DELETE)。cap50 未验证误伤=0。
//    未启用、未装机、未 wire 进交付路径。详见 aether_mirror_cull.h 顶部铁律。
//
// 纯 C++/CPU。依赖 Eigen(MPL2)+ 本文件内置的紧凑静态 3D KD-tree(生产可原样
// 换 nanoflann BSD-2,接口等价:query nearest → (dist, index))。fp-contract 建
// 议关(-ffp-contract=off);本模块不承诺逐位 parity(几何容差判据,非统计带),
// 但阈值全是物理量,run-to-run 稳定。

#include "aether_mirror_cull.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>

#include <Eigen/Dense>

namespace aether {
namespace mirror {

namespace {

using Vec3 = Eigen::Vector3d;

// ── 内置紧凑静态 3D KD-tree(median-split, nth_element build)──────────────────
// 仅用于最近邻查询。生产可换 nanoflann(BSD-2)。点数量级(候选~1e2,目标~1e5)
// 下,树高 O(log n)、查询 O(log n),host 轻活足够。
class KdTree3 {
 public:
  explicit KdTree3(const std::vector<Vec3>& pts) : pts_(pts) {
    const int n = static_cast<int>(pts.size());
    idx_.resize(n);
    for (int i = 0; i < n; ++i) idx_[i] = i;
    if (n > 0) Build(0, n, 0);
  }

  // 返回最近邻在 pts_ 中的索引;out_dist2 = 平方距离。空树返回 -1。
  int Nearest(const Vec3& q, double* out_dist2) const {
    int best = -1;
    double best_d2 = std::numeric_limits<double>::infinity();
    if (!idx_.empty()) Query(0, static_cast<int>(idx_.size()), 0, q, &best, &best_d2);
    if (out_dist2) *out_dist2 = best_d2;
    return best;
  }

 private:
  void Build(int lo, int hi, int depth) {
    if (hi - lo <= 1) return;
    const int axis = depth % 3;
    const int mid = lo + (hi - lo) / 2;
    std::nth_element(idx_.begin() + lo, idx_.begin() + mid, idx_.begin() + hi,
                     [&](int a, int b) { return pts_[a][axis] < pts_[b][axis]; });
    Build(lo, mid, depth + 1);
    Build(mid + 1, hi, depth + 1);
  }

  void Query(int lo, int hi, int depth, const Vec3& q, int* best, double* best_d2) const {
    if (hi - lo <= 0) return;
    const int axis = depth % 3;
    const int mid = lo + (hi - lo) / 2;
    const int p = idx_[mid];
    const double d2 = (pts_[p] - q).squaredNorm();
    if (d2 < *best_d2) {
      *best_d2 = d2;
      *best = p;
    }
    const double diff = q[axis] - pts_[p][axis];
    const int near_lo = diff < 0.0 ? lo : mid + 1;
    const int near_hi = diff < 0.0 ? mid : hi;
    const int far_lo = diff < 0.0 ? mid + 1 : lo;
    const int far_hi = diff < 0.0 ? hi : mid;
    Query(near_lo, near_hi, depth + 1, q, best, best_d2);
    if (diff * diff < *best_d2) Query(far_lo, far_hi, depth + 1, q, best, best_d2);
  }

  const std::vector<Vec3>& pts_;
  std::vector<int> idx_;
};

Vec3 RowVec(const double* base, int i) {
  return Vec3(base[3 * i + 0], base[3 * i + 1], base[3 * i + 2]);
}

// Householder 反射:竖直平面 n·x = o(n 单位、水平)。x' = x − 2(n·x − o)n。
Vec3 Reflect(const Vec3& x, const Vec3& n, double o) {
  return x - 2.0 * (n.dot(x) - o) * n;
}

void SetReason(MirrorCullStats* s, const char* msg) {
  if (!s) return;
  std::snprintf(s->abstain_reason, sizeof(s->abstain_reason), "%s", msg);
}

}  // namespace

std::vector<int> ArbitrateMirrorCull(const MirrorCullInput& in,
                                     const MirrorCullConfig& cfg,
                                     MirrorCullStats* stats) {
  MirrorCullStats local;
  MirrorCullStats* s = stats ? stats : &local;
  *s = MirrorCullStats{};
  s->n_cand = in.n_cand;

  // ── 铁律①:env 硬门。不设 / !="1" → 硬 no-op,连分析都不跑(零 ship 影响)──
  if (cfg.require_env_gate) {
    const char* e = std::getenv("AETHER_MIRROR_DELETE");
    s->env_enabled = (e != nullptr && e[0] == '1' && e[1] == '\0');
    if (!s->env_enabled) {
      SetReason(s, "disabled: AETHER_MIRROR_DELETE != 1 (default no-op, display-only)");
      return {};  // 不删任何点。
    }
  } else {
    s->env_enabled = true;  // 仅 host 测试/评审可显式绕过 env 门(仍受全部证据门约束)。
  }

  if (in.n_cand <= 0 || in.n_real <= 0 || in.cand_xyz == nullptr || in.real_xyz == nullptr) {
    SetReason(s, "abstain: empty candidate or target set");
    return {};
  }

  // 重力 up、平面内正交基 e1/e2(与设计一致:e1=离 up 最远的世界轴投影正交化)。
  Vec3 up(in.up[0], in.up[1], in.up[2]);
  up.normalize();
  int ref_axis = 0;
  {
    double best = std::numeric_limits<double>::infinity();
    for (int a = 0; a < 3; ++a) {
      const double c = std::abs(up[a]);
      if (c < best) {
        best = c;
        ref_axis = a;
      }
    }
  }
  Vec3 e1 = Vec3::Unit(ref_axis);
  e1 = e1 - (e1.dot(up)) * up;
  e1.normalize();
  Vec3 e2 = up.cross(e1);

  // 目标真簇 → KD-tree。
  std::vector<Vec3> real_pts(in.n_real);
  for (int i = 0; i < in.n_real; ++i) real_pts[i] = RowVec(in.real_xyz, i);
  KdTree3 tree(real_pts);

  std::vector<Vec3> cand_pts(in.n_cand);
  for (int i = 0; i < in.n_cand; ++i) cand_pts[i] = RowVec(in.cand_xyz, i);

  // ── 反射平面检测:重力锁定 → 法向 = cosθ·e1 + sinθ·e2,搜索空间近一维 ──────
  // 目标:最大化"候选反射后落在真簇 plane_find_tol 内"的比例。松容差先锁面,严
  // 判据(eps_sym)留给下游门。这是 Podolak/Mitra 2006 PRST 的重力约束特例。
  const double eps2 = cfg.eps_sym_m * cfg.eps_sym_m;
  const double find_tol2 = cfg.plane_find_tol_m * cfg.plane_find_tol_m;
  const double dtheta = cfg.sweep_angle_step_deg * M_PI / 180.0;

  double best_hit = -1.0;
  double best_theta = 0.0, best_o = 0.0;
  Vec3 best_n = e1;
  for (double theta = 0.0; theta < M_PI; theta += dtheta) {
    const Vec3 n = std::cos(theta) * e1 + std::sin(theta) * e2;
    // 偏移扫描范围 = 候选∪目标沿 n 的投影跨度。
    double omin = std::numeric_limits<double>::infinity();
    double omax = -std::numeric_limits<double>::infinity();
    for (const auto& p : cand_pts) {
      const double t = n.dot(p);
      omin = std::min(omin, t);
      omax = std::max(omax, t);
    }
    for (const auto& p : real_pts) {
      const double t = n.dot(p);
      omin = std::min(omin, t);
      omax = std::max(omax, t);
    }
    for (double o = omin; o <= omax + 1e-9; o += cfg.sweep_offset_step_m) {
      int hit = 0;
      for (const auto& p : cand_pts) {
        double d2;
        tree.Nearest(Reflect(p, n, o), &d2);
        if (d2 < find_tol2) ++hit;
      }
      const double frac = static_cast<double>(hit) / in.n_cand;
      if (frac > best_hit) {
        best_hit = frac;
        best_theta = theta;
        best_o = o;
        best_n = n;
      }
    }
  }
  (void)best_theta;

  // ── 平面精化:对应点对【垂直平分面】(设计主路 a),法向保持重力水平 ──────────
  // 松容差(find_tol)扫描只能把平面锁到 ±簇深度的歧义带内;若不精化,紧 eps 门
  // 会被"松拟合平面"人为拖垮(把真镜子误判成不对称)。这里用 find_tol 内的对应对
  // (cand_i, NN_i) 迭代重估:法向 ∝ mean(cand−NN)(投影回水平),偏移 = 对应对
  // 中点在法向上的均值(垂直平分面闭式)。iter 收敛后再交给严格判据。
  for (int iter = 0; iter < 8; ++iter) {
    Vec3 nsum = Vec3::Zero();
    int npair = 0;
    for (const auto& p : cand_pts) {
      double d2;
      const int j = tree.Nearest(Reflect(p, best_n, best_o), &d2);
      if (j < 0 || d2 >= find_tol2) continue;
      Vec3 diff = p - real_pts[j];
      if (diff.dot(best_n) < 0.0) diff = -diff;  // 对齐符号到当前法向
      const double dn = diff.norm();
      if (dn > 1e-9) nsum += diff / dn;
      ++npair;
    }
    if (npair < 3) break;
    Vec3 nnew = nsum.norm() > 1e-9 ? Vec3(nsum.normalized()) : best_n;
    nnew = nnew - (nnew.dot(up)) * up;  // 锁回水平(重力约束)
    if (nnew.norm() < 1e-9) nnew = best_n;
    nnew.normalize();
    // 偏移用【新法向】重算中点均值,保证与 nnew 自洽。
    double osum2 = 0.0;
    int np2 = 0;
    for (const auto& p : cand_pts) {
      double d2;
      const int j = tree.Nearest(Reflect(p, best_n, best_o), &d2);
      if (j < 0 || d2 >= find_tol2) continue;
      osum2 += nnew.dot((p + real_pts[j]) * 0.5);
      ++np2;
    }
    const double onew = np2 > 0 ? osum2 / np2 : best_o;
    const double moved = (nnew - best_n).norm() + std::abs(onew - best_o);
    best_n = nnew;
    best_o = onew;
    if (moved < 1e-6) break;  // 收敛
  }

  s->plane_found = best_hit >= 0.0;
  for (int k = 0; k < 3; ++k) s->plane_n[k] = best_n[k];
  s->plane_d = best_o;

  // ── 每-候选:反射 → NN 距离、对称内点、颜色/法向一致 ─────────────────────────
  std::vector<char> sym_inlier(in.n_cand, 0);
  std::vector<int> nn_idx(in.n_cand, -1);
  int n_sym = 0;
  for (int i = 0; i < in.n_cand; ++i) {
    double d2;
    const int j = tree.Nearest(Reflect(cand_pts[i], best_n, best_o), &d2);
    nn_idx[i] = j;
    if (d2 < eps2) {
      sym_inlier[i] = 1;
      ++n_sym;
    }
  }
  s->n_sym_inlier = n_sym;
  s->sym_support_frac = static_cast<double>(n_sym) / in.n_cand;

  // 颜色一致率(在对称内点上;需 cand_rgb 与 real_rgb)。
  int color_consistent = 0;
  for (int i = 0; i < in.n_cand; ++i) {
    if (!sym_inlier[i]) continue;
    if (in.cand_rgb == nullptr || in.real_rgb == nullptr) continue;  // 无输入 → 不算一致
    const int j = nn_idx[i];
    if (j < 0) continue;
    int dmax = 0;
    for (int c = 0; c < 3; ++c) {
      const int dc = std::abs(static_cast<int>(in.cand_rgb[3 * i + c]) -
                              static_cast<int>(in.real_rgb[3 * j + c]));
      dmax = std::max(dmax, dc);
    }
    if (static_cast<double>(dmax) < cfg.color_dmax) ++color_consistent;
  }
  s->color_consistent_frac = n_sym > 0 ? static_cast<double>(color_consistent) / n_sym : 0.0;

  // ── 门③ 法向水平:|n·up| < sin(阈)──────────────────────────────────────────
  s->gate_normal_horizontal = std::abs(best_n.dot(up)) < cfg.normal_horiz_sin;

  // ── 门① 对称支持率(聚合):eps 内命中 ≥ 阈 ────────────────────────────────
  s->gate_symmetry_support = s->sym_support_frac >= cfg.min_sym_support_frac;

  // ── 门② 颜色一致(聚合):对称内点颜色一致率 ≥ 阈(且必须有颜色输入)──────────
  s->gate_color_consistency =
      (in.cand_rgb != nullptr && in.real_rgb != nullptr) &&
      s->color_consistent_frac >= cfg.min_color_consistent_frac;

  // ── 门④ 鬼侧无合法相机覆盖:相机全在平面一侧(房间侧),鬼侧无相机 ──────────
  int cam_pos = 0, cam_neg = 0;
  for (int i = 0; i < in.n_cam; ++i) {
    const double side = best_n.dot(RowVec(in.cam_xyz, i)) - best_o;
    if (side > 0.0)
      ++cam_pos;
    else if (side < 0.0)
      ++cam_neg;
  }
  s->cam_room_side = std::max(cam_pos, cam_neg);
  s->cam_ghost_side = std::min(cam_pos, cam_neg);
  // 需有相机、且全在一侧(鬼侧=0)。无相机 → 无法证鬼侧空 → 门不过。
  s->gate_ghost_no_camera = (in.n_cam > 0) && (s->cam_ghost_side == 0);

  // ── 门⑤ 平面与有界玻璃边框重合 / 对称内点足迹紧致(有界镜非整墙)─────────────
  // 对称内点的反射落点投影到平面内轴 → 足迹跨度;真簇(墙)同样投影 → 墙跨度。
  double fu_min = 1e18, fu_max = -1e18, fv_min = 1e18, fv_max = -1e18;
  for (int i = 0; i < in.n_cand; ++i) {
    if (!sym_inlier[i]) continue;
    const Vec3 r = Reflect(cand_pts[i], best_n, best_o);
    const double u = r.dot(e1), v = r.dot(e2);
    fu_min = std::min(fu_min, u);
    fu_max = std::max(fu_max, u);
    fv_min = std::min(fv_min, v);
    fv_max = std::max(fv_max, v);
  }
  double wu_min = 1e18, wu_max = -1e18, wv_min = 1e18, wv_max = -1e18;
  for (const auto& p : real_pts) {
    const double u = p.dot(e1), v = p.dot(e2);
    wu_min = std::min(wu_min, u);
    wu_max = std::max(wu_max, u);
    wv_min = std::min(wv_min, v);
    wv_max = std::max(wv_max, v);
  }
  s->footprint_u_m = (n_sym > 0) ? (fu_max - fu_min) : 0.0;
  s->footprint_v_m = (n_sym > 0) ? (fv_max - fv_min) : 0.0;
  s->wall_u_m = wu_max - wu_min;
  s->wall_v_m = wv_max - wv_min;

  bool bounded = (n_sym > 0) && (s->footprint_u_m < cfg.frame_max_extent_m) &&
                 (s->footprint_v_m < cfg.frame_max_extent_m) &&
                 (s->footprint_u_m < cfg.frame_max_wall_frac * s->wall_u_m) &&
                 (s->footprint_v_m < cfg.frame_max_wall_frac * s->wall_v_m);
  // 若显式给了重建玻璃边框:平面须与之重合(边框点全在平面 eps 内)且边框有界。
  if (in.frame_xyz != nullptr && in.n_frame > 0) {
    bool coincident = true;
    double gu_min = 1e18, gu_max = -1e18, gv_min = 1e18, gv_max = -1e18;
    for (int i = 0; i < in.n_frame; ++i) {
      const Vec3 f = RowVec(in.frame_xyz, i);
      if (std::abs(best_n.dot(f) - best_o) > cfg.eps_sym_m) coincident = false;
      const double u = f.dot(e1), v = f.dot(e2);
      gu_min = std::min(gu_min, u);
      gu_max = std::max(gu_max, u);
      gv_min = std::min(gv_min, v);
      gv_max = std::max(gv_max, v);
    }
    const bool frame_bounded = (gu_max - gu_min < cfg.frame_max_extent_m) &&
                               (gv_max - gv_min < cfg.frame_max_extent_m);
    bounded = bounded && coincident && frame_bounded;
  }
  s->gate_bounded_frame = bounded;

  // ── 硬化门:真自对称基线(假阳性地板)。reflect real→real 自命中率 ───────────
  // 支持率须 ≥ margin × baseline,否则删的可能只是场景本身的对称混淆。
  int self_hit = 0;
  const int self_n = static_cast<int>(real_pts.size());
  for (const auto& p : real_pts) {
    double d2;
    const int j = tree.Nearest(Reflect(p, best_n, best_o), &d2);
    // 排除自身(反射后最近邻可能是自己附近);仍用 eps 判。
    (void)j;
    if (d2 < eps2) ++self_hit;
  }
  s->real_self_symmetry_baseline = self_n > 0 ? static_cast<double>(self_hit) / self_n : 0.0;
  s->gate_self_symmetry_margin =
      s->sym_support_frac >= cfg.self_symmetry_margin * s->real_self_symmetry_baseline;

  // ── 全部每-平面门 AND ─────────────────────────────────────────────────────
  s->all_plane_gates_passed = s->plane_found && s->gate_normal_horizontal &&
                              s->gate_symmetry_support && s->gate_bounded_frame &&
                              s->gate_ghost_no_camera && s->gate_color_consistency &&
                              s->gate_self_symmetry_margin;

  // ── 每-候选合取:对称内点 ∧ 颜色一致 ∧(法向一致 若有)∧ 在鬼侧 ∧ ¬rescued ──
  const int ghost_sign = (cam_neg >= cam_pos) ? +1 : -1;  // 鬼侧 = 相机对侧
  std::vector<int> confirmed;
  int exempted = 0;
  for (int i = 0; i < in.n_cand; ++i) {
    if (!sym_inlier[i]) continue;
    // 颜色一致(必须有颜色输入)。
    if (in.cand_rgb == nullptr || in.real_rgb == nullptr) continue;
    const int j = nn_idx[i];
    if (j < 0) continue;
    int dmax = 0;
    for (int c = 0; c < 3; ++c) {
      const int dc = std::abs(static_cast<int>(in.cand_rgb[3 * i + c]) -
                              static_cast<int>(in.real_rgb[3 * j + c]));
      dmax = std::max(dmax, dc);
    }
    if (static_cast<double>(dmax) >= cfg.color_dmax) continue;
    // 法向一致(仅当双方法向可用)。
    if (in.cand_normal != nullptr && in.real_normal != nullptr) {
      const Vec3 nc = RowVec(in.cand_normal, i).normalized();
      // 反射会翻转法向沿 n 的分量:比较 |dot| 允许镜像翻转。
      const Vec3 nr = RowVec(in.real_normal, j).normalized();
      if (std::abs(nc.dot(nr)) < cfg.normal_dot_min) continue;
    }
    // 必须在鬼侧(平面法向 ghost 侧)。
    const double side = best_n.dot(cand_pts[i]) - best_o;
    if (side * ghost_sign <= 0.0) continue;
    // ¬rescued(bit5 豁免)。
    if (in.cand_flags != nullptr && (in.cand_flags[i] & 0x20) != 0) {
      ++exempted;
      continue;
    }
    confirmed.push_back(i);
  }
  s->n_confirmed_mirror = static_cast<int>(confirmed.size());
  s->n_exempted_rescue = exempted;

  // ── 最终:任一平面门不过 → ABSTAIN(删集清空)。能藏就别删。─────────────────
  if (!s->all_plane_gates_passed) {
    s->n_deleted = 0;
    char why[256];
    std::snprintf(why, sizeof(why),
                  "ABSTAIN: plane gates [normal_h=%d sym=%d(%.1f%%) color=%d(%.1f%%) "
                  "bounded=%d(%.2fx%.2fm) ghost_no_cam=%d self_margin=%d(base %.1f%%)]",
                  s->gate_normal_horizontal ? 1 : 0, s->gate_symmetry_support ? 1 : 0,
                  s->sym_support_frac * 100.0, s->gate_color_consistency ? 1 : 0,
                  s->color_consistent_frac * 100.0, s->gate_bounded_frame ? 1 : 0,
                  s->footprint_u_m, s->footprint_v_m, s->gate_ghost_no_camera ? 1 : 0,
                  s->gate_self_symmetry_margin ? 1 : 0,
                  s->real_self_symmetry_baseline * 100.0);
    SetReason(s, why);
    return {};
  }

  s->n_deleted = s->n_confirmed_mirror;
  SetReason(s, "CONFIRMED: all plane gates passed; deleting per-point confirmed mirror set");
  return confirmed;
}

}  // namespace mirror
}  // namespace aether
