// aether_ghost_mask.h — [GHOST-MASK 2026-07-12] per-point ghost-layer display
// mask pass (L1/L2 data side of the "选区前 100% 无鬼层" campaign).
//
// C++ port of the Phase0 host reference (scratchpad/ghost_phase0/ghost_lib.py:
// fit_floor_plane + floor_labels), which itself unifies the per-cell bimodal
// detector of cap47_diag/bimodal_cells.py (identical params: cell 20cm, >=12
// pts, gap>=1.2cm, sep>=1sigma, minor>=0.25) with the D band gate (mode-anchored
// global floor plane + per-cell local anchor + band). The gate band here is the
// USER-SIGNED 1.5cm (D@1.5cm, GT_FINDINGS 2026-07-12); the Phase0 1.0cm form is
// also emitted as a reference bit.
//
// Output: one flag byte per point (see GhostFlagBits). DISPLAY-ONLY metadata —
// nothing here deletes or moves a point; the delivered PLY/db stay byte
// identical (全量交付铁律). Points are HIDE-CANDIDATES only; the L1 CasDiffMVS
// 1-bit arbitration decides rescue (误隐=0 red line) downstream.
//
// PARITY CONTRACT (host gate): flags must be BIT-IDENTICAL to the Python
// reference (ghost_l1/gen_ref_flags.py) on the cap46/47 device clouds. The
// arithmetic below therefore mirrors NumPy semantics exactly where reductions
// feed thresholds (empirically calibrated on numpy 2.4.2 / macOS arm64):
//   - P @ n (matvec), 3-dots, 3-norms, axis-0 means: plain sequential
//     mul/add, NO fma (verified bit-equal vs numpy on the real clouds);
//   - 1-D contiguous mean/std (np.add.reduce): numpy pairwise summation,
//     scalar 8-accumulator variant + n/2-rounded-to-8 recursive split
//     (verified bit-equal for n in 3..1000);
//   - np.percentile(axis=0, linear), np.arange(float step), np.histogram
//     (array bins, last edge inclusive), np.median: exact ports;
//   - covariance (X^T X) + 3x3 SVD smallest singular vector: NOT bit-equal to
//     LAPACK dgesdd (Accelerate blocked/FMA accumulation is opaque) — a cyclic
//     Jacobi eigensolver is used; plane differs from numpy at ~1e-14, which
//     flips a threshold flag only if a point sits within ~1e-14 of a gate
//     (probability ~1e-7 per capture; the parity harness catches it if ever).
// fp-contract is forced off inside every function (pragma) so inclusion into
// production TUs cannot re-fuse the calibrated expressions.
#pragma once

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <unordered_map>
#include <vector>

namespace aether_ghost {

#if defined(__clang__)
#define AETHER_GHOST_NO_CONTRACT _Pragma("clang fp contract(off)")
#else
#define AETHER_GHOST_NO_CONTRACT
#endif

// --- parameters (verbatim ghost_lib.py; do NOT retune without re-running the
// --- Python parity reference) ---
constexpr double kHalfGapBand = 0.015;  // D band @1.5cm (user-signed)
constexpr double kHalfGapRef = 0.010;   // Phase0 1.0cm band (reference bit)
constexpr double kSlab = 0.08;          // floor slab half-width
constexpr double kCell = 0.20;          // XZ cell size (m)
constexpr int kMinCellPts = 12;         // bimodal detector min pts / cell
constexpr double kAnchorTol = 0.010;    // plane refine inlier tol
constexpr double kAnchorWin = 0.012;    // footprint/local anchor window
constexpr double kBimFrac = 0.25;       // minor-mode fraction gate
constexpr double kBimGap = 0.012;       // mode gap gate (m)
constexpr double kBimSep = 1.0;         // separation index gate
constexpr int kFootprintMin = 5;        // anchor pts for a footprint cell
constexpr int kOverheadMax = 5;         // above-slab pts allowed in a clean cell
constexpr double kOverheadHi = 0.5;     // overhead window top (m)

enum GhostFlagBits : uint8_t {
  kFlagInRegion = 1u << 0,   // footprint cell & |sd| < 8cm slab
  kFlagBand15 = 1u << 1,     // D@1.5cm hide-candidate (display gate)
  kFlagCellGhost = 1u << 2,  // bimodal-cell ghost-mode member
  kFlagInClean = 1u << 3,    // cell has no overhead structure
  kFlagBand10 = 1u << 4,     // Phase0 D@1.0cm band (reference only)
  // [L1-ARBITRATE 2026-07-12] written by aether_l1_arbitrate.h (NOT by the
  // ComputeGhostMask pass): the CasDiffMVS 1-bit arbitration verdict over the
  // band15 hide-candidates. Neither bit set on a band15 point = ABSTAIN
  // (fail-open -> visible, calibrated 误隐=0 policy).
  kFlagL1Rescued = 1u << 5,    // dense evidence pins it to real geometry
  kFlagL1Confirmed = 1u << 6,  // rays actively convict it (hide)
};

// [L1-ARBITRATE 2026-07-12] Optional per-point intermediates of the pass —
// exactly the values the pass already computes; exposing them lets the L1
// plan/arbitration sidecars reuse the same signed distances / local anchors
// without re-deriving them (zero arithmetic added to the parity-gated path).
struct GhostMaskIntermediates {
  std::vector<double> sd;         // signed distance to the fitted floor plane
  std::vector<double> local_off;  // per-cell local floor anchor (0 if none)
};

struct GhostMaskStats {
  int64_t n_points = 0;
  int64_t n_region = 0;
  int64_t n_band15 = 0;
  int64_t n_band10 = 0;
  int64_t n_cell_ghost = 0;
  int64_t n_clean = 0;
  int64_t n_bim_cells = 0;
  int64_t n_floor_cells = 0;  // cells with >= kMinCellPts region points
  double plane_n[3] = {0, 0, 0};
  double plane_d = 0;
};

namespace detail {

// numpy pairwise summation, scalar 8-accumulator variant (calibrated bit-equal
// to np.add.reduce on contiguous float64, numpy 2.4.2 / macOS arm64).
inline double PairwiseSum(const double* a, size_t n) {
  AETHER_GHOST_NO_CONTRACT
  if (n < 8) {
    double res = 0.0;
    for (size_t i = 0; i < n; ++i) res += a[i];
    return res;
  }
  if (n <= 128) {
    double r0 = a[0], r1 = a[1], r2 = a[2], r3 = a[3];
    double r4 = a[4], r5 = a[5], r6 = a[6], r7 = a[7];
    size_t i = 8;
    for (; i + 8 <= n; i += 8) {
      r0 += a[i + 0];
      r1 += a[i + 1];
      r2 += a[i + 2];
      r3 += a[i + 3];
      r4 += a[i + 4];
      r5 += a[i + 5];
      r6 += a[i + 6];
      r7 += a[i + 7];
    }
    double res = ((r0 + r1) + (r2 + r3)) + ((r4 + r5) + (r6 + r7));
    for (; i < n; ++i) res += a[i];
    return res;
  }
  size_t n2 = n / 2;
  n2 -= n2 % 8;
  return PairwiseSum(a, n2) + PairwiseSum(a + n2, n - n2);
}

inline double Mean1D(const std::vector<double>& v) {
  return PairwiseSum(v.data(), v.size()) / static_cast<double>(v.size());
}

// np.std (ddof=0): sqrt(mean((x - mean(x))^2)), both reductions pairwise.
inline double Std1D(const std::vector<double>& v) {
  AETHER_GHOST_NO_CONTRACT
  const double m = Mean1D(v);
  std::vector<double> sq(v.size());
  for (size_t i = 0; i < v.size(); ++i) {
    const double d = v[i] - m;
    sq[i] = d * d;
  }
  return std::sqrt(PairwiseSum(sq.data(), sq.size()) /
                   static_cast<double>(v.size()));
}

// np.median on a scratch copy (sorts; even n -> mean of the two middles).
inline double Median1D(std::vector<double> v) {
  std::sort(v.begin(), v.end());
  const size_t n = v.size();
  if (n % 2 == 1) return v[n / 2];
  return (v[n / 2 - 1] + v[n / 2]) / 2.0;
}

// np.percentile(sorted column, q, method='linear'). `sorted` ascending.
inline double PercentileSorted(const std::vector<double>& sorted, double q100) {
  AETHER_GHOST_NO_CONTRACT
  const double q = q100 / 100.0;
  const double pos = q * static_cast<double>(sorted.size() - 1);
  double prev = std::floor(pos);
  const double t = pos - prev;
  const size_t lo = static_cast<size_t>(prev);
  const double a = sorted[lo];
  const double b = sorted[std::min(lo + 1, sorted.size() - 1)];
  const double diff = b - a;
  double r = a + diff * t;               // numpy _lerp
  if (t >= 0.5) r = b - diff * (1 - t);  // numpy _lerp t>=0.5 branch
  return r;
}

// np.arange(start, stop, step) fill semantics (ctors.c _fill): e[0]=start,
// e[1]=start+step, delta=e[1]-e[0], e[i]=start+i*delta.
inline std::vector<double> Arange(double start, double stop, double step) {
  AETHER_GHOST_NO_CONTRACT
  const double len_d = std::ceil((stop - start) / step);
  const int64_t len = len_d > 0 ? static_cast<int64_t>(len_d) : 0;
  std::vector<double> e(static_cast<size_t>(len));
  if (len > 0) e[0] = start;
  if (len > 1) {
    e[1] = start + step;
    const double delta = e[1] - e[0];
    for (int64_t i = 2; i < len; ++i)
      e[static_cast<size_t>(i)] = start + static_cast<double>(i) * delta;
  }
  return e;
}

// np.histogram(values, bins=edges): left-closed bins, last edge inclusive.
inline std::vector<int64_t> Histogram(const std::vector<double>& values,
                                      const std::vector<double>& edges) {
  const size_t nbins = edges.size() - 1;
  std::vector<int64_t> h(nbins, 0);
  for (const double y : values) {
    if (y < edges.front() || y > edges.back()) continue;
    // searchsorted(edges, y, 'right') - 1, clamped for y == last edge
    size_t j = static_cast<size_t>(
        std::upper_bound(edges.begin(), edges.end(), y) - edges.begin());
    if (j == 0) continue;  // y < edges[0] handled above; defensive
    j -= 1;
    if (j >= nbins) j = nbins - 1;  // y == edges.back()
    h[j] += 1;
  }
  return h;
}

// Cyclic Jacobi eigensolver for a symmetric 3x3; returns the eigenvector of
// the SMALLEST eigenvalue (== smallest singular vector of a PSD matrix, i.e.
// np.linalg.svd(M)[0][:, -1] up to sign). Deterministic; ~1e-15 of LAPACK.
inline void SmallestEigvec3(const double M[3][3], double out[3]) {
  AETHER_GHOST_NO_CONTRACT
  double a[3][3];
  double v[3][3] = {{1, 0, 0}, {0, 1, 0}, {0, 0, 1}};
  for (int i = 0; i < 3; ++i)
    for (int j = 0; j < 3; ++j) a[i][j] = M[i][j];
  for (int sweep = 0; sweep < 64; ++sweep) {
    double off = std::fabs(a[0][1]) + std::fabs(a[0][2]) + std::fabs(a[1][2]);
    if (off == 0.0) break;
    for (int p = 0; p < 2; ++p) {
      for (int q = p + 1; q < 3; ++q) {
        if (a[p][q] == 0.0) continue;
        const double theta = (a[q][q] - a[p][p]) / (2.0 * a[p][q]);
        const double t = (theta >= 0 ? 1.0 : -1.0) /
                         (std::fabs(theta) +
                          std::sqrt(theta * theta + 1.0));
        const double c = 1.0 / std::sqrt(t * t + 1.0);
        const double s = t * c;
        for (int k = 0; k < 3; ++k) {
          const double akp = a[k][p], akq = a[k][q];
          a[k][p] = c * akp - s * akq;
          a[k][q] = s * akp + c * akq;
        }
        for (int k = 0; k < 3; ++k) {
          const double apk = a[p][k], aqk = a[q][k];
          a[p][k] = c * apk - s * aqk;
          a[q][k] = s * apk + c * aqk;
        }
        for (int k = 0; k < 3; ++k) {
          const double vkp = v[k][p], vkq = v[k][q];
          v[k][p] = c * vkp - s * vkq;
          v[k][q] = s * vkp + c * vkq;
        }
      }
    }
  }
  int mi = 0;
  for (int i = 1; i < 3; ++i)
    if (a[i][i] < a[mi][mi]) mi = i;
  for (int k = 0; k < 3; ++k) out[k] = v[k][mi];
}

inline int64_t CellKey(double x, double z) {
  const int64_t cx = static_cast<int64_t>(std::floor(x / kCell));
  const int64_t cz = static_cast<int64_t>(std::floor(z / kCell));
  return cx * 100000 + cz;
}

// kmeans2 (ghost_lib.kmeans2 verbatim: init [min,max], 30 fixed iterations,
// argmin tie -> label 0, empty cluster keeps its center).
inline void KMeans2(const std::vector<double>& v, double c[2],
                    std::vector<uint8_t>& lab) {
  AETHER_GHOST_NO_CONTRACT
  const size_t n = v.size();
  double lo = v[0], hi = v[0];
  for (const double x : v) {
    if (x < lo) lo = x;
    if (x > hi) hi = x;
  }
  c[0] = lo;
  c[1] = hi;
  lab.assign(n, 0);
  std::vector<double> member;
  member.reserve(n);
  for (int it = 0; it < 30; ++it) {
    for (size_t i = 0; i < n; ++i) {
      const double d0 = std::fabs(v[i] - c[0]);
      const double d1 = std::fabs(v[i] - c[1]);
      lab[i] = d1 < d0 ? 1 : 0;  // numpy argmin: tie -> 0
    }
    for (int j = 0; j < 2; ++j) {
      member.clear();
      for (size_t i = 0; i < n; ++i)
        if (lab[i] == j) member.push_back(v[i]);
      if (!member.empty()) c[j] = Mean1D(member);
    }
  }
}

}  // namespace detail

// Mode-anchored LSQ floor plane (ghost_lib.fit_floor_plane verbatim). xyz is
// row-major (n,3) float64. Returns unit normal (ny>=0) + offset d.
inline void FitFloorPlane(const double* xyz, size_t n, double nrm[3],
                          double* d_out) {
  AETHER_GHOST_NO_CONTRACT
  // percentile 2/98 per axis over sorted column copies
  double lo[3], hi[3], lb[3], ub[3];
  {
    std::vector<double> col(n);
    for (int j = 0; j < 3; ++j) {
      for (size_t i = 0; i < n; ++i) col[i] = xyz[i * 3 + j];
      std::sort(col.begin(), col.end());
      lo[j] = detail::PercentileSorted(col, 2.0);
      hi[j] = detail::PercentileSorted(col, 98.0);
      lb[j] = lo[j] - (hi[j] - lo[j]) * 0.5;
      ub[j] = hi[j] + (hi[j] - lo[j]) * 0.5;
    }
  }
  std::vector<uint8_t> keep(n);
  for (size_t i = 0; i < n; ++i) {
    bool k = true;
    for (int j = 0; j < 3; ++j) {
      const double x = xyz[i * 3 + j];
      if (!(x >= lb[j] && x <= ub[j])) k = false;
    }
    keep[i] = k ? 1 : 0;
  }
  // histogram mode of kept Y at 2cm bins
  std::vector<double> Y;
  Y.reserve(n);
  for (size_t i = 0; i < n; ++i)
    if (keep[i]) Y.push_back(xyz[i * 3 + 1]);
  double ymin = Y[0], ymax = Y[0];
  for (const double y : Y) {
    if (y < ymin) ymin = y;
    if (y > ymax) ymax = y;
  }
  const std::vector<double> e = detail::Arange(ymin, ymax + 0.02, 0.02);
  const std::vector<int64_t> h = detail::Histogram(Y, e);
  size_t am = 0;
  for (size_t i = 1; i < h.size(); ++i)
    if (h[i] > h[am]) am = i;
  const double fl = e[am] + 0.01;

  double nv[3] = {0.0, 1.0, 0.0};
  double d = -fl;
  for (int iter = 0; iter < 3; ++iter) {
    // inliers: |P@n + d| < kAnchorTol, restricted to keep
    // c0 = Q.mean(0) — numpy axis-0 reduce is sequential over rows
    double acc[3] = {0, 0, 0};
    size_t m = 0;
    std::vector<size_t> inl;
    inl.reserve(n);
    for (size_t i = 0; i < n; ++i) {
      const double* p = &xyz[i * 3];
      const double sd = ((p[0] * nv[0] + p[1] * nv[1]) + p[2] * nv[2]) + d;
      if (std::fabs(sd) < kAnchorTol && keep[i]) {
        acc[0] += p[0];
        acc[1] += p[1];
        acc[2] += p[2];
        inl.push_back(i);
        ++m;
      }
    }
    double c0[3];
    for (int j = 0; j < 3; ++j) c0[j] = acc[j] / static_cast<double>(m);
    // M = (Q-c0)^T (Q-c0) — sequential accumulation (LAPACK-level ~1e-14
    // difference vs numpy dgemm is accepted; see header contract note).
    double M[3][3] = {{0, 0, 0}, {0, 0, 0}, {0, 0, 0}};
    for (const size_t i : inl) {
      const double* p = &xyz[i * 3];
      const double q0 = p[0] - c0[0], q1 = p[1] - c0[1], q2 = p[2] - c0[2];
      M[0][0] += q0 * q0;
      M[0][1] += q0 * q1;
      M[0][2] += q0 * q2;
      M[1][1] += q1 * q1;
      M[1][2] += q1 * q2;
      M[2][2] += q2 * q2;
    }
    M[1][0] = M[0][1];
    M[2][0] = M[0][2];
    M[2][1] = M[1][2];
    double w[3];
    detail::SmallestEigvec3(M, w);
    if (w[1] < 0) {
      w[0] = -w[0];
      w[1] = -w[1];
      w[2] = -w[2];
    }
    const double norm =
        std::sqrt((w[0] * w[0] + w[1] * w[1]) + w[2] * w[2]);
    nv[0] = w[0] / norm;
    nv[1] = w[1] / norm;
    nv[2] = w[2] / norm;
    d = -((nv[0] * c0[0] + nv[1] * c0[1]) + nv[2] * c0[2]);
  }
  nrm[0] = nv[0];
  nrm[1] = nv[1];
  nrm[2] = nv[2];
  *d_out = d;
}

// The full pass (ghost_lib.floor_labels + the 1.5cm band of run_phase0).
// xyz: row-major (n,3) float64 — production feeds the float32-cast point
// coordinates (the delivered-PLY quantization) so flags stay consistent with
// any PLY-based tooling. flags: resized to n, one GhostFlagBits byte each.
inline bool ComputeGhostMask(const double* xyz, size_t n,
                             std::vector<uint8_t>* flags,
                             GhostMaskStats* stats,
                             GhostMaskIntermediates* inter = nullptr) {
  AETHER_GHOST_NO_CONTRACT
  if (!flags || n < 100) return false;  // degenerate cloud: no mask
  flags->assign(n, 0);

  double nv[3], d;
  FitFloorPlane(xyz, n, nv, &d);

  std::vector<double> sd(n);
  std::vector<int64_t> ckey(n);
  for (size_t i = 0; i < n; ++i) {
    const double* p = &xyz[i * 3];
    sd[i] = ((p[0] * nv[0] + p[1] * nv[1]) + p[2] * nv[2]) + d;
    ckey[i] = detail::CellKey(p[0], p[2]);
  }

  // footprint cells: >= kFootprintMin points with |sd| <= kAnchorWin
  std::unordered_map<int64_t, int32_t> anchor_cnt;
  std::unordered_map<int64_t, int32_t> above_cnt;
  for (size_t i = 0; i < n; ++i) {
    if (std::fabs(sd[i]) <= kAnchorWin) ++anchor_cnt[ckey[i]];
    if (sd[i] > kSlab && sd[i] < kOverheadHi) ++above_cnt[ckey[i]];
  }

  std::vector<uint8_t>& F = *flags;
  std::unordered_map<int64_t, std::vector<int32_t>> bycell;
  for (size_t i = 0; i < n; ++i) {
    const auto it = anchor_cnt.find(ckey[i]);
    const bool in_fp = it != anchor_cnt.end() && it->second >= kFootprintMin;
    if (in_fp && std::fabs(sd[i]) < kSlab) {
      F[i] |= kFlagInRegion;
      bycell[ckey[i]].push_back(static_cast<int32_t>(i));  // ascending order
      const auto ab = above_cnt.find(ckey[i]);
      if (ab == above_cnt.end() || ab->second < kOverheadMax)
        F[i] |= kFlagInClean;
    }
  }

  // per-cell local floor anchor + bimodal detector
  std::vector<double> local_off(n, 0.0);
  int64_t n_bim = 0, n_floor_cells = 0;
  std::vector<double> v, anc;
  std::vector<uint8_t> lab;
  for (const auto& [key, ii] : bycell) {
    v.clear();
    anc.clear();
    for (const int32_t i : ii) v.push_back(sd[static_cast<size_t>(i)]);
    for (const double x : v)
      if (std::fabs(x) <= kAnchorWin) anc.push_back(x);
    if (anc.size() >= static_cast<size_t>(kFootprintMin)) {
      const double med = detail::Median1D(anc);
      for (const int32_t i : ii) local_off[static_cast<size_t>(i)] = med;
    }
    if (v.size() >= static_cast<size_t>(kMinCellPts)) {
      ++n_floor_cells;
      double c[2];
      detail::KMeans2(v, c, lab);
      size_t n0 = 0;
      for (const uint8_t l : lab)
        if (l == 0) ++n0;
      const size_t n1 = v.size() - n0;
      const double frac = static_cast<double>(std::min(n0, n1)) /
                          static_cast<double>(v.size());
      const double gap = std::fabs(c[1] - c[0]);
      std::vector<double> m0, m1;
      for (size_t k = 0; k < v.size(); ++k)
        (lab[k] == 0 ? m0 : m1).push_back(v[k]);
      // ghost_lib: sep = gap / max(1e-6, std0 + std1); empty modes cannot
      // happen here (frac gate implies both non-empty when it matters, and
      // numpy std of an empty slice would have been nan -> gate false).
      const double s0 = m0.empty() ? std::nan("") : detail::Std1D(m0);
      const double s1 = m1.empty() ? std::nan("") : detail::Std1D(m1);
      const double sep = gap / std::max(1e-6, s0 + s1);
      if (frac >= kBimFrac && gap >= kBimGap && sep >= kBimSep) {
        ++n_bim;
        const int gm = std::fabs(c[0]) > std::fabs(c[1]) ? 0 : 1;
        for (size_t k = 0; k < v.size(); ++k)
          if (lab[k] == gm)
            F[static_cast<size_t>(ii[k])] |= kFlagCellGhost;
      }
    }
  }

  int64_t n_region = 0, n_band15 = 0, n_band10 = 0, n_ghost = 0, n_clean = 0;
  for (size_t i = 0; i < n; ++i) {
    if (!(F[i] & kFlagInRegion)) continue;
    ++n_region;
    const double r = std::fabs(sd[i] - local_off[i]);
    if (r > kHalfGapBand) {
      F[i] |= kFlagBand15;
      ++n_band15;
    }
    if (r > kHalfGapRef) {
      F[i] |= kFlagBand10;
      ++n_band10;
    }
    if (F[i] & kFlagCellGhost) ++n_ghost;
    if (F[i] & kFlagInClean) ++n_clean;
  }

  if (stats) {
    stats->n_points = static_cast<int64_t>(n);
    stats->n_region = n_region;
    stats->n_band15 = n_band15;
    stats->n_band10 = n_band10;
    stats->n_cell_ghost = n_ghost;
    stats->n_clean = n_clean;
    stats->n_bim_cells = n_bim;
    stats->n_floor_cells = n_floor_cells;
    stats->plane_n[0] = nv[0];
    stats->plane_n[1] = nv[1];
    stats->plane_n[2] = nv[2];
    stats->plane_d = d;
  }
  if (inter) {
    inter->sd = std::move(sd);
    inter->local_off = std::move(local_off);
  }
  return true;
}

#undef AETHER_GHOST_NO_CONTRACT

}  // namespace aether_ghost
