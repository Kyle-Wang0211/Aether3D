// official_isolated_floater.h — 交付层孤立浮点过滤(最强安全版)
//
// [2026-08-07 用户签决装机] 与镜像鬼点(official_mirror_ghost.h)并列的第二把
// 交付层刀,跑在同一批"视差角 ≥3° 幸存者"上,两把刀的 kill 集取并。
//
// 要解决的是什么:视差角刀砍掉的是"低视差深度噪声壳";剩下的漏网是少数
// **深度估错**的点 —— 它们在图像里对得上,只是被三角化到了错误的深度,于是
// 在 3D 里脱离主结构、悬在空中(浮点)。事后清算类刀谱(SOR / 半径滤波 /
// track 长度 / 重投影误差)在 08-05 的 AUC 实验里已全部判死(壳自撑 k=20
// 邻域,SOR 反而误杀真结构),所以这里不用"密度"当判据,而用**几何方向**:
//
//   物理依据:深度估错 ⇒ 位置沿**视线**平移 ⇒ 浮点相对主结构的偏移方向与
//             它自己的平均视线方向近乎平行(|cos| → 1)。
//             真结构的碎片是**采样断开**(纹理弱/遮挡/帧覆盖不足)⇒ 它就长
//             在结构旁边,偏移是**横向**的(|cos| → 0)。
//
// 规则(host 原型定案,cap1 上删 113 点 / 85 簇,排风口与 439 点大结构全保):
//   eps = 10 × p90(最近邻距离)          ← 与镜像鬼点同一份 ScaleEps 口径
//   在 eps 下做连通簇;最大簇 = 主簇
//   对每个非主簇 c:
//     n     = 簇点数
//     dmain = 簇内点到主簇的最小距离(取到最小值的那个点记作 p*)
//     cos   = |dot( 单位化(p* − 主簇上离 p* 最近的点), p* 的平均视线方向 )|
//             (平均视线 = 该点各观测相机中心指向该点的单位向量之均值再单位化)
//   删除 c ⟺ (n < 5 且 dmain > 4×eps)  或  (n < 20 且 cos > 0.7)
//
// ⚠️ 阈值 0.7 是**下限被实测钉死**的:cap1 上那团 439 点的真结构 cos=0.60,
//    若把阈值放到 0.6 就会把它整团误删。排风口(21 点,dmain=6.5eps)cos=0.06
//    保住;远处真浮点 cos=0.83~0.94 删掉。**不要为了多删而下调这个阈值。**
//    n<5 那条是"极小簇 + 离主结构很远"的兜底,与 cos 无关(取或)。
//
// 与"全量交付铁律"的关系:同 3° 视差角与镜像鬼点 —— 该铁律禁的是降采样 /
// 性能性删点;本过滤是用户签决的**质量性**交付口径。
//
// 纯 std、无 Eigen/colmap 依赖:同一份代码被 iOS 产品核与 host parity 工具
// 共用(单一事实源);eps 口径共用 official_scale_eps.h。
// 开关:OFFICIAL_AETHER_ISOLATED_FLOATER=0 关闭(默认开,判定在
//       official_aether_sfm_c.cc 的 IsolatedFloaterEnabled())。
// 旋钮:OFFICIAL_AETHER_ISOLATED_FLOATER_EPS_MUL   (默认 10)
//       OFFICIAL_AETHER_ISOLATED_FLOATER_MIN_PTS  (默认 5)
//       OFFICIAL_AETHER_ISOLATED_FLOATER_DMAIN_MUL(默认 4)
//       OFFICIAL_AETHER_ISOLATED_FLOATER_COS      (默认 0.7)
#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <unordered_map>
#include <vector>

#include "official_scale_eps.h"

namespace aether_isolated_floater {

constexpr float kEpsMulDefault = 10.0f;    // eps = 10 × p90(NN)
constexpr int kMinPtsDefault = 5;          // "极小簇"上限(不含)
constexpr float kDmainMulDefault = 4.0f;   // 极小簇的远离门(eps 的倍数)
constexpr float kCosDefault = 0.7f;        // 视线平行门,见上文 ⚠️
// [2026-08-08 装机前加保险] cos 判据只对"中小簇"生效。物理依据:深度算错
// 导致的沿视线偏移,只可能发生在点少的碎片上;一个几十点、直径近 1m 的
// 结构不可能整体错到还保持内部一致——那更像真实物体。
// 实测触发点:cap2 有一个 64 点/直径 78cm/离主体仅 16cm 的簇 cos=0.819,
// 三项几何特征全指向真实结构、只有 cos 判它是浮点(且该场彩色云已从设备
// 删除、无法肉眼定夺)⇒ 加此上限规避。四场里 cos>0.7 命中的最大簇仅 13 点,
// 故本上限对 cap1/cap5/cap50 零影响。
constexpr int kCosMaxPtsDefault = 20;      // cos 判据的簇大小上限(不含)
constexpr size_t kMinCloudPts = 100;       // 云太小谈不上"主结构",不过滤

using P3 = aether_scale_eps::P3;

struct Result {
  float eps = 0.0f;         // 本云推出的尺度基准长度(m),诊断用
  int clusters = 0;         // 非主簇个数
  int killed_clusters = 0;
  int main_size = 0;        // 主簇点数,诊断用
  std::vector<uint32_t> kill;  // 判浮点在输入数组中的下标(升序)
};

namespace detail {

using Grid = aether_scale_eps::Grid;
using aether_scale_eps::dist2;

inline float EpsMul() {
  static const float v = aether_scale_eps::EnvMul(
      "OFFICIAL_AETHER_ISOLATED_FLOATER_EPS_MUL", kEpsMulDefault);
  return v;
}
inline int MinPts() {
  static const int v = aether_scale_eps::EnvInt(
      "OFFICIAL_AETHER_ISOLATED_FLOATER_MIN_PTS", kMinPtsDefault);
  return v;
}
inline float DmainMul() {
  static const float v = aether_scale_eps::EnvMul(
      "OFFICIAL_AETHER_ISOLATED_FLOATER_DMAIN_MUL", kDmainMulDefault);
  return v;
}
inline int CosMaxPts() {
  static const int v = static_cast<int>(aether_scale_eps::EnvMul(
      "OFFICIAL_AETHER_ISOLATED_FLOATER_COS_MAX_PTS",
      static_cast<float>(kCosMaxPtsDefault)));
  return v;
}

inline float CosThr() {
  static const float v = aether_scale_eps::EnvMul(
      "OFFICIAL_AETHER_ISOLATED_FLOATER_COS", kCosDefault);
  return v;
}

inline float ScaleEps(const std::vector<P3>& pts) {
  const float p90 = aether_scale_eps::NnP90(pts);
  if (!(p90 > 0.0f)) return 0.0f;
  return EpsMul() * p90;
}

}  // namespace detail

// pts       : 交付候选(视差角过滤幸存者)的位置。
// view_dirs : 与 pts 等长的平均视线**单位**向量(由调用方从 recon 算好:
//             遍历 track 的 image_id → ProjectionCenter() → 单位化
//             (C − X) 求均值再单位化)。零向量 = 该点无有效观测,其 cos 记 0
//             (fail-safe:算不出方向就不按方向删)。传入长度不符时整体按
//             "无观测"处理,退化成只剩 n<5 && dmain>4eps 那一条。
inline Result Detect(const std::vector<P3>& pts,
                     const std::vector<P3>& view_dirs) {
  Result r;
  const size_t n = pts.size();
  if (n < kMinCloudPts) return r;

  // 0) 尺度基准:下面每一个长度判据都是它的倍数(拍茶杯与拍卧室同一套判据)
  const float eps = detail::ScaleEps(pts);
  if (!(eps > 0.0f)) return r;  // 退化云(点全重合等)→ 不过滤,fail-safe
  r.eps = eps;
  const bool has_dirs = (view_dirs.size() == n);

  // 1) eps 半径下的连通簇(单链接)。
  //    朴素做法(边长 eps 的网格 + 3×3×3 全对)在 15 万点上 host 实测 1296ms
  //    ——交付入口 count-only 与全量各调一次,再乘手机 CPU,直接吃掉"拍完
  //    ≤30s"预算。这里换等价但便宜得多的算法:
  //      边长 c = 0.577·eps < eps/√3 ⇒ **同格任意两点距离 ≤ c√3 < eps**,
  //      于是每格先整体并成一个分量;此后两个格之间只要找到**一条** ≤eps
  //      的边就足以合并两个分量 —— 找到即停,同分量直接跳过。
  //      邻域 = Chebyshev ≤2 的 5×5×5:偏移 (2,2,2) 的最小间距 √3·c=0.9994eps
  //      仍可能连通,而 (3,0,0) 的 2c=1.155eps 必不可能,故 2 是紧的。
  //      只取字典序 > (0,0,0) 的 62 个偏移,每个无序格对恰好算一次。
  //    连通分量是唯一的,故结果与朴素做法逐点一致(host 已逐位对拍)。
  const float e2 = eps * eps;
  const float ccell = eps * 0.577f;
  // 格坐标以 bbox 最小角为原点:云可以整体离世界原点很远(x/ccell 直接取整
  // 会把格号推到 1e6 量级),减掉 lo 之后格号恒 ∈ [0, diag/ccell],21bit 打包
  // 绝无溢出。连通分量与网格如何划分无关,故这只是加固,不改结果(host 已
  // 对拍:四场 kill 掩码逐位不变)。
  float lo[3] = {pts[0].x, pts[0].y, pts[0].z};
  float hi[3] = {pts[0].x, pts[0].y, pts[0].z};
  for (const auto& p : pts) {
    lo[0] = std::min(lo[0], p.x); hi[0] = std::max(hi[0], p.x);
    lo[1] = std::min(lo[1], p.y); hi[1] = std::max(hi[1], p.y);
    lo[2] = std::min(lo[2], p.z); hi[2] = std::max(hi[2], p.z);
  }
  const float bx = hi[0] - lo[0], by = hi[1] - lo[1], bz = hi[2] - lo[2];
  const float diag = std::sqrt(bx * bx + by * by + bz * bz);
  // 21 bit/轴的**可逆**打包(不是 Grid 的 XOR 哈希:这里要靠 key 唯一性,
  // 一次碰撞就会把两个格错并成一个分量)。格坐标跨度 = diag/ccell,实拍云
  // 量级 1e2~1e3,离 2^20 极远。
  auto ckey = [](int x, int y, int z) -> uint64_t {
    return (static_cast<uint64_t>(static_cast<uint32_t>(x) & 0x1FFFFFu) << 42) |
           (static_cast<uint64_t>(static_cast<uint32_t>(y) & 0x1FFFFFu) << 21) |
           (static_cast<uint64_t>(static_cast<uint32_t>(z) & 0x1FFFFFu));
  };
  std::unordered_map<uint64_t, uint32_t> slot_of;
  slot_of.reserve(n / 8 + 16);
  std::vector<std::array<int, 3>> cell_xyz;
  std::vector<uint32_t> slot_of_pt(n), cell_cnt;
  for (uint32_t i = 0; i < n; ++i) {
    const int cx = static_cast<int>(std::floor((pts[i].x - lo[0]) / ccell));
    const int cy = static_cast<int>(std::floor((pts[i].y - lo[1]) / ccell));
    const int cz = static_cast<int>(std::floor((pts[i].z - lo[2]) / ccell));
    const uint64_t k = ckey(cx, cy, cz);
    auto it = slot_of.find(k);
    uint32_t s;
    if (it == slot_of.end()) {
      s = static_cast<uint32_t>(cell_xyz.size());
      slot_of.emplace(k, s);
      cell_xyz.push_back({cx, cy, cz});
      cell_cnt.push_back(0);
    } else {
      s = it->second;
    }
    slot_of_pt[i] = s;
    ++cell_cnt[s];
  }
  const size_t ncell = cell_xyz.size();
  std::vector<uint32_t> cell_off(ncell + 1, 0);   // CSR
  for (size_t s = 0; s < ncell; ++s) cell_off[s + 1] = cell_off[s] + cell_cnt[s];
  std::vector<uint32_t> cell_pts(n);
  {
    std::vector<uint32_t> w(cell_off.begin(), cell_off.end() - 1);
    for (uint32_t i = 0; i < n; ++i) cell_pts[w[slot_of_pt[i]]++] = i;
  }

  aether_scale_eps::DSU dsu(n);
  for (size_t s = 0; s < ncell; ++s) {           // 格内直连
    const uint32_t b = cell_off[s], e = cell_off[s + 1];
    for (uint32_t t = b + 1; t < e; ++t) dsu.unite(cell_pts[b], cell_pts[t]);
  }
  for (size_t s = 0; s < ncell; ++s) {           // 格间:一条边即可
    const int cx = cell_xyz[s][0], cy = cell_xyz[s][1], cz = cell_xyz[s][2];
    for (int dx = 0; dx <= 2; ++dx)
      for (int dy = (dx == 0 ? 0 : -2); dy <= 2; ++dy)
        for (int dz = (dx == 0 && dy == 0) ? 1 : -2; dz <= 2; ++dz) {
          const auto it = slot_of.find(ckey(cx + dx, cy + dy, cz + dz));
          if (it == slot_of.end()) continue;
          const uint32_t s2 = it->second;
          if (dsu.find(cell_pts[cell_off[s]]) ==
              dsu.find(cell_pts[cell_off[s2]])) continue;
          bool linked = false;
          for (uint32_t ai = cell_off[s]; ai < cell_off[s + 1] && !linked; ++ai) {
            const P3& pa = pts[cell_pts[ai]];
            for (uint32_t bi = cell_off[s2]; bi < cell_off[s2 + 1]; ++bi) {
              const uint32_t j = cell_pts[bi];
              if (detail::dist2(pa, pts[j]) <= e2) {
                dsu.unite(cell_pts[ai], j);
                linked = true;
                break;
              }
            }
          }
        }
  }

  // 2) 主簇 = 最大簇
  std::vector<uint32_t> root(n);
  std::unordered_map<uint32_t, uint32_t> size_of;
  size_of.reserve(n / 4 + 16);
  for (uint32_t i = 0; i < n; ++i) {
    root[i] = dsu.find(i);
    ++size_of[root[i]];
  }
  uint32_t main_root = root[0];
  uint32_t main_sz = 0;
  for (const auto& [rt, sz] : size_of) {
    // 平局用较小的 root 号定序,保证同一份输入总给同一个主簇(可复现)
    if (sz > main_sz || (sz == main_sz && rt < main_root)) {
      main_sz = sz;
      main_root = rt;
    }
  }
  r.main_size = static_cast<int>(main_sz);
  if (main_sz == n) return r;  // 一整团,没有非主簇

  // 3) 主簇的最近邻网格(环形扩张精确搜索)。
  //    ⚠️ 网格边长**不能**取 eps:真浮点的 dmain 可以远到几十个 eps
  //    (cap1 实测有 4.5m ≈ 39eps 的),而环形扩张的上限是 kEpsMaxRing=32 格
  //    ——用 eps 当边长会让这些最该删的远浮点搜不到主簇而被"保守保留"
  //    (host 对账实测:漏 1 簇 2 点,且另 1 簇拿到错的最近点 4.59 而非
  //     4.52,cos 从 0.911 掉到 0.890)。取 max(eps, diag/(ring−2)) 后整朵云
  //    必落在 32 格内,搜索恒为精确解,与 python 原型的 KD-tree 逐簇对齐。
  const float main_cell =
      std::max(eps, diag / static_cast<float>(aether_scale_eps::kEpsMaxRing - 2));
  detail::Grid mg(main_cell);
  for (uint32_t i = 0; i < n; ++i)
    if (root[i] == main_root) mg.add(pts[i], i);

  // 4) 非主簇分组
  std::unordered_map<uint32_t, std::vector<uint32_t>> groups;
  for (uint32_t i = 0; i < n; ++i)
    if (root[i] != main_root) groups[root[i]].push_back(i);
  r.clusters = static_cast<int>(groups.size());

  const int min_pts = detail::MinPts();
  const float dmain_thr = detail::DmainMul() * eps;
  const float cos_thr = detail::CosThr();

  for (const auto& [rt, members] : groups) {
    // 4a) dmain = 簇到主簇的最小距离,并记下取到它的簇内点 p* 与主簇对应点
    float best_d2 = -1.0f;
    uint32_t p_star = aether_scale_eps::kNoIndex;
    uint32_t q_star = aether_scale_eps::kNoIndex;
    for (uint32_t i : members) {
      float d2 = -1.0f;
      const uint32_t q = aether_scale_eps::NearestIndexed(mg, pts, pts[i], &d2);
      if (q == aether_scale_eps::kNoIndex || d2 < 0.0f) continue;
      if (best_d2 < 0.0f || d2 < best_d2) { best_d2 = d2; p_star = i; q_star = q; }
    }
    if (best_d2 < 0.0f) continue;  // 主簇远到 32 格外:算不出判据,保守保留
    const float dmain = std::sqrt(best_d2);

    // 4b) cos = |偏移方向 · 平均视线|(偏移方向 = p* − q*)
    float cosv = 0.0f;
    if (has_dirs) {
      const P3& p = pts[p_star];
      const P3& q = pts[q_star];
      float ox = p.x - q.x, oy = p.y - q.y, oz = p.z - q.z;
      const float on = std::sqrt(ox * ox + oy * oy + oz * oz);
      const P3& v = view_dirs[p_star];
      const float vn = std::sqrt(v.x * v.x + v.y * v.y + v.z * v.z);
      if (on > 0.0f && vn > 0.0f) {
        cosv = std::fabs((ox * v.x + oy * v.y + oz * v.z) / (on * vn));
      }
    }

    const int csize = static_cast<int>(members.size());
    const bool tiny_and_far = (csize < min_pts) && (dmain > dmain_thr);
    const bool ray_aligned = (csize < detail::CosMaxPts()) && (cosv > cos_thr);
    if (tiny_and_far || ray_aligned) {
      ++r.killed_clusters;
      for (uint32_t i : members) r.kill.push_back(i);
    }
  }
  std::sort(r.kill.begin(), r.kill.end());  // 与遍历序无关,输出可复现
  return r;
}

}  // namespace aether_isolated_floater
