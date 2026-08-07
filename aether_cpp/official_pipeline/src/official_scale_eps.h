// official_scale_eps.h — 交付层判据的共用"尺度基准长度"(单一事实源)
//
// [2026-08-07] 原本这段代码只住在 official_mirror_ghost.h 里;孤立浮点刀
// (official_isolated_floater.h)上机时用户签决"必须复用其 ScaleEps()",于是
// 把 P3 / Grid / dist2 / NnP90 抽到本头,两把交付层刀共用同一份实现 ——
// 任何一方改口径,另一方必然同步(避免两套 eps 悄悄漂开)。
// 抽取是纯搬运:算术、循环序、浮点类型逐字未动,故 mirror ghost 的 cap5
// 52/52 逐点 parity 不受影响(host 已复测)。
//
// eps 的定义:eps = mul × p90(最近邻距离)。
//   · p90 由点云自身密度推出 ⇒ 所有以 eps 为单位的长度判据对相似变换不变
//     (云整体 ×s ⇒ p90 ×s ⇒ eps ×s ⇒ 判据 ×s)。拍茶杯(场景尺度 5cm)与
//     拍卧室用同一套常数,这是 08-07 "改尺度自适应"签决的全部动机。
//   · 网格边长取 diag/sqrt(n) 而非 diag/cbrt(n):点云是"面填充"不是"体填充",
//     体积口径每格落进数百点,查询退化成 O(n·k) —— host 实测 15 万点 442ms
//     vs 面口径 38ms,eps 逐位相同(11× 提速且不改结果)。
//   · n 可达 15 万,对查询点等步长子采样 ≤kEpsSampleMax 估 p90(邻域搜索仍
//     对全量点,NN 距离本身无偏)。⚠️ 子采样会让 p90 与"全量 numpy
//     percentile"差 ~1%(cap1 实测 0.011371 vs 0.011475,−0.91%);host 原型
//     若用全量口径标定过阈值,移植到本实现时要按这条重新核对簇数。
//
// 纯 std、无 Eigen/colmap 依赖:同一份代码被 iOS 产品核与 host parity 工具共用。
#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <limits>
#include <unordered_map>
#include <vector>

namespace aether_scale_eps {

constexpr int kEpsSampleMax = 30000;  // p90 估计的子采样上限
constexpr int kEpsMaxRing = 32;       // 环形扩张上限(超出则该查询弃权)
constexpr uint32_t kNoIndex = std::numeric_limits<uint32_t>::max();

struct P3 { float x, y, z; };

inline float dist2(const P3& a, const P3& b) {
  const float dx = a.x - b.x, dy = a.y - b.y, dz = a.z - b.z;
  return dx * dx + dy * dy + dz * dz;
}

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

// 环形扩张精确最近邻:返回"已加入 g 的点"中距 q 最近者在 pts 中的下标
// (exclude 跳过,通常是 q 自己);找不到返回 kNoIndex。*out_d2 写距离平方。
// 壳层 R 扫完后,壳外任何点距离 ≥ R*cell:best 已达此界即为精确解。
inline uint32_t NearestIndexed(const Grid& g, const std::vector<P3>& pts,
                               const P3& q, float* out_d2,
                               uint32_t exclude = kNoIndex,
                               int max_ring = kEpsMaxRing) {
  const auto c = g.cellOf(q);
  float best = -1.0f;
  uint32_t best_i = kNoIndex;
  for (int R = 0; R <= max_ring; ++R) {
    for (int ax = -R; ax <= R; ++ax)
      for (int ay = -R; ay <= R; ++ay)
        for (int az = -R; az <= R; ++az) {
          // 只扫 Chebyshev 距离 == R 的壳层(R-1 及以内上一轮已扫过)
          if (std::max(std::max(std::abs(ax), std::abs(ay)), std::abs(az)) != R)
            continue;
          const auto it = g.m.find(Grid::key(c[0] + ax, c[1] + ay, c[2] + az));
          if (it == g.m.end()) continue;
          for (uint32_t j : it->second) {
            if (j == exclude) continue;
            const float d2 = dist2(q, pts[j]);
            if (best < 0.0f || d2 < best) { best = d2; best_i = j; }
          }
        }
    const float bound = static_cast<float>(R) * g.cell;
    if (best >= 0.0f && best <= bound * bound) break;
  }
  if (out_d2) *out_d2 = best;
  return best_i;
}

// p90(最近邻距离)。退化云(n<2 / bbox 塌缩 / 全体极孤立)返回 0。
inline float NnP90(const std::vector<P3>& pts) {
  const size_t n = pts.size();
  if (n < 2) return 0.0f;
  float lo[3] = {pts[0].x, pts[0].y, pts[0].z};
  float hi[3] = {pts[0].x, pts[0].y, pts[0].z};
  for (const auto& p : pts) {
    lo[0] = std::min(lo[0], p.x); hi[0] = std::max(hi[0], p.x);
    lo[1] = std::min(lo[1], p.y); hi[1] = std::max(hi[1], p.y);
    lo[2] = std::min(lo[2], p.z); hi[2] = std::max(hi[2], p.z);
  }
  const float dx = hi[0] - lo[0], dy = hi[1] - lo[1], dz = hi[2] - lo[2];
  const float diag = std::sqrt(dx * dx + dy * dy + dz * dz);
  if (!(diag > 0.0f)) return 0.0f;
  const float cell = diag / std::sqrt(static_cast<float>(n));
  if (!(cell > 0.0f)) return 0.0f;

  Grid g(cell);
  for (uint32_t i = 0; i < n; ++i) g.add(pts[i], i);

  const size_t stride = (n + kEpsSampleMax - 1) / kEpsSampleMax;
  std::vector<float> d;
  d.reserve(n / stride + 1);
  for (size_t i = 0; i < n; i += stride) {
    float best = -1.0f;
    NearestIndexed(g, pts, pts[i], &best, static_cast<uint32_t>(i));
    if (best < 0.0f) continue;  // 极孤立点(>32 格无邻居)弃权,不污染 p90
    d.push_back(std::sqrt(best));
  }
  if (d.empty()) return 0.0f;
  size_t k = static_cast<size_t>(0.9 * static_cast<double>(d.size()));
  if (k >= d.size()) k = d.size() - 1;
  std::nth_element(d.begin(), d.begin() + k, d.end());
  return d[k];
}

// env 覆盖的正浮点旋钮(非法/缺省 → def)。每个 name 独立缓存。
inline float EnvMul(const char* name, float def) {
  const char* e = std::getenv(name);
  if (!e || !*e) return def;
  const float f = static_cast<float>(std::atof(e));
  return (f > 0.0f) ? f : def;
}

// env 覆盖的正整数旋钮(<=0 或非法 → def)。
inline int EnvInt(const char* name, int def) {
  const char* e = std::getenv(name);
  if (!e || !*e) return def;
  const int v = std::atoi(e);
  return (v > 0) ? v : def;
}

// 并查集(路径减半),连通簇用。
struct DSU {
  std::vector<uint32_t> p;
  explicit DSU(size_t n) : p(n) {
    for (uint32_t i = 0; i < static_cast<uint32_t>(n); ++i) p[i] = i;
  }
  uint32_t find(uint32_t x) {
    while (p[x] != x) { p[x] = p[p[x]]; x = p[x]; }
    return x;
  }
  void unite(uint32_t a, uint32_t b) {
    a = find(a); b = find(b);
    if (a != b) p[b] = a;
  }
};

}  // namespace aether_scale_eps
