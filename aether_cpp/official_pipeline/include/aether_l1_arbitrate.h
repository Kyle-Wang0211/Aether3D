// aether_l1_arbitrate.h — [L1-ARBITRATE 2026-07-12] the CasDiffMVS 1-bit
// arbitration over the ghost-mask band15 hide-candidates, C++ port of the
// CALIBRATED TERMINAL RULES (scratchpad/ghost_l1/arbitrate_score.py, Mac
// calibration verdict: 误隐=0 under abstain->visible across the full 25-config
// sweep; rescue 93/210 on cap46/47 with full-fusion evidence).
//
// Evidence here = the per-ref CasDiffMVS depth+conf maps written by the
// device runner (or the Mac harness) as <db_dir>/l1_depth_<frameId>.bin,
// CLEANED IN-ARBITRATION by a cross-ref geometric-consistency gate (the
// Merrell-family check the ofsxq fusion used: reproject-roundtrip < 1.0 px
// and relative depth < 0.01, >=1 corroborating ref — the plan guarantees
// >=2 refs per marked cell, so a genuine surface pixel always has a
// partner). Without this gate the raw single-view maps convict real
// geometry: the Mac E2E measured 误隐 95/380 (cap46/47) raw vs the
// calibration's 0 on fused maps — the conviction rules are only safe on
// corroborated evidence. Still weaker than full-capture fusion, so ABSTAIN
// is expected to rise (ghost residual up); rules stay fail-open.
//
// Rule set (calibration-terminal structure; thresholds re-anchored on the
// Mac E2E with DEVICE-GRADE evidence — the deltas vs arbitrate_score.py are
// listed below and were validated 误隐=0 across a see>= {3,4} x margin
// {22,25}mm x trust {8,10}mm neighbourhood on cap46+cap47):
//   RAY    per-view votes in the HEIGHT domain: project the sparse point,
//          3x3-patch MEDIAN depth read (conf>0.3 + geo-gated pixels, >=3
//          valid), backproject -> hres = (P - Pd)·n_up, rh = hres -
//          delta_hray (runtime datum over the gate-visible control points).
//          SUP |rh|<=10mm; SEE rh>=+20mm; BELOW rh<=-20mm (10..20mm dead
//          zone = the per-view margin gate). ray_ok = #SUP>=2 & #SEE==0.
//   FLOOR  per-cell dense floor level lev (histogram mode nearest the plane
//          over the voxelized slab evidence, analyze_gt.dense_floor_levels
//          port) + optional second mode lev2. r' = sd - lev - delta;
//          floor_ok = |r'|<=10mm or on an ABOVE-floor second mode.
//   STRUCT nn to the sub-floor-filtered dense evidence: <=10mm qualifies
//          for RESCUE (calibration value); <=15mm additionally VETOES a
//          conviction (fail-open widening for the thinner device evidence).
//   TRUST  per-cell: |local_off - lev - delta| <= 10mm, else the cell's
//          dense evidence is systematically biased (self-corroborating
//          CasDiffMVS local error) -> every verdict in the cell ABSTAINS.
//   MIRROR DEFENSE (hard): below-floor points are NEVER rescued
//          (r' < -10mm; sparse local_off fallback where no dense level);
//          on a BELOW-floor second mode => never rescued; rescue requires
//          an above-floor voucher (FLOOR | STRUCT) — dual-channel agreement.
//   RESCUE  = trusted & ray_ok & (floor_ok | nn<=10mm) & ~below_floor
//             & ~mirror_hit
//   CONFIRM = trusted & ~rescue & sup==0 & see>=3 & no_voucher
//             & |sd - local_off| >= 25mm     (see-driven ONLY)
//   ABSTAIN = the rest -> VISIBLE (fail-open; the signed-off policy).
//
// Deltas vs the fused-evidence calibration, forced by the Mac E2E account:
//   - conviction see>=3 (was 2): a third independent witness is required on
//     single-view-grade evidence (cap47 see>=2 convicted 12 real tails).
//   - conviction sparse margin |sd-local_off|>=25mm: the D-band marginal
//     zone (15-25mm) is where the band gate's own 误杀 lives (GT thick tail
//     sigma 6-9mm); never convict there, the ghost mass median sits 30-40mm.
//   - conf_below conviction channel DROPPED: separating sunken real
//     structure from mirror ghosts below the floor needs full-fusion
//     structure evidence (GT nn_above); at 10-ref evidence it convicted
//     74-334 real skirting/threshold points. Below-floor ghosts abstain and
//     stay handled by the L2 display gates.
//   - voucher (conviction veto) = floor_ok | |r'|<=15mm | nn<=15mm — wider
//     than the rescue voucher, in the fail-open direction only.
//
// Flags written back into <db_dir>/ghost_mask.bin: kFlagL1Rescued (bit 5) /
// kFlagL1Confirmed (bit 6) — bits 0-4 untouched, file rewritten atomically.
// Stats go to <db_dir>/ghost_arbitration.json. Fully file-driven: inputs are
// arbitration_plan.bin + arbitration_points.bin + ghost_mask.bin +
// l1_depth_*.bin, so the exact same code runs on-device (aether_sfm_arbitrate)
// and in the Mac end-to-end harness (l1_ghost_tool).
#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <limits>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include "aether_ghost_mask.h"
#include "aether_l1_plan.h"

namespace aether_l1 {

// calibration-terminal gates (arbitrate_score.py defaults; DO NOT retune
// without re-running the Mac calibration)
constexpr double kTauSup = 0.010;
constexpr double kTauRej = 0.020;
constexpr int kVoteMin = 2;
constexpr int kSeeTol = 0;
constexpr double kFloorTol = 0.010;
constexpr double kNnTol = 0.010;
// conviction-side gates (device-evidence re-anchoring, see header):
constexpr int kConvSeeMin = 3;          // >=3 independent see-through views
constexpr double kConvSparseMargin = 0.025;  // |sd - local_off| floor
constexpr double kFloorLooseTol = 0.015;     // conviction-veto floor band
constexpr double kNnVetoTol = 0.015;         // conviction-veto NN radius
constexpr float kConfMin = 0.3f;      // fusion-recipe photometric gate
constexpr double kDatumWin = 0.06;    // |hres| window for the height datum
constexpr int kMinCellDense = 50;     // dense_floor_levels MIN_CELL_DENSE
constexpr double kModeWin = 0.010;    // mode membership window
constexpr double kMode2Gap = 0.015;   // second-mode min separation
constexpr double kHistBin = 0.005;    // slab histogram bin
constexpr double kBelowTol = 0.010;   // below-floor veto threshold
constexpr int kCtrlMin = 50;          // minimum control points for the datums
constexpr double kNnVoxel = 0.010;    // NN hash voxel (== kNnTol: exact bool)
// cross-ref geometric-consistency gate (ofsxq fusion family: GEO_PIX=1.0,
// GEO_DEP=0.01; corroboration floor 1 — the plan covers every marked cell
// with >=2 refs, so true surface pixels have a partner by construction)
constexpr double kGeoPix = 1.0;
constexpr double kGeoDepRel = 0.01;
constexpr int kGeoN = 1;
// per-cell evidence-trust gate: the dense floor level must agree with the
// SPARSE per-cell anchor (local_off) up to the global datum within this
// tolerance, else the cell's dense evidence is systematically biased (Mac
// E2E: CasDiffMVS locally sank the floor 2-3cm in a few cells — the refs
// corroborate each other there, so the geo gate cannot catch it) and every
// verdict in the cell is forced to ABSTAIN (fail-open both directions).
constexpr double kCellTrustTol = 0.010;
// dense-evidence voxelization: the calibration's lev/lev2/NN structures were
// computed over a 5mm-voxel-downsampled cloud (ofsxq clean step); raw per-ref
// pixel mass has a wildly different density profile (12 refs x 458k px), so
// the same MIN_CELL_DENSE / keep thresholds only transfer on voxel centroids.
constexpr double kEvidVoxel = 0.005;

struct ArbStats {
  int n_refs_planned = 0;
  int n_refs_used = 0;       // depth bins actually present/valid
  int n_region = 0;
  int n_band = 0;
  int n_rescue = 0;
  int n_confirm = 0;
  int n_abstain = 0;
  int n_confirm_see = 0;
  int n_confirm_below = 0;
  int n_ray_ok = 0;          // band points passing the ray gate
  int n_floor_ok = 0;        // band points vouched by FLOOR
  int n_struct_ok = 0;       // band points vouched by STRUCT
  int n_below_floor = 0;
  int n_mirror_hit = 0;
  int n_lev_cells = 0;
  int n_lev2_cells = 0;
  int n_ctrl_floor = 0;      // FLOOR datum control size
  int n_ctrl_ray = 0;        // RAY datum control size
  double delta_mm = 0.0;     // FLOOR datum
  double delta_ray_mm = 0.0; // RAY (height) datum
  bool degraded = false;     // datums under-powered -> all abstain
  double pass_ms = 0.0;
};

namespace detail_arb {

struct PlanRefBin {
  int32_t frame_id = -1;
  double k[4] = {0};
  double w2c[16] = {0};
};

inline bool ReadAll(const std::string& path, std::vector<uint8_t>* out) {
  FILE* f = std::fopen(path.c_str(), "rb");
  if (!f) return false;
  std::fseek(f, 0, SEEK_END);
  const long sz = std::ftell(f);
  std::fseek(f, 0, SEEK_SET);
  if (sz <= 0) {
    std::fclose(f);
    return false;
  }
  out->resize(static_cast<size_t>(sz));
  const size_t r = std::fread(out->data(), 1, out->size(), f);
  std::fclose(f);
  return r == out->size();
}

template <typename T>
inline bool Pull(const std::vector<uint8_t>& b, size_t* off, T* out,
                 size_t count = 1) {
  const size_t bytes = sizeof(T) * count;
  if (*off + bytes > b.size()) return false;
  std::memcpy(out, b.data() + *off, bytes);
  *off += bytes;
  return true;
}

// voxel key at pitch `vox` (separate from the 20cm ghost cells).
inline int64_t VoxKeyAt(double x, double y, double z, double vox) {
  const int64_t vx = static_cast<int64_t>(std::floor(x / vox));
  const int64_t vy = static_cast<int64_t>(std::floor(y / vox));
  const int64_t vz = static_cast<int64_t>(std::floor(z / vox));
  // 21/21/21-bit pack with offset — captures span < 10km, safe.
  return ((vx + (1ll << 20)) << 42) | ((vy + (1ll << 20)) << 21) |
         (vz + (1ll << 20));
}
inline int64_t VoxKey(double x, double y, double z) {
  return VoxKeyAt(x, y, z, kNnVoxel);
}

}  // namespace detail_arb

inline bool RunArbitration(const std::string& db_dir, ArbStats* st,
                           std::string* err) {
  using aether_ghost::detail::Arange;
  using aether_ghost::detail::Histogram;
  using aether_ghost::detail::Median1D;
  const auto fail = [&](const char* m) {
    if (err) *err = m;
    return false;
  };

  // ── inputs ────────────────────────────────────────────────────────────
  std::vector<uint8_t> planb;
  if (!detail_arb::ReadAll(db_dir + "/arbitration_plan.bin", &planb))
    return fail("arbitration_plan.bin missing/unreadable");
  size_t off = 0;
  uint32_t magic = 0, ver = 0, H = 0, W = 0, n_refs = 0;
  double plane_n[3] = {0}, plane_d = 0;
  if (!detail_arb::Pull(planb, &off, &magic) || magic != 0x314C3341u)
    return fail("plan magic mismatch");
  if (!detail_arb::Pull(planb, &off, &ver) || ver != 1u)
    return fail("plan version mismatch");
  if (!detail_arb::Pull(planb, &off, plane_n, 3) ||
      !detail_arb::Pull(planb, &off, &plane_d) ||
      !detail_arb::Pull(planb, &off, &H) ||
      !detail_arb::Pull(planb, &off, &W) ||
      !detail_arb::Pull(planb, &off, &n_refs))
    return fail("plan truncated");
  std::vector<detail_arb::PlanRefBin> refs(n_refs);
  for (uint32_t r = 0; r < n_refs; ++r) {
    if (!detail_arb::Pull(planb, &off, &refs[r].frame_id) ||
        !detail_arb::Pull(planb, &off, refs[r].k, 4) ||
        !detail_arb::Pull(planb, &off, refs[r].w2c, 16))
      return fail("plan ref truncated");
  }
  st->n_refs_planned = static_cast<int>(n_refs);
  if (n_refs == 0) return fail("plan has no refs");

  std::vector<uint8_t> ptsb;
  if (!detail_arb::ReadAll(db_dir + "/arbitration_points.bin", &ptsb))
    return fail("arbitration_points.bin missing/unreadable");
  off = 0;
  uint32_t pmagic = 0, pver = 0, n = 0;
  if (!detail_arb::Pull(ptsb, &off, &pmagic) || pmagic != 0x504C3341u ||
      !detail_arb::Pull(ptsb, &off, &pver) || pver != 1u ||
      !detail_arb::Pull(ptsb, &off, &n) || n == 0)
    return fail("points sidecar header invalid");
  std::vector<uint32_t> flag_idx(n);
  std::vector<float> xyz(static_cast<size_t>(n) * 3);
  std::vector<double> sd(n), local_off(n);
  if (!detail_arb::Pull(ptsb, &off, flag_idx.data(), n) ||
      !detail_arb::Pull(ptsb, &off, xyz.data(), static_cast<size_t>(n) * 3) ||
      !detail_arb::Pull(ptsb, &off, sd.data(), n) ||
      !detail_arb::Pull(ptsb, &off, local_off.data(), n))
    return fail("points sidecar truncated");
  st->n_region = static_cast<int>(n);

  std::vector<uint8_t> mask;
  if (!detail_arb::ReadAll(db_dir + "/ghost_mask.bin", &mask))
    return fail("ghost_mask.bin missing/unreadable");
  for (const uint32_t fi : flag_idx)
    if (fi >= mask.size()) return fail("flag index out of mask range");

  std::vector<uint8_t> band(n), cellghost(n);
  for (uint32_t i = 0; i < n; ++i) {
    band[i] = (mask[flag_idx[i]] & aether_ghost::kFlagBand15) ? 1 : 0;
    cellghost[i] = (mask[flag_idx[i]] & aether_ghost::kFlagCellGhost) ? 1 : 0;
  }
  int n_band = 0;
  for (uint32_t i = 0; i < n; ++i) n_band += band[i];
  st->n_band = n_band;

  // per-point 20cm cell keys (same CellKey as the mask pass)
  std::vector<int64_t> ckey(n);
  for (uint32_t i = 0; i < n; ++i)
    ckey[i] = aether_ghost::detail::CellKey(
        static_cast<double>(xyz[static_cast<size_t>(i) * 3]),
        static_cast<double>(xyz[static_cast<size_t>(i) * 3 + 2]));

  // NN candidate hash: band15 points, 1cm voxels + dilated acceptance set.
  std::unordered_map<int64_t, std::vector<uint32_t>> cand_of_vox;
  std::unordered_set<int64_t> vox_accept;
  for (uint32_t i = 0; i < n; ++i) {
    if (!band[i]) continue;
    const double px = xyz[static_cast<size_t>(i) * 3];
    const double py = xyz[static_cast<size_t>(i) * 3 + 1];
    const double pz = xyz[static_cast<size_t>(i) * 3 + 2];
    cand_of_vox[detail_arb::VoxKey(px, py, pz)].push_back(i);
    for (int dx = -1; dx <= 1; ++dx)
      for (int dy = -1; dy <= 1; ++dy)
        for (int dz = -1; dz <= 1; ++dz)
          vox_accept.insert(detail_arb::VoxKey(px + dx * kNnVoxel,
                                               py + dy * kNnVoxel,
                                               pz + dz * kNnVoxel));
  }

  // ── load every available ref map, then geo-consistency-gate them ──────
  const size_t hw = static_cast<size_t>(H) * W;
  struct RefMap {
    int32_t frame_id = -1;
    const double* k = nullptr;    // fx fy cx cy
    const double* w2c = nullptr;  // row-major 4x4
    std::vector<float> depth;     // H*W
    std::vector<uint8_t> ok;      // conviction-grade mask (conf + geo gates)
    std::vector<uint8_t> okc;     // conf-gate only (STRUCT voucher evidence:
                                  // the geo gate strips depth-edge pixels on
                                  // skirting/structure — exactly the mass the
                                  // fail-open veto needs; Mac E2E raw-vs-GT
                                  // NN 15-18mm vs 3-9mm proved the loss)
  };
  std::vector<RefMap> maps;
  {
    std::vector<uint8_t> raw;
    for (uint32_t r = 0; r < n_refs; ++r) {
      char name[64];
      std::snprintf(name, sizeof(name), "/l1_depth_%d.bin", refs[r].frame_id);
      if (!detail_arb::ReadAll(db_dir + name, &raw)) continue;
      size_t doff = 0;
      char dm[4];
      uint32_t dver = 0, dH = 0, dW = 0;
      int32_t dfid = -1;
      if (!detail_arb::Pull(raw, &doff, dm, 4) ||
          std::memcmp(dm, "L1DP", 4) != 0 ||
          !detail_arb::Pull(raw, &doff, &dver) || dver != 1u ||
          !detail_arb::Pull(raw, &doff, &dfid) ||
          !detail_arb::Pull(raw, &doff, &dH) ||
          !detail_arb::Pull(raw, &doff, &dW) || dH != H || dW != W ||
          dfid != refs[r].frame_id || raw.size() < doff + hw * 8)
        continue;  // malformed bin: treat as absent (fail-open)
      RefMap m;
      m.frame_id = refs[r].frame_id;
      m.k = refs[r].k;
      m.w2c = refs[r].w2c;
      m.depth.resize(hw);
      std::memcpy(m.depth.data(), raw.data() + doff, hw * 4);
      const float* conf = reinterpret_cast<const float*>(raw.data() + doff) +
                          hw;
      m.ok.resize(hw);
      for (size_t p = 0; p < hw; ++p)
        m.ok[p] = (m.depth[p] > 0.0f && conf[p] > kConfMin) ? 1 : 0;
      m.okc = m.ok;
      maps.push_back(std::move(m));
    }
  }
  const int n_maps = static_cast<int>(maps.size());
  st->n_refs_used = n_maps;
  if (n_maps == 0) return fail("no usable l1_depth_*.bin found");
  std::vector<int> ref_used_ids;
  for (const RefMap& m : maps) ref_used_ids.push_back(m.frame_id);

  // cam -> world for a row-major CamFromWorld
  const auto cam2world = [](const double* w2c, double xc, double yc,
                            double zc, double o[3]) {
    const double a = xc - w2c[3], b = yc - w2c[7], c = zc - w2c[11];
    o[0] = w2c[0] * a + w2c[4] * b + w2c[8] * c;
    o[1] = w2c[1] * a + w2c[5] * b + w2c[9] * c;
    o[2] = w2c[2] * a + w2c[6] * b + w2c[10] * c;
  };
  const auto world2cam = [](const double* w2c, const double p[3],
                            double o[3]) {
    o[0] = w2c[0] * p[0] + w2c[1] * p[1] + w2c[2] * p[2] + w2c[3];
    o[1] = w2c[4] * p[0] + w2c[5] * p[1] + w2c[6] * p[2] + w2c[7];
    o[2] = w2c[8] * p[0] + w2c[9] * p[1] + w2c[10] * p[2] + w2c[11];
  };

  // Geometric-consistency gate (Merrell/ofsxq family, roundtrip form):
  // backproject A's pixel, project into B, read B's depth at the rounded
  // pixel, backproject THAT, reproject into A — consistent when the
  // roundtrip lands < kGeoPix of the source pixel and the roundtrip depth
  // is within kGeoDepRel of A's. A pixel needs >= kGeoN consistent partner
  // refs to stay usable. Raw single-view CasDiffMVS output convicts real
  // geometry without this (Mac E2E: 误隐 95/380 raw -> gate restores 0).
  {
    std::vector<std::vector<uint8_t>> geo_ok(maps.size());
    for (size_t a = 0; a < maps.size(); ++a) {
      const RefMap& A = maps[a];
      geo_ok[a].assign(hw, 0);
      const double fxA = A.k[0], fyA = A.k[1], cxA = A.k[2], cyA = A.k[3];
      for (uint32_t v = 0; v < H; ++v) {
        for (uint32_t u = 0; u < W; ++u) {
          const size_t px = static_cast<size_t>(v) * W + u;
          if (!A.ok[px]) continue;
          const double zd = static_cast<double>(A.depth[px]);
          double Pw[3];
          cam2world(A.w2c, (static_cast<double>(u) - cxA) / fxA * zd,
                    (static_cast<double>(v) - cyA) / fyA * zd, zd, Pw);
          int agree = 0;
          for (size_t b = 0; b < maps.size() && agree < kGeoN; ++b) {
            if (b == a) continue;
            const RefMap& B = maps[b];
            double pb[3];
            world2cam(B.w2c, Pw, pb);
            if (pb[2] <= 0.05) continue;
            const double ub = B.k[0] * pb[0] / pb[2] + B.k[2];
            const double vb = B.k[1] * pb[1] / pb[2] + B.k[3];
            const long ubi = static_cast<long>(std::rint(ub));
            const long vbi = static_cast<long>(std::rint(vb));
            if (ubi < 0 || ubi >= static_cast<long>(W) || vbi < 0 ||
                vbi >= static_cast<long>(H))
              continue;
            const size_t pxb = static_cast<size_t>(vbi) * W + ubi;
            const float dB = B.depth[pxb];
            if (!(dB > 0.0f)) continue;
            double Pw2[3];
            cam2world(B.w2c,
                      (static_cast<double>(ubi) - B.k[2]) / B.k[0] * dB,
                      (static_cast<double>(vbi) - B.k[3]) / B.k[1] * dB,
                      static_cast<double>(dB), Pw2);
            double pa[3];
            world2cam(A.w2c, Pw2, pa);
            if (pa[2] <= 0.05) continue;
            const double ua2 = fxA * pa[0] / pa[2] + cxA;
            const double va2 = fyA * pa[1] / pa[2] + cyA;
            const double du = ua2 - static_cast<double>(u);
            const double dvv = va2 - static_cast<double>(v);
            if (du * du + dvv * dvv >= kGeoPix * kGeoPix) continue;
            if (std::fabs(pa[2] - zd) / zd >= kGeoDepRel) continue;
            ++agree;
          }
          geo_ok[a][px] = agree >= kGeoN ? 1 : 0;
        }
      }
    }
    for (size_t a = 0; a < maps.size(); ++a)
      for (size_t p = 0; p < hw; ++p) maps[a].ok[p] &= geo_ok[a][p];
  }

  // ── evidence passes over the gated maps ───────────────────────────────
  // Dense evidence is accumulated into 5mm-voxel centroids (kEvidVoxel) —
  // the calibration computed lev/lev2/NN over a 5mm-voxel-downsampled cloud,
  // and MIN_CELL_DENSE / the sub-floor keep rule only transfer on that
  // density profile. vox_geo (conviction-grade, geo-gated) feeds lev/lev2;
  // vox_conf (conf-only, near the NN candidates) feeds the STRUCT voucher.
  const float nanf = std::numeric_limits<float>::quiet_NaN();
  std::vector<float> hres(static_cast<size_t>(n) * n_maps, nanf);
  struct VoxAcc {
    double sx = 0, sy = 0, sz = 0;
    int cnt = 0;
  };
  std::unordered_map<int64_t, VoxAcc> vox_geo, vox_conf;
  for (int r = 0; r < n_maps; ++r) {
    const RefMap& M = maps[static_cast<size_t>(r)];
    const float* depth = M.depth.data();
    const uint8_t* ok = M.ok.data();
    const uint8_t* okc = M.okc.data();
    const double fx = M.k[0], fy = M.k[1], cx = M.k[2], cy = M.k[3];
    const double* w2c = M.w2c;

    // (a) dense pixel pass -> voxel accumulators
    for (uint32_t v = 0; v < H; ++v) {
      for (uint32_t u = 0; u < W; ++u) {
        const size_t px = static_cast<size_t>(v) * W + u;
        if (!okc[px]) continue;
        const double zd = static_cast<double>(depth[px]);
        double Pw[3];
        cam2world(w2c, (static_cast<double>(u) - cx) / fx * zd,
                  (static_cast<double>(v) - cy) / fy * zd, zd, Pw);
        const double sdd =
            Pw[0] * plane_n[0] + Pw[1] * plane_n[1] + Pw[2] * plane_n[2] +
            plane_d;
        if (ok[px] && std::fabs(sdd) < aether_ghost::kSlab) {
          VoxAcc& a = vox_geo[detail_arb::VoxKeyAt(Pw[0], Pw[1], Pw[2],
                                                   kEvidVoxel)];
          a.sx += Pw[0];
          a.sy += Pw[1];
          a.sz += Pw[2];
          ++a.cnt;
        }
        if (std::fabs(sdd) < 0.10 &&
            vox_accept.count(detail_arb::VoxKey(Pw[0], Pw[1], Pw[2]))) {
          VoxAcc& a = vox_conf[detail_arb::VoxKeyAt(Pw[0], Pw[1], Pw[2],
                                                    kEvidVoxel)];
          a.sx += Pw[0];
          a.sy += Pw[1];
          a.sz += Pw[2];
          ++a.cnt;
        }
      }
    }

    // (b) sparse projection pass: 3x3-patch-median height residuals
    for (uint32_t i = 0; i < n; ++i) {
      const double P[3] = {
          static_cast<double>(xyz[static_cast<size_t>(i) * 3]),
          static_cast<double>(xyz[static_cast<size_t>(i) * 3 + 1]),
          static_cast<double>(xyz[static_cast<size_t>(i) * 3 + 2])};
      double pc[3];
      world2cam(w2c, P, pc);
      if (pc[2] <= 0.05) continue;
      const double u = fx * pc[0] / pc[2] + cx;
      const double v = fy * pc[1] / pc[2] + cy;
      const long ui = static_cast<long>(std::rint(u));  // np.round: half-even
      const long vi = static_cast<long>(std::rint(v));
      if (ui < 0 || ui >= static_cast<long>(W) || vi < 0 ||
          vi >= static_cast<long>(H))
        continue;
      const long uc = std::min(std::max(ui, 1l), static_cast<long>(W) - 2);
      const long vc = std::min(std::max(vi, 1l), static_cast<long>(H) - 2);
      double patch[9];
      int nv = 0;
      for (int dy = -1; dy <= 1; ++dy) {
        for (int dx = -1; dx <= 1; ++dx) {
          const size_t px = static_cast<size_t>(vc + dy) * W + (uc + dx);
          if (ok[px]) patch[nv++] = static_cast<double>(depth[px]);
        }
      }
      if (nv < 3) continue;
      std::sort(patch, patch + nv);
      const double dmv = (nv % 2 == 1)
                             ? patch[nv / 2]
                             : (patch[nv / 2 - 1] + patch[nv / 2]) / 2.0;
      if (!(dmv > 0.0)) continue;
      // backproject the (clipped-pixel) dense read -> world height residual
      double Pd[3];
      cam2world(w2c, (static_cast<double>(uc) - cx) / fx * dmv,
                (static_cast<double>(vc) - cy) / fy * dmv, dmv, Pd);
      const double h = (P[0] - Pd[0]) * plane_n[0] +
                       (P[1] - Pd[1]) * plane_n[1] +
                       (P[2] - Pd[2]) * plane_n[2];
      hres[static_cast<size_t>(i) * n_maps + r] = static_cast<float>(h);
    }
  }
  maps.clear();
  maps.shrink_to_fit();

  // materialize the voxel centroids -> per-cell slab heights + NN evidence
  std::unordered_map<int64_t, std::vector<double>> cellvals;  // slab heights
  struct DenseNear {  // centroid evidence near NN candidates
    float x, y, z, sd;
    int64_t cell;
  };
  std::vector<DenseNear> dense_near;
  for (const auto& [key, a] : vox_geo) {
    const double px = a.sx / a.cnt, py = a.sy / a.cnt, pz = a.sz / a.cnt;
    const double sdd =
        px * plane_n[0] + py * plane_n[1] + pz * plane_n[2] + plane_d;
    if (std::fabs(sdd) < aether_ghost::kSlab)
      cellvals[aether_ghost::detail::CellKey(px, pz)].push_back(sdd);
  }
  dense_near.reserve(vox_conf.size());
  for (const auto& [key, a] : vox_conf) {
    const double px = a.sx / a.cnt, py = a.sy / a.cnt, pz = a.sz / a.cnt;
    const double sdd =
        px * plane_n[0] + py * plane_n[1] + pz * plane_n[2] + plane_d;
    dense_near.push_back({static_cast<float>(px), static_cast<float>(py),
                          static_cast<float>(pz), static_cast<float>(sdd),
                          aether_ghost::detail::CellKey(px, pz)});
  }
  vox_geo.clear();
  vox_conf.clear();

  // ── dense floor levels per cell (analyze_gt.dense_floor_levels port) ──
  const std::vector<double> edges =
      Arange(-aether_ghost::kSlab, aether_ghost::kSlab + kHistBin, kHistBin);
  std::unordered_map<int64_t, double> lev, lev2;
  for (auto& [key, v] : cellvals) {
    if (v.size() < static_cast<size_t>(kMinCellDense)) continue;
    const std::vector<int64_t> h = Histogram(v, edges);
    int64_t hmax = 0;
    for (const int64_t c : h) hmax = std::max(hmax, c);
    if (hmax == 0) continue;
    const double thr = std::max(1.0, 0.3 * static_cast<double>(hmax));
    std::vector<size_t> cand;
    for (size_t j = 0; j < h.size(); ++j)
      if (static_cast<double>(h[j]) >= thr) cand.push_back(j);
    if (cand.empty()) continue;
    size_t mi = 0;
    double mabs = std::numeric_limits<double>::infinity();
    std::vector<double> centers(cand.size());
    for (size_t j = 0; j < cand.size(); ++j) {
      centers[j] = (edges[cand[j]] + edges[cand[j] + 1]) / 2.0;
      if (std::fabs(centers[j]) < mabs) {
        mabs = std::fabs(centers[j]);
        mi = j;
      }
    }
    const double m = centers[mi];
    std::vector<double> sel;
    for (const double x : v)
      if (std::fabs(x - m) <= kModeWin) sel.push_back(x);
    if (sel.size() < static_cast<size_t>(kMinCellDense) / 2) continue;
    lev[key] = Median1D(sel);
    // second mode: strongest candidate bin >= 1.5cm away from the main mode
    size_t fb = 0;
    int64_t fbh = -1;
    for (size_t j = 0; j < cand.size(); ++j) {
      if (std::fabs(centers[j] - m) < kMode2Gap) continue;
      if (h[cand[j]] > fbh) {
        fbh = h[cand[j]];
        fb = j;
      }
    }
    if (fbh >= 0) {
      const double m2 = centers[fb];
      std::vector<double> sel2;
      for (const double x : v)
        if (std::fabs(x - m2) <= kModeWin) sel2.push_back(x);
      if (sel2.size() >= static_cast<size_t>(kMinCellDense) / 2)
        lev2[key] = Median1D(sel2);
    }
  }
  st->n_lev_cells = static_cast<int>(lev.size());
  st->n_lev2_cells = static_cast<int>(lev2.size());
  cellvals.clear();

  // ── STRUCT channel: nn (above-floor-filtered dense) <= 10mm ───────────
  std::vector<float> nn2(n, std::numeric_limits<float>::infinity());
  for (const auto& dp : dense_near) {
    const auto lv = lev.find(dp.cell);
    if (lv != lev.end() && !(static_cast<double>(dp.sd) >= lv->second - 0.005))
      continue;  // sub-floor artifact mass dropped (final_verdict keep rule)
    for (int dx = -1; dx <= 1; ++dx) {
      for (int dy = -1; dy <= 1; ++dy) {
        for (int dz = -1; dz <= 1; ++dz) {
          const auto it = cand_of_vox.find(detail_arb::VoxKey(
              dp.x + dx * kNnVoxel, dp.y + dy * kNnVoxel,
              dp.z + dz * kNnVoxel));
          if (it == cand_of_vox.end()) continue;
          for (const uint32_t ci : it->second) {
            const float ddx = xyz[static_cast<size_t>(ci) * 3] - dp.x;
            const float ddy = xyz[static_cast<size_t>(ci) * 3 + 1] - dp.y;
            const float ddz = xyz[static_cast<size_t>(ci) * 3 + 2] - dp.z;
            const float d2 = ddx * ddx + ddy * ddy + ddz * ddz;
            if (d2 < nn2[ci]) nn2[ci] = d2;
          }
        }
      }
    }
  }
  dense_near.clear();
  dense_near.shrink_to_fit();

  // ── datums over the gate-visible control set ──────────────────────────
  std::vector<double> levP(n, std::numeric_limits<double>::quiet_NaN());
  std::vector<double> lev2P(n, std::numeric_limits<double>::quiet_NaN());
  for (uint32_t i = 0; i < n; ++i) {
    const auto lv = lev.find(ckey[i]);
    if (lv != lev.end()) levP[i] = lv->second;
    const auto l2 = lev2.find(ckey[i]);
    if (l2 != lev2.end()) lev2P[i] = l2->second;
  }
  std::vector<double> mean_h(n, std::numeric_limits<double>::quiet_NaN());
  std::vector<int> h_cnt(n, 0);
  for (uint32_t i = 0; i < n; ++i) {
    double s = 0.0;
    int c = 0;
    for (int r = 0; r < n_maps; ++r) {
      const float h = hres[static_cast<size_t>(i) * n_maps + r];
      if (std::isnan(h) || !(std::fabs(static_cast<double>(h)) < kDatumWin))
        continue;
      s += static_cast<double>(h);
      ++c;
    }
    h_cnt[i] = c;
    if (c > 0) mean_h[i] = s / c;
  }
  std::vector<double> ctrl_r, ctrl_h;
  for (uint32_t i = 0; i < n; ++i) {
    if (band[i]) continue;  // control = points the gate keeps visible
    if (!std::isnan(levP[i])) {
      ctrl_r.push_back(sd[i] - levP[i]);
      if (h_cnt[i] >= 2) ctrl_h.push_back(mean_h[i]);
    }
  }
  st->n_ctrl_floor = static_cast<int>(ctrl_r.size());
  st->n_ctrl_ray = static_cast<int>(ctrl_h.size());
  double delta = 0.0, delta_ray = 0.0;
  if (static_cast<int>(ctrl_r.size()) < kCtrlMin ||
      static_cast<int>(ctrl_h.size()) < kCtrlMin) {
    st->degraded = true;  // under-powered datums -> all abstain (visible)
  } else {
    delta = Median1D(ctrl_r);
    delta_ray = Median1D(ctrl_h);
  }
  st->delta_mm = delta * 1000.0;
  st->delta_ray_mm = delta_ray * 1000.0;

  // ── verdicts over the band15 candidates ───────────────────────────────
  const double nn_tol2 = kNnTol * kNnTol;
  std::vector<uint8_t> rescued(n, 0), confirmed(n, 0);
  // optional per-point diagnosis dump (harness only; OFFICIAL_AETHER_L1_DUMP=1):
  // per region point 20B LE: u8 sup,see,below,chan_bits + f32 rp, nn_m,
  // mean_h, cell_bias. chan_bits: 1 band,2 has_lev,4 floor_ok,8 struct_ok,
  // 16 below_floor,32 mirror_hit,64 rescue,128 confirm
  const bool dump = [] {
    const char* e = std::getenv("OFFICIAL_AETHER_L1_DUMP");
    return e && e[0] == '1';
  }();
  std::vector<uint8_t> dump_buf;
  if (dump) dump_buf.resize(static_cast<size_t>(n) * 20, 0);
  if (!st->degraded) {
    for (uint32_t i = 0; i < n; ++i) {
      if (!band[i] && !dump) continue;
      int sup = 0, see = 0, below = 0;
      for (int r = 0; r < n_maps; ++r) {
        const float hf = hres[static_cast<size_t>(i) * n_maps + r];
        if (std::isnan(hf)) continue;
        const double rh = static_cast<double>(hf) - delta_ray;
        if (std::fabs(rh) <= kTauSup) ++sup;
        if (rh >= kTauRej) ++see;
        if (rh <= -kTauRej) ++below;
      }
      const bool has_lev = !std::isnan(levP[i]);
      const double rp = has_lev ? sd[i] - levP[i] - delta : 0.0;
      const bool floor_strict = has_lev && std::fabs(rp) <= kFloorTol;
      const bool has_m2 = !std::isnan(lev2P[i]);
      const bool m2_above = has_m2 && has_lev && lev2P[i] > levP[i];
      const bool on_m2 =
          has_m2 && std::fabs(sd[i] - lev2P[i] - delta) <= kModeWin;
      const bool on_m2_above = on_m2 && m2_above;
      const bool mirror_hit = on_m2 && !m2_above;
      const bool below_floor = has_lev ? (rp < -kBelowTol)
                                       : (sd[i] - local_off[i] < -kBelowTol);
      const bool struct_ok = static_cast<double>(nn2[i]) <= nn_tol2;
      const bool floor_ok = floor_strict || on_m2_above;
      const bool ray_ok = sup >= kVoteMin && see <= kSeeTol;
      // cell-trust: dense lev must agree with the sparse per-cell anchor up
      // to the global datum; a biased cell (CasDiffMVS local systematic
      // error, self-corroborating across its few covering refs) abstains in
      // BOTH directions. Ghost-dragged anchors move only 3-9mm (cap47
      // verdict) so genuine ghost cells stay trusted.
      const bool cell_trusted =
          has_lev && std::fabs(local_off[i] - levP[i] - delta) <= kCellTrustTol;
      const bool resc = cell_trusted && ray_ok && (floor_ok || struct_ok) &&
                        !below_floor && !mirror_hit;
      // conviction voucher: wider than the rescue voucher (fail-open only)
      const bool vouched = floor_ok ||
                           (has_lev && std::fabs(rp) <= kFloorLooseTol) ||
                           static_cast<double>(nn2[i]) <=
                               kNnVetoTol * kNnVetoTol;
      // see-driven conviction only (conf_below dropped — see header)
      const bool conf_see =
          see >= kConvSeeMin && sup == 0 && !vouched &&
          std::fabs(sd[i] - local_off[i]) >= kConvSparseMargin;
      const bool conf = cell_trusted && !resc && conf_see;
      if (dump) {
        uint8_t* d = &dump_buf[static_cast<size_t>(i) * 20];
        d[0] = static_cast<uint8_t>(std::min(sup, 255));
        d[1] = static_cast<uint8_t>(std::min(see, 255));
        d[2] = static_cast<uint8_t>(std::min(below, 255));
        d[3] = static_cast<uint8_t>(
            (band[i] ? 1 : 0) | (has_lev ? 2 : 0) | (floor_ok ? 4 : 0) |
            (struct_ok ? 8 : 0) | (below_floor ? 16 : 0) |
            (mirror_hit ? 32 : 0) | ((band[i] && resc) ? 64 : 0) |
            ((band[i] && conf) ? 128 : 0));
        const float frp = static_cast<float>(has_lev ? rp : std::nan(""));
        const float fnn = std::sqrt(nn2[i]);
        const float fmh = static_cast<float>(mean_h[i]);
        const float fcb = static_cast<float>(
            has_lev ? local_off[i] - levP[i] - delta : std::nan(""));
        std::memcpy(d + 4, &frp, 4);
        std::memcpy(d + 8, &fnn, 4);
        std::memcpy(d + 12, &fmh, 4);
        std::memcpy(d + 16, &fcb, 4);
      }
      if (!band[i]) continue;
      rescued[i] = resc ? 1 : 0;
      confirmed[i] = conf ? 1 : 0;
      st->n_ray_ok += ray_ok;
      st->n_floor_ok += floor_ok;
      st->n_struct_ok += struct_ok;
      st->n_below_floor += below_floor;
      st->n_mirror_hit += mirror_hit;
      st->n_rescue += resc;
      st->n_confirm += conf;
      st->n_confirm_see += conf;  // see-driven is the only conviction channel
    }
  }
  if (dump)
    detail::WriteFileAtomic(db_dir + "/l1_debug.bin", dump_buf.data(),
                            dump_buf.size());
  st->n_abstain = st->n_band - st->n_rescue - st->n_confirm;

  // ── write back: mask bits 5/6 (idempotent) + stats json ───────────────
  for (uint32_t i = 0; i < n; ++i) {
    uint8_t& f = mask[flag_idx[i]];
    f &= static_cast<uint8_t>(
        ~(aether_ghost::kFlagL1Rescued | aether_ghost::kFlagL1Confirmed));
    if (rescued[i]) f |= aether_ghost::kFlagL1Rescued;
    if (confirmed[i]) f |= aether_ghost::kFlagL1Confirmed;
  }
  if (!detail::WriteFileAtomic(db_dir + "/ghost_mask.bin", mask.data(),
                               mask.size()))
    return fail("ghost_mask.bin rewrite failed");

  char jb[1536];
  std::string used_ids;
  for (size_t i = 0; i < ref_used_ids.size(); ++i) {
    if (i) used_ids += ",";
    char t[16];
    std::snprintf(t, sizeof(t), "%d", ref_used_ids[i]);
    used_ids += t;
  }
  const int jn = std::snprintf(
      jb, sizeof(jb),
      "{\"version\":1,\"refs_planned\":%d,\"refs_used\":%d,"
      "\"refs_used_ids\":[%s],\"n_region\":%d,\"n_band\":%d,"
      "\"rescue\":%d,\"confirm\":%d,\"abstain\":%d,"
      "\"confirm_see\":%d,\"confirm_below\":%d,"
      "\"ray_ok\":%d,\"floor_ok\":%d,\"struct_ok\":%d,"
      "\"below_floor\":%d,\"mirror_hit\":%d,"
      "\"lev_cells\":%d,\"lev2_cells\":%d,"
      "\"ctrl_floor\":%d,\"ctrl_ray\":%d,"
      "\"delta_mm\":%.3f,\"delta_ray_mm\":%.3f,\"degraded\":%s,"
      "\"policy\":\"abstain_visible\","
      "\"bits\":\"5:l1_rescued,6:l1_confirmed\"}\n",
      st->n_refs_planned, st->n_refs_used, used_ids.c_str(), st->n_region,
      st->n_band, st->n_rescue, st->n_confirm, st->n_abstain,
      st->n_confirm_see, st->n_confirm_below, st->n_ray_ok, st->n_floor_ok,
      st->n_struct_ok, st->n_below_floor, st->n_mirror_hit, st->n_lev_cells,
      st->n_lev2_cells, st->n_ctrl_floor, st->n_ctrl_ray, st->delta_mm,
      st->delta_ray_mm, st->degraded ? "true" : "false");
  if (jn > 0 && jn < static_cast<int>(sizeof(jb)))
    detail::WriteFileAtomic(db_dir + "/ghost_arbitration.json", jb,
                            static_cast<size_t>(jn));
  return true;
}

}  // namespace aether_l1
