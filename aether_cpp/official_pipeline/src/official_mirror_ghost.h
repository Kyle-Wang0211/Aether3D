// official_mirror_ghost.h — 交付层镜像鬼点过滤(V1:重力地板平面)
//
// [2026-08-06 用户签决"V1开工"→网页并排批准"确实很干净。v1可以上生产了"]
// 反光地板把上方结构的倒影三角化成地板平面下方的镜像虚点(cap5 实锤:
// 地板 -1.06,床头板顶 +0.38,虚点条带 -2.50 = 严格镜像;Flash-Splat 实证
// 倒影对 SfM 等价于"合法虚拟物体",几何质量过滤原则上杀不掉,只能用
// 物理/对称先验)。谱系:LiDAR 虚点去除(Yun&Sim CVPR18→GRASS26)的
// 已知平面退化版,调研与四臂验证见
// progecttwo/_artifacts/mirror_ghost_v1_20260806/RESULTS.md。
//
// 最终规则(双判据取与,host 四臂实测定案):
//   候选 = 重力地板平面(直方图最低显著水平层)下方 >15cm
//   ①成簇:单链接 eps=0.35m,簇≥8 点(孤点不删)
//   ②镜像对应率≥0.6:点关于地板平面镜像后 30cm 内存在真实上方结构
//     (排除地板带自身)
// 被淘汰的判据(实测记录,勿复活):射线穿透(反光处恰无真实地板点,
// 方向反了,靶 0.16 vs 人造下沉 0.45);颜色(域均值被稀释 / 逐点最优被
// 密集区巧合命中,双向不可判别)。楼梯/下沉防护由②承担(实测 0.00)。
//
// 纯 std、无 Eigen/colmap 依赖:同一份代码被 iOS 产品核与 host parity
// 工具共用(单一事实源)。Y 轴 = 重力上(ARKit .gravity / 四端 IMU)。
// 开关:OFFICIAL_AETHER_MIRROR_GHOST=0 关闭(默认开)。
#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <unordered_map>
#include <vector>

namespace aether_mirror_ghost {

constexpr float kFloorBinCount = 80.0f;
constexpr float kFloorSignif = 0.015f;   // 最低显著层:bin 数 > 1.5% 总点数
constexpr float kFloorBandM = 0.08f;     // 地板带厚(±),镜像搜索域排除它
constexpr float kBelowTolM = 0.15f;      // 平面下超过此距离才算候选
constexpr float kClusterEps = 0.35f;     // 单链接簇内邻距
constexpr int kMinCluster = 8;           // 成簇才删
constexpr float kMirrorR = 0.30f;        // 镜像对应搜索半径
constexpr float kMirrorRatio = 0.6f;     // 簇级镜像对应率下限

struct P3 { float x, y, z; };

struct Result {
  float floor_y = 0.0f;
  int candidates = 0;
  int clusters = 0;        // 达到 kMinCluster 的簇数
  int killed_clusters = 0;
  std::vector<uint32_t> kill;  // 判虚点在输入数组中的下标
};

namespace detail {

// 空间网格哈希(单元=cell),邻域查询用
struct Grid {
  float cell;
  std::unordered_map<uint64_t, std::vector<uint32_t>> m;
  explicit Grid(float c) : cell(c) {}
  static uint64_t key(int ix, int iy, int iz) {
    return (static_cast<uint64_t>(static_cast<uint32_t>(ix)) << 42) ^
           (static_cast<uint64_t>(static_cast<uint32_t>(iy)) << 21) ^
           static_cast<uint64_t>(static_cast<uint32_t>(iz));
  }
  std::array<int, 3> cellOf(const P3& p) const {
    return {static_cast<int>(std::floor(p.x / cell)),
            static_cast<int>(std::floor(p.y / cell)),
            static_cast<int>(std::floor(p.z / cell))};
  }
  void add(const P3& p, uint32_t idx) {
    const auto c = cellOf(p);
    m[key(c[0], c[1], c[2])].push_back(idx);
  }
  // 半径 r<=cell 时查 3x3x3 邻格足够
  template <typename F>
  void forNeighbors(const P3& p, F&& f) const {
    const auto c = cellOf(p);
    for (int dx = -1; dx <= 1; ++dx)
      for (int dy = -1; dy <= 1; ++dy)
        for (int dz = -1; dz <= 1; ++dz) {
          const auto it = m.find(key(c[0] + dx, c[1] + dy, c[2] + dz));
          if (it == m.end()) continue;
          for (uint32_t idx : it->second) f(idx);
        }
  }
};

inline float dist2(const P3& a, const P3& b) {
  const float dx = a.x - b.x, dy = a.y - b.y, dz = a.z - b.z;
  return dx * dx + dy * dy + dz * dz;
}

}  // namespace detail

// pts:交付候选(视差角过滤幸存者)的位置。返回判虚下标集合与统计。
inline Result Detect(const std::vector<P3>& pts) {
  Result r;
  const size_t n = pts.size();
  if (n < 100) return r;  // 云太小谈不上地板

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
    const float lo = ymin + fbin * bw - 0.1f, hi = ymin + (fbin + 1) * bw + 0.1f;
    std::vector<float> band;
    for (const auto& p : pts) if (p.y >= lo && p.y <= hi) band.push_back(p.y);
    if (band.empty()) return r;
    std::nth_element(band.begin(), band.begin() + band.size() / 2, band.end());
    floor_y = band[band.size() / 2];
  }
  r.floor_y = floor_y;

  // 2) 候选(平面下)与镜像搜索域(上方真实结构,排除地板带与候选)
  std::vector<uint32_t> cand;
  detail::Grid up(kMirrorR);
  for (uint32_t i = 0; i < n; ++i) {
    const float y = pts[i].y;
    if (y < floor_y - kBelowTolM) cand.push_back(i);
    else if (std::fabs(y - floor_y) >= kFloorBandM) up.add(pts[i], i);
  }
  r.candidates = static_cast<int>(cand.size());
  if (cand.empty()) return r;

  // 3) 候选单链接聚簇(候选是百级,网格加速的 flood fill)
  detail::Grid cg(kClusterEps);
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
            detail::dist2(pts[cand[j]], pts[cand[k2]]) <= kClusterEps * kClusterEps) {
          lbl[k2] = ncl;
          stack.push_back(k2);
        }
      });
    }
    ++ncl;
  }

  // 4) 逐簇判决:≥kMinCluster 且镜像对应率≥kMirrorRatio → 判虚
  const float r2 = kMirrorR * kMirrorR;
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
