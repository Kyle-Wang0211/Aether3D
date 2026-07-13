// aether_mirror_cull.h — [MIRROR-CULL 2026-07-13] 玻璃镜中世界删刀
// (vertical-glass "mirror world" refutation-by-symmetry cull).
//
// ┌─────────────────────────────────────────────────────────────────────────┐
// │  🔴🔴🔴  真删 = 有损 = 不可逆。默认关。cap50 未验证误伤=0。  🔴🔴🔴        │
// │                                                                          │
// │  三条焊死的铁律（不可自行改回）:                                          │
// │   ① 默认关。行为受 env `AETHER_MIRROR_DELETE` 门控;不设或 !="1" =         │
// │      硬 no-op(ArbitrateMirrorCull 立即返回空,连分析都不跑)= 零 ship     │
// │      影响。这与 kGhostMaskViewFilter(默认 true 的【可逆】display 门)     │
// │      不同:本删门【不可逆】,默认必须 false,须用户显式签决后才可 ship。   │
// │   ② cap50 上验不了误伤=0。对抗复核(workflow wv3ffymrw)已证 cap50 里那面   │
// │      "镜子"其实是【真玻璃门/落地窗通向对齐相邻走廊】:满墙铺开(足迹        │
// │      2.2m×2.4m≈全墙宽)、40% 颜色不匹配、鬼侧实为相机可达的真远景。         │
// │      现在开=删真内容。→ 绝不默认开。                                       │
// │   ③ 未验证。启用前必须:带【已知有界镜子】的专用 fixture 逐位验误伤=0      │
// │      + 用户对"真删=有损=不可逆"签决。二者缺一不可 ship。                    │
// └─────────────────────────────────────────────────────────────────────────┘
//
// 状态:独立可评审模块 + host 测试(banking),**未启用、未装机、未 wire 进
// 交付路径**。集成挂点(未接):Dart `arbitrate_done` 钩子
// (ar_capture_page._recomputeDeliveredGhostMaskAfterArbitration),等 fixture
// 验证过 + 签决后才接,这样本轮零概率误触交付。
//
// ── 算法(纯 C++/CPU,跨端零障碍:iOS/Android/鸿蒙/Web WASM)──────────────────
// 依赖 Eigen(MPL2)+ 内置紧凑 3D KD-tree(生产可换 nanoflann,BSD-2,等价)+
// 自写 gravity-locked 反射平面搜索(~百行)。不碰 CGAL(GPL)/OpenMVS(AGPL)/
// CoreML/MNN/Dawn。
//   1. 反射平面检测:用重力向量把候选法向【锁死为水平】|n·up|<sin15°,搜索空
//      间砍到近一维(θ 角 + 偏移 o),Podolak/Mitra 2006 PRST 的重力约束特例。
//   2. Householder 镜像证伪:x' = (I − 2·n·nᵀ)·x − 2d·n;KD-tree 在真簇找最近
//      邻,symmetry score = ‖x' − NN(x')‖。
//   3. 多证据【合取】(误隐=0 红线,缺一即回退不删):
//        对称距 ε ∧ 描述子/法向/颜色一致 ∧ 法向水平 ∧ 鬼侧无合法相机覆盖 ∧
//        平面与重建到的玻璃边框重合(有界)。
//      另加一条硬化门(quant 坐实的假阳性地板):确证支持率须显著高于【真内容
//      自对称基线】(reflect real→real 的自命中率,cap50=8.6%@10cm)。
//   缺任一门 → ABSTAIN(不删),疑似点继续走 L2 可逆藏。原则:能藏就别删。
//
// 与 L1/L2 衔接(未接,仅设计):删集 = confirmed(bit6) ∧ mirror_hit ∧
// ¬rescued(bit5)。rescue 与 mirror 构造性不相交(aether_l1_arbitrate.h:724),
// 先豁免 rescue 再删,天然不误删救回点(belt-and-suspenders)。
//
// Build(standalone,不进 contended CMakeLists;host 测试同法):
//   clang++ -std=c++17 -O2 -ffp-contract=off -I <repo>/aether_cpp/third_party/eigen \
//       -o mirror_cull_cap50_test \
//       bench/mirror_cull_cap50_test.cc bench/aether_mirror_cull.cc
#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace aether {
namespace mirror {

// ── 输入:候选鬼簇 + 真簇(反射目标)+ 相机中心 + 重力向量(+ 可选玻璃边框)──
struct MirrorCullInput {
  // 候选鬼点(疑似镜中世界虚像,落在玻璃平面"后方")。行主序 xyz。
  const double* cand_xyz = nullptr;    // 3 * n_cand
  const uint8_t* cand_rgb = nullptr;   // 3 * n_cand,可选;缺 → 颜色门无法通过
  const uint8_t* cand_flags = nullptr; // n_cand,可选;bit5(0x20)=rescued(豁免)
  const double* cand_normal = nullptr; // 3 * n_cand,可选;缺 → 法向门跳过(不加分)
  int n_cand = 0;

  // 真(保留)簇:镜中世界必须反射【命中】它。KD-tree 目标。
  const double* real_xyz = nullptr;    // 3 * n_real
  const uint8_t* real_rgb = nullptr;   // 3 * n_real,可选
  const double* real_normal = nullptr; // 3 * n_real,可选
  int n_real = 0;

  // 已注册相机中心(世界系),供"鬼侧无合法相机覆盖"门。
  const double* cam_xyz = nullptr;     // 3 * n_cam
  int n_cam = 0;

  // 重力/up 单位向量(取自重建到的地板面法向)。
  double up[3] = {0.0, 1.0, 0.0};

  // 可选:显式重建到的【有界玻璃边框】(镜框/污渍/边缘点)。给了(n_frame>0)则
  // 平面须与之重合且足迹有界;没给则退化为对称内点足迹紧致性启发式。
  const double* frame_xyz = nullptr;   // 3 * n_frame
  int n_frame = 0;
};

// ── 配置:阈值均为【物理几何容差】(cm/度级),非被否决的 σ_depth 统计带 ──────
struct MirrorCullConfig {
  double eps_sym_m = 0.03;                 // 紧对称容差(cm 级),per-point 判虚像
  double plane_find_tol_m = 0.10;          // 平面搜索容差(松,先锁面;门在 eps 判)
  double normal_horiz_sin = 0.258819;      // sin(15°):|n·up| 上限
  double color_dmax = 30.0;                // 每通道 |dRGB| 判"颜色一致"
  double normal_dot_min = 0.80;            // per-point 法向一致(仅当法向可用)
  double min_sym_support_frac = 0.60;      // 平面门:≥60% 候选在 eps 内反射命中
  double min_color_consistent_frac = 0.70; // ≥70% 对称内点颜色一致
  double frame_max_extent_m = 0.90;        // 有界镜:足迹每轴 <0.9m(镜框不是整墙)
  double frame_max_wall_frac = 0.50;       // 足迹每轴 <50% 墙跨度
  double self_symmetry_margin = 3.0;       // 支持率须 ≥ margin×真自对称基线(假阳地板)
  double sweep_angle_step_deg = 3.0;       // 重力锁定 θ 扫描步长
  double sweep_offset_step_m = 0.05;       // 偏移 o 扫描步长
  bool require_env_gate = true;            // true:须 AETHER_MIRROR_DELETE=="1" 才动
};

// ── 遥测(抄现有范式,拟落 mirror_delete.json + Dart TelemetryWriter event)──
struct MirrorCullStats {
  bool env_enabled = false;                // AETHER_MIRROR_DELETE=="1"?
  bool plane_found = false;
  // 每-平面门:
  bool gate_normal_horizontal = false;     // ③ 法向水平
  bool gate_symmetry_support = false;      // ① 对称距 ε(聚合形式)
  bool gate_bounded_frame = false;         // ⑤ 平面与有界玻璃边框重合
  bool gate_ghost_no_camera = false;       // ④ 鬼侧无合法相机覆盖
  bool gate_color_consistency = false;     // ② 颜色一致(聚合形式)
  bool gate_self_symmetry_margin = false;  // 硬化:超真自对称假阳地板
  bool all_plane_gates_passed = false;     // 全部每-平面门 AND
  // 计数:
  int n_cand = 0;
  int n_sym_inlier = 0;                    // 反射 NN 距 < eps 的候选数
  int n_confirmed_mirror = 0;             // 过【全部】per-point 门
  int n_exempted_rescue = 0;              // 因 bit5 豁免
  int n_deleted = 0;                       // all_plane_gates? n_confirmed : 0
  // 几何/证据:
  double plane_n[3] = {0.0, 0.0, 0.0};
  double plane_d = 0.0;                     // n·x = plane_d
  double sym_support_frac = 0.0;           // eps 内命中率
  double color_consistent_frac = 0.0;
  double footprint_u_m = 0.0;              // 对称内点足迹跨度(平面内 e1)
  double footprint_v_m = 0.0;              // 平面内 e2
  double wall_u_m = 0.0;                   // 真簇(墙)跨度 e1
  double wall_v_m = 0.0;                   // e2
  double real_self_symmetry_baseline = 0.0;// reflect real→real 自命中率(假阳地板)
  int cam_room_side = 0;
  int cam_ghost_side = 0;
  char abstain_reason[256] = {0};
};

// 返回可【永久删除】的候选索引(into cand)。仅当 env 门开 AND 每一条门都过时才
// 非空;任一门不过 → 空(ABSTAIN)。这是唯一提议真删的函数,默认 no-op /
// display-only(见 AETHER_MIRROR_DELETE)。stats 可为 nullptr。
std::vector<int> ArbitrateMirrorCull(const MirrorCullInput& in,
                                     const MirrorCullConfig& cfg,
                                     MirrorCullStats* stats);

}  // namespace mirror
}  // namespace aether
