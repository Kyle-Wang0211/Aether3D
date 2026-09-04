// dense_preproc.h — deterministic CasDiffMVS pre-processing, ported VERBATIM from
// the certified 'o' pipeline (pocketworld_research_benchmarks/tools/python:
// pw_diffmvs_common.make_proj_matrices/depth_values_tensor, pw_diffmvs_run.scaled_K).
// Byte-exact float32: the CoreML model must be fed inputs bit-identical to Python.
//
// Cross-platform C++17, no deps beyond <array>/<vector>. NO parameter is invented —
// every constant (PROC_H=512, PROC_W=896, NPZ_H=504, numdepth=384, stage scales
// 0.125/0.25/0.5/1.0) is copied from the production 'o' config.
#pragma once
#include <array>
#include <cstdint>
#include <string>
#include <utility>
#include <vector>

namespace aether::dense {

// 'o' config constants (verbatim from pw_diffmvs_run.py / _common.py / trio).
constexpr int PROC_H = 512;      // model render height (npz native 504)
constexpr int PROC_W = 896;      // model render width
constexpr int NPZ_H = 504;       // npz intrinsics were baked at 504-tall
constexpr int NUM_DEPTH = 384;   // depth hypotheses

// scaled_K: K[1,:] *= PROC_H/NPZ_H (the npz K is for 504-tall; we render 512-tall).
// K is row-major 3x3 float32; returns the scaled copy.
std::array<float, 9> scaled_K(const std::array<float, 9>& K_npz);

// make_proj_matrices for ONE view: builds the (2,4,4) proj block for a given stage
// scale f, exactly as datasets/mvs.py: proj[0]=w2c, proj[1,:3,:3]=K, then
// proj[1,:2,:] *= f. w2c is row-major 4x4, K is row-major 3x3 (already scaled_K).
// out16 = the 2*4*4=32 floats? No: one stage's proj is (2,4,4)=32 floats. Returns
// the 32 floats [ w2c(16) , Kblock(16) ] with the Kblock's first two rows *f.
std::array<float, 32> make_proj_stage(const std::array<float, 16>& w2c,
                                      const std::array<float, 9>& K, float scale);

// The 4 production stage scales, in order stage1..stage4.
constexpr std::array<float, 4> STAGE_SCALES = {0.125f, 0.25f, 0.5f, 1.0f};

// depth_values_tensor: linspace(1/depth_max, 1/depth_min, NUM_DEPTH) in float32,
// replicating numpy.linspace's exact arithmetic (start + i*step, endpoint pinned).
std::array<float, NUM_DEPTH> depth_values(float depth_min, float depth_max);

// ── 认证 'o' 路径的选视图与深度区间 ──────────────────────────────────────
//
// ⚠️ 这三个才是 pw_diffmvs_sfm_trio.py(= 'o')实际调用的。下面 select_views /
// metric_depth_range 是 pw_diffmvs_run.py 那个**独立 runner** 的版本,语义不同,
// 保留只为兼容旧的对照实验 —— 生产路径别用。

// 一帧的可见性:该帧观测到的稀疏点 id(升序去重)。
struct FrameObs {
    std::string name;              // 帧名(并列时的 tie-break 键,与生产的元组排序一致)
    std::vector<int> point_ids;
    std::array<float, 3> center;   // 相机中心(模型单位)
};

// covis_select:MVSNet 的三角化角度视图打分,打在**模型自己的稀疏点**上。
//
// 与 ref 共享 >= 5 个点的候选才参与;对每个共享点算 ref 与候选的视线夹角 ang,
// 分段高斯打分(θ0=5°,ang<=θ0 用 σ=1,ang>θ0 用 σ=10)后求和,取前 k。
//
// ref 观测 < 8 个点、或够格候选不足 k,返回空 —— 调用方据此回退到 nearest
// (生产写法就是 `covis_select(...) or nearest(...)`)。
std::vector<std::string> covis_select(const std::string& ref,
                                      const std::vector<FrameObs>& pool,
                                      const std::vector<std::array<float, 3>>& points,
                                      int k);

// nearest:按相机中心距离升序,滤掉基线 < min_base 的,取前 k(不含 ref 自己)。
// min_base 是**模型单位** —— 生产传的是 MIN_BASE_SRC_M / s_al。
std::vector<std::string> nearest(const std::string& ref,
                                 const std::vector<FrameObs>& pool,
                                 int k, double min_base);

// drange:'o' 的深度区间。与下面 metric_depth_range 的差别不只是名字 ——
// 所有阈值都除以对齐尺度 s_al(模型单位 vs 米),且**过滤之后**还要再查一次
// 观测数 < 8。s_al = robust_align(SfM 相机中心, ARKit) 得到的相似变换尺度;
// 若端上模型已锚定到米制(SCALE-ANCHOR),s_al = 1 —— 但这要**签决**,不能默认。
std::pair<float, float> drange(const std::vector<float>& obs_pts_world,
                               const std::array<float, 16>& w2c, double s_al);

// ── 下面两个来自独立 runner,不在 'o' 路径上 ──────────────────────────────

// select_views: ref + 最近的、且**基线足够**的 n_view-1 个源视图。
//
// 纯取最近会挑到几乎同位的帧(~1cm)→ 零视差 → 近处物体深度全废,所以要求基线
// >= min_base 米。窗口太紧凑候选不够时退回纯最近(与生产同款 fail-open)。
//
// w2c 是每视图 row-major 4x4;返回的下标含 ref 本身,位置 0。
//
// ⚠️ 与生产的一处**已知**差异:numpy 的 argsort 默认 quicksort(不稳定),这里用
// 稳定排序按 (距离, 下标)。只有两帧到 ref 的距离**浮点完全相等**时结果才可能不同
// —— 实测数据里没出现过,但这是构造性差异,不是"应该一样"。
std::vector<int> select_views(const std::vector<std::array<float, 16>>& w2c,
                              int ref_local, int n_view, float min_base = 0.06f);

// 相机中心 = -R^T t(w2c row-major 4x4)。
std::array<float, 3> cam_center(const std::array<float, 16>& w2c);

// metric_depth_range: 由**该 ref 帧观测到的**稀疏点反推米制深度区间。
//
// pts_world = 这一帧观测到的世界点(每点 3 float)。观测数 < 8 直接给保守兜底
// (0.3, 4.0) —— 稀疏点太少时百分位没有意义。
//
// 生产原文:z>0.05 过滤后取 p2 与 p99.5,返回 (max(0.1, p2*0.70), p99.5*1.5)。
// 远端 margin 放这么宽是有来历的:p98*1.25 会让 5-9% 的像素在 dmax 处截断,
// 表现为远墙鼓包/拉丝。
//
// ⚠️ 生产在"过滤后一个点都不剩"时会让 numpy 抛异常;端上不能崩,这里退回兜底。
// 这是**故意**的分歧,不是漏抄。
std::pair<float, float> metric_depth_range(const std::vector<float>& pts_world,
                                           const std::array<float, 16>& w2c_ref);

}  // namespace aether::dense
