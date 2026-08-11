// official_mirror_ghost.h — 交付层镜像鬼点过滤(V1:重力地板平面)
//
// [2026-08-06 用户签决"V1开工"→网页并排批准"确实很干净。v1可以上生产了"]
// [2026-08-07 用户签决"改尺度自适应"] 原 V1 的长度判据是绝对米数,拍茶杯
//  (场景尺度 ~5cm)时这些常数比物体还大,判据整体失效(host 实测:cap5 云
//  整体 ×0.05 后 candidates=0,52 个鬼点一个也杀不掉;×0.2 反而误杀到 92)。
//  现全部改写成"基准长度 eps"的倍数,eps 由点云自身密度推出 → 判据对相似
//  变换不变。验证见 progecttwo/_artifacts/mirror_ghost_adaptive_20260807/。
//
// 反光地板把上方结构的倒影三角化成地板平面下方的镜像虚点(cap5 实锤:
// 地板 -1.06,床头板顶 +0.38,虚点条带 -2.50 = 严格镜像;Flash-Splat 实证
// 倒影对 SfM 等价于"合法虚拟物体",几何质量过滤原则上杀不掉,只能用
// 物理/对称先验)。谱系:LiDAR 虚点去除(Yun&Sim CVPR18→GRASS26)的
// 已知平面退化版,调研与四臂验证见
// progecttwo/_artifacts/mirror_ghost_v1_20260806/RESULTS.md。
//
// 最终规则(双判据取与,host 四臂实测定案):
//   候选 = 重力地板平面(直方图最低显著水平层)下方 >1.1056×eps
//   ①成簇:单链接邻距 2.5798×eps,簇≥8 点(孤点不删)
//   ②镜像对应率≥0.6:点关于地板平面镜像后 2.2112×eps 内存在真实上方结构
//     (排除地板带自身)
// 被淘汰的判据(实测记录,勿复活):射线穿透(反光处恰无真实地板点,
// 方向反了,靶 0.16 vs 人造下沉 0.45);颜色(域均值被稀释 / 逐点最优被
// 密集区巧合命中,双向不可判别)。楼梯/下沉防护由②承担(实测 0.00)。
//
// 纯 std、无 Eigen/colmap 依赖:同一份代码被 iOS 产品核与 host parity
// 工具共用(单一事实源)。Y 轴 = 重力上(ARKit .gravity / 四端 IMU)。
// 开关:OFFICIAL_AETHER_MIRROR_GHOST=0 关闭(默认开)。
//       OFFICIAL_AETHER_MIRROR_GHOST_EPS_MUL 覆盖 eps 倍数(默认 10)。
//
// [2026-08-07 孤立浮点刀上机] P3 / Grid / dist2 / p90(NN) 已抽到
// official_scale_eps.h,与 official_isolated_floater.h 共用同一份 eps 口径
// (单一事实源)。纯搬运,算术与循环序逐字未动 ⇒ cap5 52/52 逐点 parity 不变。
#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <vector>

#include "official_scale_eps.h"

namespace aether_mirror_ghost {

constexpr float kFloorBinCount = 80.0f;
constexpr float kFloorSignif = 0.015f;   // 最低显著层:bin 数 > 1.5% 总点数
constexpr int kMinCluster = 8;           // 成簇才删(计数判据,天生尺度无关)
constexpr float kMirrorRatio = 0.6f;     // 簇级镜像对应率下限(比例,尺度无关)

// —— 尺度自适应基准长度 ——
// eps = kEpsMul × p90(最近邻距离):实现在 official_scale_eps.h,与孤立浮点刀
// 同口径同一份代码。整个估计对相似变换严格等变(云整体 ×s ⇒ eps ×s ⇒ 所有
// 判据阈值 ×s)。
constexpr float kEpsMulDefault = 10.0f;
constexpr int kEpsSampleMax = aether_scale_eps::kEpsSampleMax;
constexpr int kEpsMaxRing = aether_scale_eps::kEpsMaxRing;

// —— 长度判据(eps 的倍数)——
// ⚠️ 倍数由 cap5(镜像鬼点原始靶)现行为反推,与下面 ScaleEps() 的口径绑死:
// cap5 实测 eps = 0.135672m,与 V1 的绝对米数一一对应,保持逐点 parity:
//   0.08m→kFloorBandMul   0.15m→kBelowTolMul    0.30m→kMirrorRMul
//   0.35m→kClusterEpsMul  0.10m→kFloorPadMul
// 若日后改动 ScaleEps() 的口径(倍数 / 子采样 / 网格),这五个倍数必须
// 在 cap5 上重新反推,否则 parity 失效。
constexpr float kFloorBandMul = 0.5897f;    // 地板带厚(±),镜像搜索域排除它
constexpr float kBelowTolMul = 1.1056f;     // 平面下超过此距离才算候选
constexpr float kMirrorRMul = 2.2112f;      // 镜像对应搜索半径
constexpr float kClusterEpsMul = 2.5798f;   // 单链接簇内邻距
constexpr float kFloorPadMul = 0.7371f;     // 地板 bin 取带内中位数时的带外扩

using P3 = aether_scale_eps::P3;

struct Result {
  float floor_y = 0.0f;
  float eps = 0.0f;        // 本云推出的尺度基准长度(m),诊断用
  int candidates = 0;
  int guard = 0;  // [FLOOR-GUARD 2026-08-09] 0=未触发 1=候选质量守卫 2=地板合理性守卫
  int clusters = 0;        // 达到 kMinCluster 的簇数
  int killed_clusters = 0;
  std::vector<uint32_t> kill;  // 判虚点在输入数组中的下标
};

namespace detail {

// —— 共用实现别名(单一事实源在 official_scale_eps.h)——
// 保留 detail:: 这层名字是为了不动 host parity 工具(eps_probe.cc 直接引用
// aether_mirror_ghost::detail::Grid / dist2)。
using Grid = aether_scale_eps::Grid;
using aether_scale_eps::dist2;

inline float EpsMul() {
  static const float v =
      aether_scale_eps::EnvMul("OFFICIAL_AETHER_MIRROR_GHOST_EPS_MUL",
                               kEpsMulDefault);
  return v;
}

// 尺度基准长度 eps = kEpsMul × p90(最近邻距离)。
inline float ScaleEps(const std::vector<P3>& pts) {
  const float p90 = aether_scale_eps::NnP90(pts);
  if (!(p90 > 0.0f)) return 0.0f;
  return EpsMul() * p90;
}

}  // namespace detail

// pts:交付候选(视差角过滤幸存者)的位置。返回判虚下标集合与统计。
inline Result Detect(const std::vector<P3>& pts) {
  Result r;
  const size_t n = pts.size();
  if (n < 100) return r;  // 云太小谈不上地板

  // 0) 尺度基准:下面每一个长度判据都是它的倍数(拍茶杯与拍卧室同一套判据)
  const float eps = detail::ScaleEps(pts);
  if (!(eps > 0.0f)) return r;  // 退化云(点全重合等)→ 不过滤,fail-safe
  r.eps = eps;
  const float floor_band = kFloorBandMul * eps;
  const float below_tol = kBelowTolMul * eps;
  const float mirror_r = kMirrorRMul * eps;
  const float cluster_eps = kClusterEpsMul * eps;
  const float floor_pad = kFloorPadMul * eps;

  // 1) 地板 = 最低显著水平层(与 python 原型同口径:80 bins 直方图,从下往
  //    上第一个超过 1.5%n 的 bin,取带内中位数)
  float ymin = pts[0].y, ymax = pts[0].y;
  for (const auto& p : pts) { ymin = std::min(ymin, p.y); ymax = std::max(ymax, p.y); }
  if (!(ymax > ymin)) return r;
  const int bins = static_cast<int>(kFloorBinCount);
  const float bw = (ymax - ymin) / bins;
  std::vector<int> hist(bins, 0);
  for (const auto& p : pts) {
    int b = static_cast<int>((p.y - ymin) / bw);
    hist[std::min(std::max(b, 0), bins - 1)]++;
  }
  const int th = static_cast<int>(kFloorSignif * static_cast<float>(n));
  int fbin = -1;
  for (int b = 0; b < bins; ++b) {
    if (hist[b] > th) { fbin = b; break; }
  }
  float floor_y;
  if (fbin < 0) {
    // 兜底与原型一致:2 百分位
    std::vector<float> ys; ys.reserve(n);
    for (const auto& p : pts) ys.push_back(p.y);
    std::nth_element(ys.begin(), ys.begin() + n / 50, ys.end());
    floor_y = ys[n / 50];
  } else {
    const float lo = ymin + fbin * bw - floor_pad;
    const float hi = ymin + (fbin + 1) * bw + floor_pad;
    std::vector<float> band;
    for (const auto& p : pts) if (p.y >= lo && p.y <= hi) band.push_back(p.y);
    if (band.empty()) return r;
    std::nth_element(band.begin(), band.begin() + band.size() / 2, band.end());
    floor_y = band[band.size() / 2];
  }
  r.floor_y = floor_y;

  // 2) 候选(平面下)与镜像搜索域(上方真实结构,排除地板带与候选)
  std::vector<uint32_t> cand;
  detail::Grid up(mirror_r);
  for (uint32_t i = 0; i < n; ++i) {
    const float y = pts[i].y;
    if (y < floor_y - below_tol) cand.push_back(i);
    else if (std::fabs(y - floor_y) >= floor_band) up.add(pts[i], i);
  }
  r.candidates = static_cast<int>(cand.size());
  if (cand.empty()) return r;

  // [FLOOR-GUARD 2026-08-09 生产事故修复] cap_1786199789306631:直方图"最低
  // 显著水平层"选中了**床面**(floor_y=-0.099,真地板≈-0.9)——地板拍得稀疏、
  // 每 bin 不足 1.5%n 被跳过,床面这种致密水平面胜出。于是床下的真实世界
  // (地板/柜子/家具,13,720 点)全成了"地板下候选",镜像判据又被床上方的
  // 墙面/床头板满足(≥0.6),一刀误杀 13,321 点。这个失效模式在原型阶段
  // 犯过并记录过(直方图选床面 -0.28 而非地板 -0.88),生产代码没设防。
  //
  // 守卫①(候选质量):反光鬼点带是**稀疏伪影**——cap5 实锤靶 52 点占全云
  //   0.06%。候选若超过全云 2%,不是鬼是世界,fail-safe 不删。
  //   (本次事故 13,720/119k = 11.5%,直接触发。)
  // 守卫②(地板合理性):真地板必然贴近全云低分位。floor_y 高出 p2(Y) 超过
  //   3×eps ⇒ 检出的不是地板(是床/桌等中层平面),fail-safe 不删。
  //   (cap5:floor -1.06 vs p2≈-1.1,间隙 0.3×eps 通过;本次 -0.099 vs
  //   ≈-0.9,6.9×eps 触发。下沉地板/楼梯场景也会触发 ⇒ 方向是保护。)
  // 两道守卫只会放过鬼点(漏杀),永不误杀真实结构——符合交付无损底线。
  constexpr float kMaxCandidateFrac = 0.02f;
  constexpr float kFloorGapMul = 3.0f;
  if (static_cast<float>(cand.size()) > kMaxCandidateFrac * static_cast<float>(n)) {
    r.guard = 1;
    return r;
  }
  {
    std::vector<float> ys2;
    ys2.reserve(n);
    for (const auto& p : pts) ys2.push_back(p.y);
    std::nth_element(ys2.begin(), ys2.begin() + n / 50, ys2.end());
    const float p2 = ys2[n / 50];
    if (floor_y - p2 > kFloorGapMul * eps) {
      r.guard = 2;
      return r;
    }
  }

  // 3) 候选单链接聚簇(候选是百级,网格加速的 flood fill)
  detail::Grid cg(cluster_eps);
  for (uint32_t k = 0; k < cand.size(); ++k) cg.add(pts[cand[k]], k);
  std::vector<int> lbl(cand.size(), -1);
  int ncl = 0;
  for (uint32_t s = 0; s < cand.size(); ++s) {
    if (lbl[s] >= 0) continue;
    std::vector<uint32_t> stack{s};
    lbl[s] = ncl;
    while (!stack.empty()) {
      const uint32_t j = stack.back(); stack.pop_back();
      cg.forNeighbors(pts[cand[j]], [&](uint32_t k2) {
        if (lbl[k2] < 0 &&
            detail::dist2(pts[cand[j]], pts[cand[k2]]) <= cluster_eps * cluster_eps) {
          lbl[k2] = ncl;
          stack.push_back(k2);
        }
      });
    }
    ++ncl;
  }

  // 4) 逐簇判决:≥kMinCluster 且镜像对应率≥kMirrorRatio → 判虚
  const float r2 = mirror_r * mirror_r;
  for (int c = 0; c < ncl; ++c) {
    std::vector<uint32_t> sel;
    for (uint32_t k = 0; k < cand.size(); ++k)
      if (lbl[k] == c) sel.push_back(cand[k]);
    if (static_cast<int>(sel.size()) < kMinCluster) continue;
    ++r.clusters;
    int hit = 0;
    for (uint32_t i : sel) {
      P3 mp{pts[i].x, 2.0f * floor_y - pts[i].y, pts[i].z};
      bool found = false;
      up.forNeighbors(mp, [&](uint32_t j) {
        if (!found && detail::dist2(mp, pts[j]) <= r2) found = true;
      });
      if (found) ++hit;
    }
    if (static_cast<float>(hit) / static_cast<float>(sel.size()) >= kMirrorRatio) {
      ++r.killed_clusters;
      for (uint32_t i : sel) r.kill.push_back(i);
    }
  }
  return r;
}

}  // namespace aether_mirror_ghost
