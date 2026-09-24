// Host test for the moved LOD render pass (plan L1): the PWLodBench `mode=correct`
// judges, run through lod_render.cpp instead of the bench's own copy.
//
//   test_pointcloud_lod_render_render <octree dir> <scratch dir>
//
// Same poses, resolution, budgets and cache as the bench (pw_lod_bench.cpp
// @ b792d57 pwlod_run defaults: 1179 x 2556, budget 3.63M, cache 3 x 15 B x
// budget, reference px = 1 at 20M points, fixed px 150). The LOD pixel size of
// the point-size block is the controller's settled value on the Mac reference
// run (150 / 1.02^147 = 8.16 px, 150 / 1.02^149 = 7.85 px at the leaf pose,
// summary_correct_{36M,216M}.txt) instead of a live controller, so the numbers
// printed here are comparable one to one with that reference.
//
//   L1a leaf visible: at the leaf pose the target leaf is selected and drawn,
//       drawing everything but the leaf changes pixels, the leaf alone covers
//       pixels. Negative controls: minus-leaf twice changes 0 pixels; the frame
//       drawn without adding the node origin back must not match the reference.
//   L1b getLOD three-way (CPU vs brute force vs GPU), every pose. Negative
//       control: the CPU check with every child mask cleared must disagree.
//   L1c async converges to the synchronous frame bit for bit, every pose, with
//       <= 2 uploads/frame, <= 4 in flight, 0 dropped, ancestor-closed GPU set.
//       Negative control: the converged frame minus one visible node must differ.
//   L1d see-through: at every pose where the bench's production point size
//       sees through the surface by more than the 0.25 px jitter floor, Potree's
//       adaptive point size must stay at or below that floor. Negative control:
//       the production formula must exceed the floor at >= 1 pose (the ruler can
//       fail); a tree where it never does reports SKIP.
//   N0  a flat grey frame fails the non-trivial image criterion.
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <string>
#include <vector>

#include "judges.h"

using namespace pwlod_judges;
using aether::pointcloud_lod::Octree;
using aether::pointcloud_lod::SelectParams;
using aether::pointcloud_lod::Vec3;

int main(int argc, char** argv) {
  if (argc < 3) { std::fprintf(stderr, "usage: %s <octree dir> <scratch dir>\n", argv[0]); return 2; }
  const std::string dir = argv[1];
  std::error_code ec;
  std::filesystem::create_directories(argv[2], ec);
  Report rep;

  plr::GpuCtx g;
  std::string err;
  if (!plr::CreateGpu(nullptr, 0, &g, &err)) { std::fprintf(stderr, "GPU: %s\n", err.c_str()); return 1; }
  std::printf("adapter: %s (backend %d)\n", g.adapter_name.c_str(), g.backend);

  Octree oct = lod::loadOctree(dir);
  if (!oct.error.empty()) { std::fprintf(stderr, "load failed: %s\n", oct.error.c_str()); return 1; }

  const uint32_t W = 1179, H = 2556;
  const int64_t budget = 3630000, ref_budget = 20000000;
  const size_t cache_bytes = (size_t)(3.0 * 15.0 * (double)budget);
  const size_t ref_cache = (size_t)(15.0 * 1.1 * (double)ref_budget);
  const double fixed_px = 150.0;

  Traj T;
  ContentFrame(oct, &T.c, &T.R);
  T.leaf = PickLeaf(oct);
  if (T.leaf < 0) { std::fprintf(stderr, "no leaf\n"); return 1; }
  T.leaf_c = oct.nodes[(size_t)T.leaf].box.center();
  T.leaf_r = oct.nodes[(size_t)T.leaf].box.boundingSphereRadius();
  std::printf("tree: %zu nodes, %lld points; target leaf %s (level %d, %u points)\n\n",
              oct.nodes.size(), (long long)oct.totalPointsInNodes(),
              oct.nodes[(size_t)T.leaf].name.c_str(), oct.nodes[(size_t)T.leaf].level,
              oct.nodes[(size_t)T.leaf].numPoints);

  plr::Pipe P;
  if (!plr::MakePipe(g, &P, WGPUTextureFormat_RGBA8Unorm, W, H, 0, &err)) {
    std::fprintf(stderr, "pipe: %s\n", err.c_str());
    return 1;
  }
  OwnedTarget tgt = MakeTarget(g, W, H);
  plr::Lod L;
  L.oct = &oct;
  L.bin_path = dir + "/octree.bin";
  L.max_nodes_loading = 4;
  plr::DrawParams DP;
  DP.base_scale = 1.5;
  DP.octree_size = oct.nodes[0].box.size().x;       // PointCloudOctree.js:318
  DP.octree_spacing = oct.meta.spacing;              // PointCloudOctree.js:315
  auto frame = [&](const plr::CamState& cs, const SelectParams& sp,
                   const plr::DrawOpts& o = plr::DrawOpts()) {
    return plr::LodFrame(g, &L, &P, tgt.target(), cs, sp, DP, T.leaf, 0, o);
  };
  auto read = [&] { return Readback(g, tgt.tex, W, H); };
  auto settled = [](int k) { double px = 150.0; for (int i = 0; i < k; ++i) px = std::max(px / 1.02, 1.0); return px; };

  // N0
  {
    Img gray; gray.w = 64; gray.h = 64; gray.px.assign(64 * 64 * 4, 128);
    for (size_t i = 0; i < 64 * 64; ++i) gray.px[i*4+3] = 255;
    rep.check("N0 a flat grey frame fails the non-trivial criterion", !ImageNonTrivial(Stat(gray)),
              StatJson(Stat(gray)));
  }

  struct PoseDef { const char* name; double t; double px; };
  const PoseDef poses[4] = {{"overview", 0.05, settled(147)}, {"leaf", 0.35, settled(149)},
                            {"orbit_mid", 0.605, settled(147)}, {"pan_mid", 0.855, settled(147)}};
  int seePremise = 0;
  bool seeOk = true;
  std::string seeDetail;
  FILE* sum = std::fopen((std::string(argv[2]) + "/summary.txt").c_str(), "w");
  for (const PoseDef& pd : poses) {
    const char* segname = "";
    const Pose ps = PoseAt(T, pd.t, &segname);
    double zn, zf; NearFar(T, ps, &zn, &zf);
    const plr::CamState cs = MakeCam(ps, (int)W, (int)H, zn, zf);
    std::printf("-- pose %s (lod px %.4f)\n", pd.name, pd.px);

    // reference: px=1, big budget (own cache sized for it)
    plr::ResetLod(&L, ref_cache);
    SelectParams spr; spr.pointBudget = ref_budget; spr.minimumNodePixelSize = 1.0;
    frame(cs, spr);
    const Img iref = read();
    const ImgStat sref = Stat(iref);

    // ── point size: production formula vs Potree ADAPTIVE, same selection ──
    plr::DrawOpts dk; dk.keep_depth = true;
    plr::DrawOpts da = dk; da.psize_mode = 1;
    plr::ResetLod(&L, ref_cache);
    const Vec3 f = Norm(ps.target - ps.eye);
    const Vec3 right = Norm(Cross(f, {0, 1, 0}));
    const double d = (ps.target - ps.eye).length();
    const double wpp = 2.0 * d * std::tan(30.0 * kPi / 180.0) / double(H);
    const plr::CamState csj = MakeCam(Pose{ps.eye + right * (0.25 * wpp), ps.target + right * (0.25 * wpp)},
                                      (int)W, (int)H, zn, zf);
    frame(cs, spr, dk);
    const Img rF = read(); const std::vector<float> rFd = ReadDepth(g, P);
    frame(csj, spr, dk);
    const Img rFj = read(); const std::vector<float> rFjd = ReadDepth(g, P);
    frame(cs, spr, da);
    const Img rA = read(); const std::vector<float> rAd = ReadDepth(g, P);
    plr::ResetLod(&L, cache_bytes);
    SelectParams spc; spc.pointBudget = budget; spc.minimumNodePixelSize = pd.px;
    frame(cs, spc, dk);
    const Img lF = read(); const std::vector<float> lFd = ReadDepth(g, P);
    std::vector<int32_t> drawnA;
    plr::DrawOpts da2 = da; da2.out_drawn = &drawnA;
    const plr::FrameRec frA = frame(cs, spc, da2);
    const Img lA = read(); const std::vector<float> lAd = ReadDepth(g, P);
    const SeeThrough stFloor = SeeThroughVs(rFj, rFjd, rF, rFd, zn, zf);
    const SeeThrough stF = SeeThroughVs(lF, lFd, rF, rFd, zn, zf);
    const SeeThrough stA = SeeThroughVs(lA, lAd, rF, rFd, zn, zf);
    const SeeThrough stAvsA = SeeThroughVs(lA, lAd, rA, rAd, zn, zf);
    const ImgStat sA = Stat(lA);
    const LodCheck lc = VerifyGetLOD(g, &L, &P, drawnA, DP);
    const std::string line = Fmt(
        "%-9s pts %lld vn %d | see-through floor %.4f fixed %.4f adaptive %.4f (hole %.4f far %.4f) "
        "adaptive-vs-adaptive-ref %.4f | adaptive cov %.3f sat %.3f sdmin %.1f | getLOD nodes %d pts %lld "
        "cpu!=bf %lld gpu!=cpu %lld/%lld maxabs %.3g NEG %lld",
        pd.name, (long long)frA.pts_drawn, frA.vn_entries, stFloor.bad, stF.bad, stA.bad, stA.hole,
        stA.farther, stAvsA.bad, sA.cover, sA.sat_mean, SdMin(sA), lc.nodes, (long long)lc.points,
        (long long)lc.cpu_bf_mismatch, (long long)lc.gpu_cpu_mismatch, (long long)lc.gpu_checked,
        lc.gpu_max_abs, (long long)lc.neg_mismatch);
    std::printf("   %s\n", line.c_str());
    if (sum) std::fprintf(sum, "%s\n", line.c_str());
    rep.check(Fmt("L1b getLOD CPU == brute force == GPU (%s)", pd.name).c_str(),
              lc.points > 0 && lc.cpu_bf_mismatch == 0 && lc.gpu_cpu_mismatch == 0 &&
                  lc.gpu_checked == lc.points,
              Fmt("%d nodes, %lld points, cpu!=bf %lld, gpu!=cpu %lld/%lld", lc.nodes,
                  (long long)lc.points, (long long)lc.cpu_bf_mismatch,
                  (long long)lc.gpu_cpu_mismatch, (long long)lc.gpu_checked));
    rep.check(Fmt("L1b NEG masks cleared -> CPU disagrees (%s)", pd.name).c_str(), lc.neg_mismatch > 0,
              Fmt("%lld of %lld points disagree", (long long)lc.neg_mismatch, (long long)lc.points));
    rep.check(Fmt("L1  adaptive frame is non-trivial (%s)", pd.name).c_str(), ImageNonTrivial(sA),
              StatJson(sA));
    if (stF.bad > stFloor.bad) {
      seePremise++;
      if (stA.bad > stFloor.bad) seeOk = false;
      seeDetail += Fmt(" %s: fixed %.4f adaptive %.4f floor %.4f;", pd.name, stF.bad, stA.bad, stFloor.bad);
    }

    // ── async loading: converges to the synchronous frame, never drops ──
    {
      SelectParams sp; sp.pointBudget = budget; sp.minimumNodePixelSize = fixed_px;
      plr::ResetLod(&L, cache_bytes);
      frame(cs, sp);
      const Img syncImg = read();
      plr::ResetLod(&L, cache_bytes, plr::LoadMode::Async);
      int frames = 0, quiet = 0, maxPromo = 0, maxFly = 0, dropped = 0;
      bool ancestorsOk = true;
      for (; frames < 20000 && quiet < 3; ++frames) {
        const plr::FrameRec fr = frame(cs, sp);
        maxPromo = std::max(maxPromo, fr.uploads);
        maxFly = std::max(maxFly, fr.in_flight);
        dropped += fr.dropped;
        for (auto& kv : L.gpu)
          for (int32_t a = oct.nodes[(size_t)kv.first].parent; a >= 0; a = oct.nodes[(size_t)a].parent)
            if (!L.gpu.count(a)) ancestorsOk = false;
        const bool idle = fr.pending_nodes == 0 && fr.uploads == 0 && fr.in_flight == 0;
        quiet = idle ? quiet + 1 : 0;
        if (fr.in_flight > 0) L.aloader->waitAndPoll(20);
      }
      const Img asyncImg = read();
      std::vector<int32_t> drawnNow;
      plr::DrawOpts od; od.out_drawn = &drawnNow;
      frame(cs, sp, od);
      int32_t pick = -1; double bestW = 1e300;
      for (int32_t n : drawnNow) {
        const Vec3 c = oct.nodes[(size_t)n].box.center();
        const double* m = cs.vp;
        const double cx = m[0]*c.x + m[1]*c.y + m[2]*c.z + m[3];
        const double cy = m[4]*c.x + m[5]*c.y + m[6]*c.z + m[7];
        const double cw = m[12]*c.x + m[13]*c.y + m[14]*c.z + m[15];
        if (cw <= 0 || std::fabs(cx / cw) > 0.5 || std::fabs(cy / cw) > 0.5) continue;
        if (oct.nodes[(size_t)n].numPoints == 0) continue;
        if (cw < bestW) { bestW = cw; pick = n; }
      }
      plr::DrawOpts sk; sk.skip_node = pick;
      frame(cs, sp, sk);
      const Img minusOne = read();
      const bool same = Stat(asyncImg).hash == Stat(syncImg).hash;
      const std::string al = Fmt("%-9s async frames %d converged %d ==sync %d maxUpl %d maxFly %d dropped %d "
                                 "ancClosed %d NEG minus1 differs %d",
                                 pd.name, frames, quiet >= 3, same, maxPromo, maxFly, dropped, ancestorsOk,
                                 pick >= 0 && Stat(minusOne).hash != Stat(syncImg).hash);
      std::printf("   %s\n", al.c_str());
      if (sum) std::fprintf(sum, "%s\n", al.c_str());
      rep.check(Fmt("L1c async converges == sync bit for bit (%s)", pd.name).c_str(),
                quiet >= 3 && same && maxPromo <= 2 && maxFly <= 4 && dropped == 0 && ancestorsOk,
                Fmt("%d frames, uploads<=%d, in flight<=%d, dropped %d, ancestors %s", frames, maxPromo,
                    maxFly, dropped, ancestorsOk ? "closed" : "OPEN"));
      rep.check(Fmt("L1c NEG minus one visible node differs (%s)", pd.name).c_str(),
                pick >= 0 && Stat(minusOne).hash != Stat(syncImg).hash,
                pick >= 0 ? "removed " + oct.nodes[(size_t)pick].name : std::string("no visible node"));
    }

    if (std::strcmp(pd.name, "leaf") == 0) {
      plr::ResetLod(&L, cache_bytes);
      SelectParams sp; sp.pointBudget = budget; sp.minimumNodePixelSize = fixed_px;
      const plr::FrameRec ffull = frame(cs, sp);
      const Img full = read();
      plr::DrawOpts skip; skip.skip_node = T.leaf;
      frame(cs, sp, skip);
      const Img noleaf = read();
      frame(cs, sp, skip);
      const Img noleaf2 = read();
      plr::DrawOpts only; only.only_node = T.leaf;
      frame(cs, sp, only);
      const Img leafonly = read();
      plr::DrawOpts noo; noo.no_origin = true;
      frame(cs, sp, noo);
      const Img noorig = read();
      const Diff dleaf = ImgDiff(full, noleaf);
      const Diff dneg = ImgDiff(noleaf, noleaf2);
      const ImgStat sonly = Stat(leafonly);
      const ImgStat snoo = Stat(noorig);
      const Diff dnoo = ImgDiff(noorig, iref);
      const Diff dfull = ImgDiff(full, iref);
      const std::string ll = Fmt("leaf_check selected %d drawn %d pixels_changed_by_leaf %llu "
                                 "neg_same_minus_leaf_pixels %llu leaf_only_px %.0f no_origin matches_ref %d "
                                 "no_origin diff %.4f with_origin diff %.4f",
                                 ffull.target_selected, ffull.target_drawn, (unsigned long long)dleaf.pixels,
                                 (unsigned long long)dneg.pixels, sonly.cover * W * H,
                                 ImageMatchesRef(snoo, sref), dnoo.frac, dfull.frac);
      std::printf("   %s\n", ll.c_str());
      if (sum) std::fprintf(sum, "%s\n", ll.c_str());
      rep.check("L1a target leaf selected, drawn, and visible on screen",
                ffull.target_selected && ffull.target_drawn && dleaf.pixels > 0 && sonly.cover > 0,
                Fmt("minus-leaf changes %llu px, leaf alone covers %.0f px",
                    (unsigned long long)dleaf.pixels, sonly.cover * W * H));
      rep.check("L1a NEG minus-leaf twice changes 0 pixels", dneg.pixels == 0,
                Fmt("%llu px", (unsigned long long)dneg.pixels));
      rep.check("L1a NEG origin not added back -> does not match the reference",
                !ImageMatchesRef(snoo, sref) && dnoo.frac > dfull.frac,
                Fmt("no-origin diff %.4f vs with-origin %.4f", dnoo.frac, dfull.frac));
    }
  }
  if (sum) std::fclose(sum);
  if (seePremise == 0) {
    rep.skipped("L1d adaptive size does not see through (<= jitter floor)",
                "the production formula never sees through by more than the floor on this tree, "
                "so the ruler has nothing to catch");
  } else {
    // Reaching here IS the negative control: the production formula exceeded
    // the floor at seePremise >= 1 pose, so the same ruler does fail.
    rep.check("L1d adaptive size does not see through (<= jitter floor)", seeOk,
              Fmt("NEG production formula sees through at %d pose(s):%s", seePremise, seeDetail.c_str()));
  }
  ReleaseTarget(&tgt);
  plr::ResetLod(&L, 0);
  L.oct = nullptr;
  plr::ReleasePipe(&P);
  if (plr::GpuErrorCount() != 0) {
    rep.check("no WebGPU errors", false, plr::GpuErrorLog());
  }
  plr::ReleaseGpu(&g);
  return rep.finish();
}
