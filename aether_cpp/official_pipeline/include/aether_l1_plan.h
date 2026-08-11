// aether_l1_plan.h — [L1-PLAN 2026-07-12] "按面积挑" CasDiffMVS keyframe
// scheduling for the ghost-layer L1 arbitration (方案书 tasks/w3vn0saoo, L1
// terminal calibration a90ff524ec932e77d, 误隐=0 red line).
//
// Given the finalize model (points + registered frames + per-frame sparse
// observations) and the ghost-mask flags (aether_ghost_mask.h; band15 = the
// D@1.5cm hide candidates the arbitration must judge), this builds a
// budgeted greedy SET-COVER over the MARKED CELLS (cells containing >=1
// band15 point): each cell wants >=2 covering refs (the arbitration votes
// need >=2 independent depth reads), a ref covers a cell when it sees the
// cell head-on (non-grazing), from < 3 m, inside its frustum. The ref budget
// is a TIME budget (env AETHER_L1_BUDGET_MS, default 12000 ms) divided by the
// measured fp32 CasDiffMVS latency (960 ms/ref, A16 CPU_AND_GPU) — so on a
// 500-1000-frame capture the ref count scales with the marked AREA, never
// with the frame count. Cells left with <2 covering refs simply abstain
// downstream (fail-open -> visible; the calibrated policy).
//
// Per selected ref the plan carries everything the on-device runner (Swift
// CoreML shim) and the arbitration need, all precomputed HERE so the shim
// stays a dumb copier (parity lives in one place):
//   - 4 cascade-stage projection matrices, the exact make_proj_matrices port
//     (pw_diffmvs_common.py): per view a (2,4,4) float32 pair [w2c | K-embed],
//     stage factors 0.125/0.25/0.5/1.0 scaling the first two K rows;
//   - dv: 384-bin inverse-depth linspace from the ref's own observed sparse
//     depths (p2*0.70 .. p99.5*1.5, floors 0.1 — pw_diffmvs_sfm.py drange);
//   - 4 source views by covis_select (MVSNet triangulation-angle score,
//     pw_diffmvs_sfm.py:176-201 port; fallback nearest with min_base 0.06 m).
//
// Outputs (all under <db_dir>/):
//   arbitration_plan.json  — consumed by the Swift runner + Mac harness
//   arbitration_plan.bin   — compact twin for the C++ arbitration (no JSON
//                            parser in the archive)
//   arbitration_points.bin — per in-region point: flag index / float32-cast
//                            xyz / sd / local_off (the arbitration input)
//
// Header-only, no deps beyond aether_ghost_mask.h. Deterministic: greedy
// ties break on (more sparse obs, lower frame_id).
#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include "aether_ghost_mask.h"

namespace aether_l1 {

// --- model contract (CasDiffMVS_fp32.mlpackage trace, 一手核实资产盘点) ---
constexpr int kProcW = 896;
constexpr int kProcH = 512;
constexpr int kNumViews = 5;   // 1 ref + 4 src (static trace)
constexpr int kNumDepth = 384; // dv bins
// --- scheduling ---
constexpr int kDefaultBudgetMs = 12000;  // env AETHER_L1_BUDGET_MS overrides
constexpr int kMsPerRef = 960;           // fp32 A16 CPU_AND_GPU median (07-08)
constexpr int kCoverNeed = 2;            // >=2 refs per marked cell (vote_min)
constexpr double kMaxRefDistM = 3.0;     // ref camera to cell centroid
constexpr double kGrazeMinCos = 0.25;    // |view_ray . n_up| >= this (~14.5°)
constexpr int kMinObsForRange = 8;       // drange needs >=8 sparse depths
constexpr int kCovisMinShared = 5;       // covis_select shared-track floor
constexpr double kSrcMinBaseM = 0.06;    // nearest-fallback baseline floor

struct L1Frame {
  int frame_id = -1;
  double w2c[16] = {0};  // CamFromWorld, row-major 4x4 (bottom row 0 0 0 1)
  double k[4] = {0};     // fx, fy, cx, cy at kProcW x kProcH (model res)
  std::string jpeg;      // absolute JPEG path; empty = ineligible as a view
  std::vector<int32_t> obs;  // observed rows into the track-point array
};

struct L1PlanRef {
  int frame = -1;                 // index into the frames vector (the ref)
  int srcs[kNumViews - 1] = {-1, -1, -1, -1};  // frame indices (4 sources)
  double dmin = 0.3, dmax = 4.0;
  std::vector<float> dv;          // kNumDepth inverse depths (ascending)
  std::vector<int64_t> cells;     // marked cells this ref newly covered
};

struct L1Plan {
  std::vector<L1PlanRef> refs;
  int budget_ms = kDefaultBudgetMs;
  int budget_refs = 0;
  int n_marked_cells = 0;
  int n_cells_cov2 = 0;   // fully covered (>= kCoverNeed refs)
  int n_cells_cov1 = 0;   // partially covered (will abstain on vote_min)
  int n_cells_cov0 = 0;   // uncovered -> abstain (= visible)
  int n_refs_dropped_srcs = 0;  // eligible refs dropped for lacking 4 srcs
  int n_frames_missing_jpeg = 0;  // [L1-ROBUST] fed-path validation drops
  double plane_n[3] = {0, 0, 0};
  double plane_d = 0;
};

namespace detail {

inline double Dot3(const double a[3], const double b[3]) {
  return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

// Camera center from a row-major 4x4 CamFromWorld: c = -R^T t.
inline void CamCenter(const double w2c[16], double c[3]) {
  const double r00 = w2c[0], r01 = w2c[1], r02 = w2c[2], tx = w2c[3];
  const double r10 = w2c[4], r11 = w2c[5], r12 = w2c[6], ty = w2c[7];
  const double r20 = w2c[8], r21 = w2c[9], r22 = w2c[10], tz = w2c[11];
  c[0] = -(r00 * tx + r10 * ty + r20 * tz);
  c[1] = -(r01 * tx + r11 * ty + r21 * tz);
  c[2] = -(r02 * tx + r12 * ty + r22 * tz);
}

// World point -> camera frame (row-major 4x4 CamFromWorld).
inline void W2C(const double w2c[16], const double p[3], double out[3]) {
  out[0] = w2c[0] * p[0] + w2c[1] * p[1] + w2c[2] * p[2] + w2c[3];
  out[1] = w2c[4] * p[0] + w2c[5] * p[1] + w2c[6] * p[2] + w2c[7];
  out[2] = w2c[8] * p[0] + w2c[9] * p[1] + w2c[10] * p[2] + w2c[11];
}

// np.linspace(start, stop, num) port (float64 math, endpoint pinned), cast
// float32 at the end — matches pw_diffmvs_common.depth_values_tensor bit-wise.
inline void LinspaceF32(double start, double stop, int num, float* out) {
  const double step = (stop - start) / static_cast<double>(num - 1);
  for (int i = 0; i < num; ++i)
    out[i] = static_cast<float>(static_cast<double>(i) * step + start);
  out[num - 1] = static_cast<float>(stop);
}

// pw_diffmvs_sfm.py drange port: percentiles over the ref's observed sparse
// depths (z > 0.05), p2*0.70 .. p99.5*1.5, floors (0.1, —). Falls back to
// (0.3, 4.0) below kMinObsForRange usable depths.
inline void DepthRange(const std::vector<double>& z_sorted, double* dmin,
                       double* dmax) {
  if (z_sorted.size() < static_cast<size_t>(kMinObsForRange)) {
    *dmin = 0.3;
    *dmax = 4.0;
    return;
  }
  const double lo = aether_ghost::detail::PercentileSorted(z_sorted, 2.0);
  const double hi = aether_ghost::detail::PercentileSorted(z_sorted, 99.5);
  *dmin = std::max(0.1, lo * 0.70);
  *dmax = hi * 1.5;
}

}  // namespace detail

// covis_select port (pw_diffmvs_sfm.py:176-201): MVSNet triangulation-angle
// score over shared sparse tracks; top-k frames. Returns false when the ref
// has <8 obs or fewer than k frames scored (caller falls back to nearest).
// Scores use plain double math; selection ties break on higher score then
// lower frame index (deterministic; the Python reference sorted
// (score, name) desc — name order equals frame order for zero-padded names).
inline bool CovisSelectTopK(const std::vector<L1Frame>& frames,
                            const std::vector<std::vector<int32_t>>& obs_sorted,
                            const std::vector<int>& pool, int ref, int k,
                            const double* pts, int out_srcs[]) {
  const std::vector<int32_t>& ro = obs_sorted[static_cast<size_t>(ref)];
  if (ro.size() < static_cast<size_t>(kMinObsForRange)) return false;
  std::vector<uint8_t> in_ref;
  int32_t max_row = 0;
  for (const int32_t r : ro) max_row = std::max(max_row, r);
  in_ref.assign(static_cast<size_t>(max_row) + 1, 0);
  for (const int32_t r : ro) in_ref[static_cast<size_t>(r)] = 1;
  double c_ref[3];
  detail::CamCenter(frames[static_cast<size_t>(ref)].w2c, c_ref);
  constexpr double t0 = 5.0, s1 = 1.0, s2 = 10.0;
  std::vector<std::pair<double, int>> scored;  // (score, frame idx)
  std::vector<int32_t> shared;
  for (const int m : pool) {
    if (m == ref) continue;
    shared.clear();
    for (const int32_t r : obs_sorted[static_cast<size_t>(m)])
      if (r <= max_row && in_ref[static_cast<size_t>(r)]) shared.push_back(r);
    if (shared.size() < static_cast<size_t>(kCovisMinShared)) continue;
    double c_m[3];
    detail::CamCenter(frames[static_cast<size_t>(m)].w2c, c_m);
    double sc = 0.0;
    for (const int32_t r : shared) {
      const double* p = &pts[static_cast<size_t>(r) * 3];
      double v1[3] = {p[0] - c_ref[0], p[1] - c_ref[1], p[2] - c_ref[2]};
      double v2[3] = {p[0] - c_m[0], p[1] - c_m[1], p[2] - c_m[2]};
      const double n1 = std::sqrt(detail::Dot3(v1, v1)) + 1e-9;
      const double n2 = std::sqrt(detail::Dot3(v2, v2)) + 1e-9;
      double cosang = detail::Dot3(v1, v2) / (n1 * n2);
      cosang = std::min(1.0, std::max(-1.0, cosang));
      const double ang = std::acos(cosang) * 180.0 / M_PI;
      const double s = ang <= t0 ? s1 : s2;
      sc += std::exp(-(ang - t0) * (ang - t0) / (2.0 * s * s));
    }
    scored.emplace_back(sc, m);
  }
  if (scored.size() < static_cast<size_t>(k)) return false;
  std::sort(scored.begin(), scored.end(), [](const auto& a, const auto& b) {
    if (a.first != b.first) return a.first > b.first;
    return a.second < b.second;
  });
  for (int i = 0; i < k; ++i) out_srcs[i] = scored[static_cast<size_t>(i)].second;
  return true;
}

// nearest-with-baseline fallback (pw_diffmvs_sfm.py nearest, min_base=0.06).
inline bool NearestTopK(const std::vector<L1Frame>& frames,
                        const std::vector<int>& pool, int ref, int k,
                        double min_base, int out_srcs[]) {
  double c_ref[3];
  detail::CamCenter(frames[static_cast<size_t>(ref)].w2c, c_ref);
  std::vector<std::pair<double, int>> d;
  for (const int m : pool) {
    if (m == ref) continue;
    double c_m[3];
    detail::CamCenter(frames[static_cast<size_t>(m)].w2c, c_m);
    const double dx = c_m[0] - c_ref[0], dy = c_m[1] - c_ref[1],
                 dz = c_m[2] - c_ref[2];
    d.emplace_back(std::sqrt(dx * dx + dy * dy + dz * dz), m);
  }
  std::sort(d.begin(), d.end());
  int got = 0;
  for (const auto& [dist, m] : d) {
    if (dist < min_base) continue;
    out_srcs[got++] = m;
    if (got == k) return true;
  }
  return false;
}

// ── the budgeted greedy set cover ──────────────────────────────────────────
// cloud_xyz/flags: the ghost-mask cloud (float32-cast coords, flag bytes).
// pts/n_pts + frames[].obs: the track model driving drange/covis (full
// precision; the SAME reconstruction in production).
inline bool BuildL1Plan(const double* cloud_xyz, const uint8_t* flags,
                        size_t n_cloud, const double plane_n[3],
                        double plane_d, const double* pts, size_t n_pts,
                        const std::vector<L1Frame>& frames, int budget_ms,
                        L1Plan* out) {
  (void)n_pts;
  out->refs.clear();
  out->budget_ms = budget_ms;
  out->budget_refs = std::max(2, budget_ms / kMsPerRef);
  out->plane_n[0] = plane_n[0];
  out->plane_n[1] = plane_n[1];
  out->plane_n[2] = plane_n[2];
  out->plane_d = plane_d;

  // 1. marked cells (>=1 band15 point) + centroid of their band15 members.
  struct CellAgg {
    double sum[3] = {0, 0, 0};
    int n = 0;
  };
  std::unordered_map<int64_t, CellAgg> cells;
  for (size_t i = 0; i < n_cloud; ++i) {
    if (!(flags[i] & aether_ghost::kFlagBand15)) continue;
    const double* p = &cloud_xyz[i * 3];
    CellAgg& a = cells[aether_ghost::detail::CellKey(p[0], p[2])];
    a.sum[0] += p[0];
    a.sum[1] += p[1];
    a.sum[2] += p[2];
    ++a.n;
  }
  out->n_marked_cells = static_cast<int>(cells.size());
  if (cells.empty()) return true;  // nothing to arbitrate — empty plan
  std::vector<int64_t> cell_keys;
  std::vector<double> cell_c;  // centroids, 3 per cell
  cell_keys.reserve(cells.size());
  for (const auto& [key, a] : cells) {
    cell_keys.push_back(key);
    cell_c.push_back(a.sum[0] / a.n);
    cell_c.push_back(a.sum[1] / a.n);
    cell_c.push_back(a.sum[2] / a.n);
  }
  // deterministic order (unordered_map iteration is not)
  {
    std::vector<size_t> idx(cell_keys.size());
    for (size_t i = 0; i < idx.size(); ++i) idx[i] = i;
    std::sort(idx.begin(), idx.end(), [&](size_t a, size_t b) {
      return cell_keys[a] < cell_keys[b];
    });
    std::vector<int64_t> k2(idx.size());
    std::vector<double> c2(idx.size() * 3);
    for (size_t i = 0; i < idx.size(); ++i) {
      k2[i] = cell_keys[idx[i]];
      c2[i * 3 + 0] = cell_c[idx[i] * 3 + 0];
      c2[i * 3 + 1] = cell_c[idx[i] * 3 + 1];
      c2[i * 3 + 2] = cell_c[idx[i] * 3 + 2];
    }
    cell_keys.swap(k2);
    cell_c.swap(c2);
  }

  // 2. view pool (any frame usable as ref or src) + sorted-unique obs.
  // [L1-ROBUST 2026-07-12] Plan-time JPEG-path validation. A re-shot capture
  // slot overwrites the file under a NEW tap-suffix, so the frame's fed jsonl
  // path (recorded at feed time) can dangle. A dangling path fed to the Swift
  // runner aborted the WHOLE chain (cap48: cell_85_slot_9_tap-484 dead → 1/11
  // refs → 100% abstain). Here we drop any frame whose JPEG no longer exists
  // from the view pool entirely: it can never be picked as ref or src, so the
  // plan carries only live paths. Marked cells that thereby lose all covers
  // fall to cov0 and abstain downstream (fail-open == visible; the calibrated
  // policy). Counted separately from n_refs_dropped_srcs.
  std::vector<int> pool;
  std::vector<std::vector<int32_t>> obs_sorted(frames.size());
  for (size_t f = 0; f < frames.size(); ++f) {
    if (frames[f].jpeg.empty()) continue;
    std::error_code fs_ec;
    if (!std::filesystem::exists(frames[f].jpeg, fs_ec) || fs_ec) {
      ++out->n_frames_missing_jpeg;
      continue;
    }
    obs_sorted[f] = frames[f].obs;
    std::sort(obs_sorted[f].begin(), obs_sorted[f].end());
    obs_sorted[f].erase(
        std::unique(obs_sorted[f].begin(), obs_sorted[f].end()),
        obs_sorted[f].end());
    pool.push_back(static_cast<int>(f));
  }
  if (pool.size() < static_cast<size_t>(kNumViews)) return true;  // no plan

  // 3. eligibility: frame f covers cell c.
  const int n_cells = static_cast<int>(cell_keys.size());
  std::vector<std::vector<int32_t>> covers(frames.size());
  for (const int f : pool) {
    const L1Frame& fr = frames[static_cast<size_t>(f)];
    double c_f[3];
    detail::CamCenter(fr.w2c, c_f);
    for (int c = 0; c < n_cells; ++c) {
      const double* cc = &cell_c[static_cast<size_t>(c) * 3];
      const double dx = cc[0] - c_f[0], dy = cc[1] - c_f[1],
                   dz = cc[2] - c_f[2];
      const double dist = std::sqrt(dx * dx + dy * dy + dz * dz);
      if (dist >= kMaxRefDistM || dist < 1e-6) continue;
      const double ray[3] = {dx / dist, dy / dist, dz / dist};
      if (std::fabs(detail::Dot3(ray, plane_n)) < kGrazeMinCos) continue;
      double pc[3];
      detail::W2C(fr.w2c, cc, pc);
      if (pc[2] <= 0.05) continue;
      const double u = fr.k[0] * pc[0] / pc[2] + fr.k[2];
      const double v = fr.k[1] * pc[1] / pc[2] + fr.k[3];
      if (u < 1.0 || u >= kProcW - 1 || v < 1.0 || v >= kProcH - 1) continue;
      covers[static_cast<size_t>(f)].push_back(c);
    }
  }

  // 4. greedy: maximize newly-satisfied cell-needs per pick; ties -> more
  // sparse obs, then lower frame_id.
  std::vector<int> need(static_cast<size_t>(n_cells), kCoverNeed);
  std::vector<uint8_t> picked(frames.size(), 0);
  while (static_cast<int>(out->refs.size()) < out->budget_refs) {
    int best = -1, best_gain = 0;
    for (const int f : pool) {
      if (picked[static_cast<size_t>(f)]) continue;
      int gain = 0;
      for (const int32_t c : covers[static_cast<size_t>(f)])
        if (need[static_cast<size_t>(c)] > 0) ++gain;
      if (gain == 0) continue;
      if (best < 0) {
        best = f;
        best_gain = gain;
        continue;
      }
      const size_t bf = static_cast<size_t>(best);
      if (gain > best_gain ||
          (gain == best_gain &&
           (obs_sorted[static_cast<size_t>(f)].size() >
                obs_sorted[bf].size() ||
            (obs_sorted[static_cast<size_t>(f)].size() ==
                 obs_sorted[bf].size() &&
             frames[static_cast<size_t>(f)].frame_id <
                 frames[bf].frame_id)))) {
        best = f;
        best_gain = gain;
      }
    }
    if (best < 0) break;  // nothing left to gain
    picked[static_cast<size_t>(best)] = 1;

    // sources for this ref (covis, fallback nearest); drop the ref if <4.
    L1PlanRef ref;
    ref.frame = best;
    if (!CovisSelectTopK(frames, obs_sorted, pool, best, kNumViews - 1, pts,
                         ref.srcs) &&
        !NearestTopK(frames, pool, best, kNumViews - 1, kSrcMinBaseM,
                     ref.srcs)) {
      ++out->n_refs_dropped_srcs;
      continue;  // picked[] stays set so we don't retry it
    }
    // drange + dv from the ref's own observed sparse depths.
    std::vector<double> z;
    z.reserve(obs_sorted[static_cast<size_t>(best)].size());
    for (const int32_t r : obs_sorted[static_cast<size_t>(best)]) {
      double pc[3];
      detail::W2C(frames[static_cast<size_t>(best)].w2c,
                  &pts[static_cast<size_t>(r) * 3], pc);
      if (pc[2] > 0.05) z.push_back(pc[2]);
    }
    std::sort(z.begin(), z.end());
    detail::DepthRange(z, &ref.dmin, &ref.dmax);
    ref.dv.resize(kNumDepth);
    detail::LinspaceF32(1.0 / ref.dmax, 1.0 / ref.dmin, kNumDepth,
                        ref.dv.data());
    for (const int32_t c : covers[static_cast<size_t>(best)]) {
      if (need[static_cast<size_t>(c)] > 0) {
        --need[static_cast<size_t>(c)];
        ref.cells.push_back(cell_keys[static_cast<size_t>(c)]);
      }
    }
    out->refs.push_back(std::move(ref));
  }
  for (int c = 0; c < n_cells; ++c) {
    if (need[static_cast<size_t>(c)] == 0)
      ++out->n_cells_cov2;
    else if (need[static_cast<size_t>(c)] < kCoverNeed)
      ++out->n_cells_cov1;
    else
      ++out->n_cells_cov0;
  }
  return true;
}

// ── writers ────────────────────────────────────────────────────────────────

namespace detail {

inline void JsonEscape(const std::string& s, std::string* out) {
  for (const char ch : s) {
    if (ch == '"' || ch == '\\') out->push_back('\\');
    out->push_back(ch);
  }
}

// One (2,4,4) float32 slot pair per view, stage-scaled — the make_proj_matrices
// port. `stage_f` scales the first two rows of the K slot. Appends 32 floats.
inline void ProjPairF32(const L1Frame& fr, double stage_f,
                        std::vector<float>* out) {
  // slot 0: w2c float32-cast
  for (int i = 0; i < 16; ++i)
    out->push_back(static_cast<float>(fr.w2c[i]));
  // slot 1: zeros with K in [:3,:3]; rows 0-1 scaled by stage_f IN float32
  float kslot[16] = {0};
  kslot[0] = static_cast<float>(fr.k[0]);   // fx
  kslot[2] = static_cast<float>(fr.k[2]);   // cx
  kslot[5] = static_cast<float>(fr.k[1]);   // fy
  kslot[6] = static_cast<float>(fr.k[3]);   // cy
  kslot[10] = 1.0f;
  const float f = static_cast<float>(stage_f);
  for (int i = 0; i < 8; ++i) kslot[i] *= f;  // rows 0-1 (all 4 cols)
  for (int i = 0; i < 16; ++i) out->push_back(kslot[i]);
}

inline bool WriteFileAtomic(const std::string& path, const void* data,
                            size_t size) {
  const std::string tmp = path + ".tmp";
  FILE* f = std::fopen(tmp.c_str(), "wb");
  if (!f) return false;
  const size_t w = std::fwrite(data, 1, size, f);
  std::fclose(f);
  if (w != size || std::rename(tmp.c_str(), path.c_str()) != 0) {
    std::remove(tmp.c_str());
    return false;
  }
  return true;
}

}  // namespace detail

// arbitration_plan.json — the Swift runner / Mac harness contract.
// proj arrays are view-major flattened (5 views x 2 slots x 4 x 4 = 160
// floats per stage), printed %.9g so float32 round-trips exactly.
inline bool WriteL1PlanJson(const std::string& path, const L1Plan& plan,
                            const std::vector<L1Frame>& frames) {
  std::string j;
  j.reserve(1 << 20);
  char buf[192];
  auto num = [&](double v, const char* fmt) {
    std::snprintf(buf, sizeof(buf), fmt, v);
    j += buf;
  };
  j += "{\"version\":1,\"w\":896,\"h\":512,\"n_views\":5,\"n_depth\":384,";
  std::snprintf(buf, sizeof(buf), "\"budget_ms\":%d,\"ms_per_ref\":%d,",
                plan.budget_ms, kMsPerRef);
  j += buf;
  std::snprintf(buf, sizeof(buf), "\"budget_refs\":%d,", plan.budget_refs);
  j += buf;
  j += "\"plane_n\":[";
  num(plan.plane_n[0], "%.17g");
  j += ",";
  num(plan.plane_n[1], "%.17g");
  j += ",";
  num(plan.plane_n[2], "%.17g");
  j += "],\"plane_d\":";
  num(plan.plane_d, "%.17g");
  std::snprintf(buf, sizeof(buf),
                ",\"n_marked_cells\":%d,\"n_cells_cov2\":%d,"
                "\"n_cells_cov1\":%d,\"n_cells_cov0\":%d,"
                "\"n_refs_dropped_srcs\":%d,\"n_frames_missing_jpeg\":%d,",
                plan.n_marked_cells, plan.n_cells_cov2, plan.n_cells_cov1,
                plan.n_cells_cov0, plan.n_refs_dropped_srcs,
                plan.n_frames_missing_jpeg);
  j += buf;
  j += "\"refs\":[";
  static const double kStageF[4] = {0.125, 0.25, 0.5, 1.0};
  static const char* kStageName[4] = {"stage1", "stage2", "stage3", "stage4"};
  for (size_t ri = 0; ri < plan.refs.size(); ++ri) {
    const L1PlanRef& r = plan.refs[ri];
    if (ri) j += ",";
    const L1Frame& rf = frames[static_cast<size_t>(r.frame)];
    std::snprintf(buf, sizeof(buf), "{\"frame_id\":%d,\"jpeg\":\"",
                  rf.frame_id);
    j += buf;
    detail::JsonEscape(rf.jpeg, &j);
    j += "\",\"views\":[";
    int view_idx[kNumViews];
    view_idx[0] = r.frame;
    for (int i = 0; i < kNumViews - 1; ++i) view_idx[i + 1] = r.srcs[i];
    for (int v = 0; v < kNumViews; ++v) {
      const L1Frame& vf = frames[static_cast<size_t>(view_idx[v])];
      if (v) j += ",";
      std::snprintf(buf, sizeof(buf), "{\"frame_id\":%d,\"jpeg\":\"",
                    vf.frame_id);
      j += buf;
      detail::JsonEscape(vf.jpeg, &j);
      j += "\"}";
    }
    j += "],";
    std::snprintf(buf, sizeof(buf), "\"dmin\":%.9g,\"dmax\":%.9g,\"dv\":[",
                  r.dmin, r.dmax);
    j += buf;
    for (int i = 0; i < kNumDepth; ++i) {
      if (i) j += ",";
      num(static_cast<double>(r.dv[static_cast<size_t>(i)]), "%.9g");
    }
    j += "],\"proj\":{";
    for (int st = 0; st < 4; ++st) {
      if (st) j += ",";
      j += "\"";
      j += kStageName[st];
      j += "\":[";
      std::vector<float> p;
      p.reserve(kNumViews * 32);
      for (int v = 0; v < kNumViews; ++v)
        detail::ProjPairF32(frames[static_cast<size_t>(view_idx[v])],
                            kStageF[st], &p);
      for (size_t i = 0; i < p.size(); ++i) {
        if (i) j += ",";
        num(static_cast<double>(p[i]), "%.9g");
      }
      j += "]";
    }
    j += "},\"cells\":[";
    for (size_t i = 0; i < r.cells.size(); ++i) {
      if (i) j += ",";
      std::snprintf(buf, sizeof(buf), "%lld",
                    static_cast<long long>(r.cells[i]));
      j += buf;
    }
    j += "]}";
  }
  j += "]}\n";
  return detail::WriteFileAtomic(path, j.data(), j.size());
}

// arbitration_plan.bin — the C++ arbitration twin (ref views only).
// Layout (LE): u32 magic 'A3L1'(0x314C3341), u32 version=1,
//   f64 plane_n[3], f64 plane_d, u32 H, u32 W, u32 n_refs,
//   then per ref: i32 frame_id, f64 k[4], f64 w2c[16].
inline bool WriteL1PlanBin(const std::string& path, const L1Plan& plan,
                           const std::vector<L1Frame>& frames) {
  std::vector<uint8_t> b;
  b.reserve(64 + plan.refs.size() * 168);
  auto put = [&](const void* p, size_t n) {
    const uint8_t* u = static_cast<const uint8_t*>(p);
    b.insert(b.end(), u, u + n);
  };
  const uint32_t magic = 0x314C3341u, ver = 1u;
  put(&magic, 4);
  put(&ver, 4);
  put(plan.plane_n, 24);
  put(&plan.plane_d, 8);
  const uint32_t H = kProcH, W = kProcW;
  put(&H, 4);
  put(&W, 4);
  const uint32_t nr = static_cast<uint32_t>(plan.refs.size());
  put(&nr, 4);
  for (const L1PlanRef& r : plan.refs) {
    const L1Frame& rf = frames[static_cast<size_t>(r.frame)];
    const int32_t fid = rf.frame_id;
    put(&fid, 4);
    put(rf.k, 32);
    put(rf.w2c, 128);
  }
  return detail::WriteFileAtomic(path, b.data(), b.size());
}

// arbitration_points.bin — per IN-REGION point sidecar (SoA, LE):
//   u32 magic 'A3LP'(0x504C3341), u32 version=1, u32 n,
//   u32 flag_idx[n], f32 xyz[3n] (the float32-cast coords the mask was
//   computed from — lossless as f32), f64 sd[n], f64 local_off[n].
inline bool WriteL1PointsSidecar(const std::string& path,
                                 const double* cloud_xyz,
                                 const uint8_t* flags, size_t n_cloud,
                                 const std::vector<double>& sd,
                                 const std::vector<double>& local_off) {
  std::vector<uint32_t> idx;
  for (size_t i = 0; i < n_cloud; ++i)
    if (flags[i] & aether_ghost::kFlagInRegion)
      idx.push_back(static_cast<uint32_t>(i));
  std::vector<uint8_t> b;
  b.reserve(12 + idx.size() * 36);
  auto put = [&](const void* p, size_t n) {
    const uint8_t* u = static_cast<const uint8_t*>(p);
    b.insert(b.end(), u, u + n);
  };
  const uint32_t magic = 0x504C3341u, ver = 1u,
                 n = static_cast<uint32_t>(idx.size());
  put(&magic, 4);
  put(&ver, 4);
  put(&n, 4);
  put(idx.data(), idx.size() * 4);
  for (const uint32_t i : idx) {
    const float xyz[3] = {static_cast<float>(cloud_xyz[i * 3 + 0]),
                          static_cast<float>(cloud_xyz[i * 3 + 1]),
                          static_cast<float>(cloud_xyz[i * 3 + 2])};
    put(xyz, 12);
  }
  for (const uint32_t i : idx) put(&sd[i], 8);
  for (const uint32_t i : idx) put(&local_off[i], 8);
  return detail::WriteFileAtomic(path, b.data(), b.size());
}

}  // namespace aether_l1
