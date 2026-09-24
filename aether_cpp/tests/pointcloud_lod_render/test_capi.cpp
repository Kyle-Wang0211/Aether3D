// Host test for the frozen C ABI (plan L2) and the orthographic render branch.
//
//   test_pointcloud_lod_render_capi <octree dir> <scratch dir>
//
//   C1  the same tree, camera and parameters through pwlod_viewer_render_once
//       and through the C++ render pass directly (lod_render.h LodFrame) give
//       bit-identical images: perspective + ADAPTIVE, perspective + FIXED,
//       orthographic + ADAPTIVE; also the same drawn point count.
//   N1  negative control: view_proj_row_major passed TRANSPOSED (the classic
//       row/column-major mix-up) must give a different image.
//   O1  orthographic + ADAPTIVE renders a non-trivial frame.
//   N2  negative control for R6 (Potree pointcloud.vs:690-692): with the whole
//       tree selected in both, the orthographic frame drawn with the shader's
//       orthographic branch switched off must differ.
//   A1  argument / state contract of pwlod_viewer.h: count != 3, bad format,
//       non-finite camera, unknown projection, start without targets, acquire /
//       get_stats before anything is published, missing and corrupt octree.
//   V2  ABI v2: pwlod_version() ends in "abi=2" == PWLOD_ABI_VERSION, and
//       pwlod_frame_stats.lowest_spacing is bit-identical to selectVisible's
//       Selection::lowestSpacing for the same camera / budget / pixel size,
//       through render_once (perspective and orthographic) and through the
//       render thread's first published frame, and in the async first frame
//       where no node is drawn yet (Potree's value is over popped nodes).
//       Negative control: the viewer made to fill the root's (largest)
//       spacing must be caught by the same comparison.
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <chrono>
#include <fstream>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "aether/pointcloud_lod_render/pwlod_viewer.h"
#include "aether/pointcloud_lod_render/viewer_probe.h"
#include "judges.h"

using namespace pwlod_judges;
using aether::pointcloud_lod::Octree;
using aether::pointcloud_lod::SelectParams;
using aether::pointcloud_lod::Vec3;

namespace {

// v3 camera for the same view: perspective (orthoMix 0, f = 0.5 H / tan(fov/2))
// or orthographic (orthoMix 1, world per pixel = orbit / f = frustum height / H).
pwlod_camera ToCamera(const plr::CamState& cs, const Pose& ps, uint32_t w, uint32_t h, bool ortho) {
  pwlod_camera c{};
  std::memcpy(c.view_proj_row_major, cs.vp, sizeof c.view_proj_row_major);
  c.eye_world[0] = ps.eye.x; c.eye_world[1] = ps.eye.y; c.eye_world[2] = ps.eye.z;
  c.orbit_distance = (ps.target - ps.eye).length();
  if (!ortho) {
    c.focal_px = 0.5 * double(h) / std::tan(cs.cam.fovYDegrees * kPi / 180.0 / 2.0);
    c.ortho_mix = 0.0;
  } else {
    c.focal_px = c.orbit_distance * double(h) / cs.cam.orthoHeight;
    c.ortho_mix = 1.0;
  }
  c.viewport_width_px = w;
  c.viewport_height_px = h;
  return c;
}

// The engine's own conversion (pwlod_viewer.cpp FrameBody step 5), for the
// C++-direct side of C1.
plr::CamState FromC(const pwlod_camera& cam) {
  plr::CamState cs{};
  cs.cam.position = Vec3{cam.eye_world[0], cam.eye_world[1], cam.eye_world[2]};
  std::memcpy(cs.cam.viewProj, cam.view_proj_row_major, sizeof cs.cam.viewProj);
  std::memcpy(cs.vp, cam.view_proj_row_major, sizeof cs.vp);
  cs.cam.screenHeightPx = (int)cam.viewport_height_px;
  cs.cam.screenWidthPx = (int)cam.viewport_width_px;
  cs.cam.cloudProjection = true;
  cs.cam.focalPx = cam.focal_px;
  cs.cam.orbitDistance = cam.orbit_distance;
  cs.cam.orthoMix = cam.ortho_mix;
  cs.cam.fovYDegrees = 2.0 * std::atan(0.5 * double(cam.viewport_height_px) / cam.focal_px) * 180.0 / kPi;
  cs.cam_dist = 1.0;
  return cs;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 3) { std::fprintf(stderr, "usage: %s <octree dir> <scratch dir>\n", argv[0]); return 2; }
  const std::string dir = argv[1];
  const std::string scratch = argv[2];
  std::error_code ec;
  std::filesystem::create_directories(scratch, ec);
  Report rep;
  std::printf("%s\n\n", pwlod_version());

  pwlod_gpu gpu{};
  if (pwlod_gpu_create(nullptr, 0, &gpu) != PWLOD_OK) { std::fprintf(stderr, "gpu\n"); return 1; }
  plr::GpuCtx g;
  g.instance = gpu.instance; g.adapter = gpu.adapter; g.device = gpu.device; g.queue = gpu.queue;
  pwlod_viewer* v = nullptr;
  if (pwlod_viewer_create(&gpu, &v) != PWLOD_OK) { std::fprintf(stderr, "viewer\n"); return 1; }

  // ---- A1 argument / state contract (before anything is loaded) ----
  {
    const uint32_t W = 64, H = 128;
    OwnedTarget t0 = MakeTarget(g, W, H), t1 = MakeTarget(g, W, H), t2 = MakeTarget(g, W, H);
    pwlod_target ts[3] = {{t0.tex, nullptr}, {t1.tex, nullptr}, {t2.tex, nullptr}};
    uint32_t idx = 0; uint64_t fn = 0;
    pwlod_frame_stats st{};
    pwlod_camera bad{};
    bad.focal_px = 1000; bad.orbit_distance = 1; bad.ortho_mix = 0; bad.viewport_width_px = W;
    bad.viewport_height_px = H; bad.view_proj_row_major[0] = std::nan("");
    pwlod_camera badproj = bad;   // v3: ortho_mix outside [0, 1]
    badproj.view_proj_row_major[0] = 1.0;
    badproj.ortho_mix = 1.5;
    pwlod_camera badfocal = badproj;
    badfocal.ortho_mix = 0.5;
    badfocal.focal_px = 0.0;
    pwlod_params bp; pwlod_params_default(&bp); bp.point_budget = 0;
    pwlod_style bs; pwlod_style_default(&bs); bs.tone = (pwlod_tone)9;
    const float pxyz[3] = {0, 0, 0};
    const bool ok =
        pwlod_viewer_set_targets(v, ts, 2, WGPUTextureFormat_RGBA8Unorm, W, H) == PWLOD_ERR_ARG &&
        pwlod_viewer_set_targets(v, ts, 3, WGPUTextureFormat_RGBA16Float, W, H) == PWLOD_ERR_ARG &&
        pwlod_viewer_set_targets(v, ts, 3, WGPUTextureFormat_RGBA8Unorm, W + 1, H) == PWLOD_ERR_ARG &&
        pwlod_viewer_start(v, nullptr, nullptr) == PWLOD_ERR_STATE &&
        pwlod_viewer_acquire_latest(v, &idx, &fn) == PWLOD_ERR_STATE &&
        pwlod_viewer_get_stats(v, &st) == PWLOD_ERR_STATE &&
        pwlod_viewer_set_camera(v, &bad) == PWLOD_ERR_ARG &&
        pwlod_viewer_set_camera(v, &badproj) == PWLOD_ERR_ARG &&
        pwlod_viewer_set_camera(v, &badfocal) == PWLOD_ERR_ARG &&
        pwlod_viewer_set_style(v, &bs) == PWLOD_ERR_ARG &&
        pwlod_viewer_set_points(v, pxyz, nullptr, 1, 1, nullptr) == PWLOD_ERR_ARG &&   // coloured, no rgb
        pwlod_viewer_set_points(v, nullptr, nullptr, 1, 0, nullptr) == PWLOD_ERR_ARG &&
        pwlod_viewer_set_params(v, &bp) == PWLOD_ERR_ARG &&
        pwlod_viewer_render_once(v, &ts[0], WGPUTextureFormat_RGBA8Unorm, W, H, &st) == PWLOD_ERR_STATE &&
        pwlod_viewer_load_octree(v, (scratch + "/does_not_exist").c_str()) == PWLOD_ERR_IO &&
        pwlod_viewer_stop(v) == PWLOD_OK;
    // corrupt octree: metadata.json that is not JSON
    const std::string bad_dir = scratch + "/corrupt";
    std::filesystem::create_directories(bad_dir, ec);
    for (const char* f : {"/metadata.json", "/hierarchy.bin", "/octree.bin"}) {
      std::ofstream o(bad_dir + f, std::ios::binary);
      o << "not an octree";
    }
    const pwlod_status corrupt = pwlod_viewer_load_octree(v, bad_dir.c_str());
    rep.check("A1 pwlod_viewer.h argument / state contract", ok && corrupt == PWLOD_ERR_FORMAT,
              Fmt("corrupt octree -> %d (want %d)", (int)corrupt, (int)PWLOD_ERR_FORMAT));
    ReleaseTarget(&t0); ReleaseTarget(&t1); ReleaseTarget(&t2);
  }

  if (pwlod_viewer_load_octree(v, dir.c_str()) != PWLOD_OK) { std::fprintf(stderr, "load\n"); return 1; }
  Octree oct = lod::loadOctree(dir);

  const uint32_t W = 1179, H = 2556;
  OwnedTarget tgt = MakeTarget(g, W, H);
  const pwlod_target ct{tgt.tex, nullptr};
  pwlod_params prm;
  pwlod_params_default(&prm);
  prm.async_loading = 0;                       // one frame = the whole selection
  prm.background_rgba[3] = 0.0f;               // the bench's clear (0,0,0,0)

  Traj T;
  ContentFrame(oct, &T.c, &T.R);
  T.leaf = PickLeaf(oct);
  T.leaf_c = oct.nodes[(size_t)T.leaf].box.center();
  T.leaf_r = oct.nodes[(size_t)T.leaf].box.boundingSphereRadius();

  // C++ direct: a fresh Lod every time, like the viewer's first frame.
  plr::Pipe P;
  std::string err;
  if (!plr::MakePipe(g, &P, WGPUTextureFormat_RGBA8Unorm, W, H, 0, &err)) { std::fprintf(stderr, "pipe\n"); return 1; }
  pwlod_style defStyleC;
  pwlod_style_default(&defStyleC);
  plr::ViewerStyle defStyle;   // pwlod_style_default as the engine converts it
  defStyle.point_size = defStyleC.point_size; defStyle.sprite_px = defStyleC.sprite_px;
  defStyle.disc_radius = defStyleC.disc_radius_px_at_scale1; defStyle.max_sprite_scale = defStyleC.max_sprite_scale;
  defStyle.exposure = defStyleC.exposure;
  auto direct = [&](const plr::CamState& cs, int psize, double px, int64_t budget, bool fixedPotree,
                    int64_t* pts, std::vector<int32_t>* drawn = nullptr) {
    plr::Lod L;
    L.oct = &oct;
    L.bin_path = dir + "/octree.bin";
    plr::ResetLod(&L, (size_t)(15ull * (uint64_t)budget), plr::LoadMode::Sync);
    plr::DrawParams dp;
    dp.octree_size = oct.nodes[0].box.size().x;
    dp.octree_spacing = oct.meta.spacing;
    if (fixedPotree) { dp.r_min = 1.0; dp.r_max = 1.0; }
    for (int i = 0; i < 4; ++i) dp.clear_rgba[i] = prm.background_rgba[i];
    if (psize == 2) dp.viewer = &defStyle;
    SelectParams sp; sp.pointBudget = budget; sp.minimumNodePixelSize = px;
    plr::DrawOpts o; o.psize_mode = psize; o.out_drawn = drawn;
    const plr::FrameRec fr = plr::LodFrame(g, &L, &P, tgt.target(), cs, sp, dp, -1, 0, o);
    *pts = fr.pts_drawn;
    const Img im = Readback(g, tgt.tex, W, H);
    plr::ResetLod(&L, 0);
    return im;
  };
  auto viaC = [&](const pwlod_camera& cam, const pwlod_params& p, int64_t* pts,
                  pwlod_frame_stats* out = nullptr, bool fillMax = false) {
    pwlod_viewer* vv = nullptr;
    pwlod_viewer_create(&gpu, &vv);             // fresh viewer: controller at Potree's 150 px
    plr::SetFillMaxSpacing(vv, fillMax);
    pwlod_viewer_load_octree(vv, dir.c_str());
    pwlod_viewer_set_params(vv, &p);
    pwlod_viewer_set_camera(vv, &cam);
    pwlod_frame_stats st{};
    const pwlod_status s = pwlod_viewer_render_once(vv, &ct, WGPUTextureFormat_RGBA8Unorm, W, H, &st);
    *pts = s == PWLOD_OK ? st.points_drawn : -1;
    if (out) *out = st;
    Img im = Readback(g, tgt.tex, W, H);
    pwlod_viewer_destroy(vv);
    return im;
  };

  const char* seg = "";
  struct Case { const char* name; double t; };
  const Case cases[2] = {{"overview", 0.05}, {"leaf", 0.35}};
  for (const Case& cs_ : cases) {
    const Pose ps = PoseAt(T, cs_.t, &seg);
    double zn, zf; NearFar(T, ps, &zn, &zf);
    const plr::CamState persp = MakeCam(ps, (int)W, (int)H, zn, zf);
    const double oh = 2.0 * (ps.target - ps.eye).length() * std::tan(30.0 * kPi / 180.0);
    const plr::CamState ortho = MakeOrthoCam(ps, (int)W, (int)H, oh, zn, zf);
    const pwlod_camera cP = ToCamera(persp, ps, W, H, false), cO = ToCamera(ortho, ps, W, H, true);
    const plr::CamState dP = FromC(cP), dO = FromC(cO);

    int64_t pa = 0, pb = 0;
    struct Arm { const char* name; const pwlod_camera* c; const plr::CamState* d; pwlod_point_size_mode mode; int psize; bool fixed; };
    const Arm arms[5] = {{"perspective VIEWER", &cP, &dP, PWLOD_PSIZE_VIEWER, 2, false},
                         {"perspective ADAPTIVE", &cP, &dP, PWLOD_PSIZE_ADAPTIVE, 1, false},
                         {"perspective FIXED", &cP, &dP, PWLOD_PSIZE_FIXED, 0, true},
                         {"orthographic VIEWER", &cO, &dO, PWLOD_PSIZE_VIEWER, 2, false},
                         {"orthographic ADAPTIVE", &cO, &dO, PWLOD_PSIZE_ADAPTIVE, 1, false}};
    for (const Arm& a : arms) {
      pwlod_params pm = prm; pm.point_size_mode = a.mode;
      const Img ia = direct(*a.d, a.psize, 150.0, prm.point_budget, a.fixed, &pa);
      const Img ib = viaC(*a.c, pm, &pb);
      rep.check(Fmt("C1 C ABI == C++ direct, %s (%s)", a.name, cs_.name).c_str(),
                Stat(ia).hash == Stat(ib).hash && pa == pb && pa > 0 && Stat(ia).cover > 0.001,
                Fmt("%016llx vs %016llx, %lld vs %lld pts", (unsigned long long)Stat(ia).hash,
                    (unsigned long long)Stat(ib).hash, (long long)pa, (long long)pb));
    }
    // N1: transposed matrix through the C ABI (default VIEWER look)
    {
      const Img a = direct(dP, 2, 150.0, prm.point_budget, false, &pa);
      pwlod_camera tc = cP;
      for (int r = 0; r < 4; ++r)
        for (int c = 0; c < 4; ++c) tc.view_proj_row_major[r * 4 + c] = cP.view_proj_row_major[c * 4 + r];
      int64_t pt = 0;
      const Img t = viaC(tc, prm, &pt);
      rep.check(Fmt("N1 NEG transposed view_proj differs (%s)", cs_.name).c_str(),
                Stat(t).hash != Stat(a).hash && ImgDiff(t, a).frac > 0.001,
                Fmt("diff frac %.4f, %lld pts", ImgDiff(t, a).frac, (long long)pt));
    }
    {
      pwlod_params pa2 = prm; pa2.point_size_mode = PWLOD_PSIZE_ADAPTIVE;
      const Img a = direct(dO, 1, 150.0, prm.point_budget, false, &pa);
      rep.check(Fmt("O1 orthographic ADAPTIVE frame non-trivial (%s)", cs_.name).c_str(),
                ImageNonTrivial(Stat(a)), StatJson(Stat(a)));
      (void)pa2;
    }
  }

  // N2: px 0 and an unlimited budget, so the frustum is the only filter and
  // both frames draw the same node list; only the shader's orthographic branch
  // differs.
  {
    const Pose ps = PoseAt(T, 0.05, &seg);
    double zn, zf; NearFar(T, ps, &zn, &zf);
    const double oh = 2.0 * (ps.target - ps.eye).length() * std::tan(30.0 * kPi / 180.0);
    plr::CamState ortho = MakeOrthoCam(ps, (int)W, (int)H, oh, zn, zf);
    const int64_t all = oct.totalPointsInNodes();
    int64_t pa = 0, pb = 0;
    std::vector<int32_t> da, db;
    const Img a = direct(ortho, 1, 0.0, all + 1, false, &pa, &da);
    // Same selection with the branch off: FrameU.ortho = 0.
    plr::CamState off = ortho;
    off.cam.orthographic = false;
    off.cam.fovYDegrees = 60.0;
    const Img b = direct(off, 1, 0.0, all + 1, false, &pb, &db);
    std::sort(da.begin(), da.end());
    std::sort(db.begin(), db.end());
    const bool sameSel = pa == pb && pa > 0 && da == db;
    if (!sameSel) {
      rep.skipped("N2 NEG orthographic shader branch off differs",
                  Fmt("selections differ (%lld vs %lld points): not an isolated test",
                      (long long)pa, (long long)pb));
    } else {
      rep.check("N2 NEG orthographic shader branch off differs", ImgDiff(a, b).pixels > 0,
                Fmt("%llu pixels differ, both draw the same %zu nodes / %lld points",
                    (unsigned long long)ImgDiff(a, b).pixels, da.size(), (long long)pa));
    }
  }

  // ---- V2: ABI v2 lowest_spacing ----
  {
    const std::string ver = pwlod_version();
    const std::string tail = std::string("abi=") + std::to_string(PWLOD_ABI_VERSION);
    rep.check("V2 pwlod_version() reports abi=3 (== PWLOD_ABI_VERSION)",
              PWLOD_ABI_VERSION == 3 && ver.size() > tail.size() &&
                  ver.compare(ver.size() - tail.size(), tail.size(), tail) == 0,
              "\"" + ver + "\"");
    auto bits = [](double a, double b) { return std::memcmp(&a, &b, sizeof a) == 0; };
    auto selLowest = [&](const plr::CamState& cs) {
      SelectParams sp; sp.pointBudget = prm.point_budget; sp.minimumNodePixelSize = 150.0;
      return lod::selectVisible(oct, cs.cam, sp).lowestSpacing;
    };
    const Pose ps = PoseAt(T, 0.35, &seg);   // the leaf pose: deep nodes, small spacing
    double zn, zf; NearFar(T, ps, &zn, &zf);
    const plr::CamState persp0 = MakeCam(ps, (int)W, (int)H, zn, zf);
    const double oh = 2.0 * (ps.target - ps.eye).length() * std::tan(30.0 * kPi / 180.0);
    const plr::CamState ortho0 = MakeOrthoCam(ps, (int)W, (int)H, oh, zn, zf);
    const pwlod_camera cP = ToCamera(persp0, ps, W, H, false), cO = ToCamera(ortho0, ps, W, H, true);
    const plr::CamState persp = FromC(cP), ortho = FromC(cO);
    int64_t pts = 0;
    pwlod_frame_stats sp{}, so{};
    viaC(cP, prm, &pts, &sp);
    viaC(cO, prm, &pts, &so);
    const double wantP = selLowest(persp), wantO = selLowest(ortho);
    rep.check("V2 render_once lowest_spacing == selectVisible's (bit for bit)",
              sp.nodes_drawn > 0 && so.nodes_drawn > 0 && wantP > 0 && bits(sp.lowest_spacing, wantP) &&
                  bits(so.lowest_spacing, wantO),
              Fmt("perspective %.17g vs %.17g, orthographic %.17g vs %.17g", sp.lowest_spacing, wantP,
                  so.lowest_spacing, wantO));
    // the render thread: first published frame (sync, controller still at 150 px)
    {
      OwnedTarget r0 = MakeTarget(g, W, H), r1 = MakeTarget(g, W, H), r2 = MakeTarget(g, W, H);
      const pwlod_target rts[3] = {{r0.tex, nullptr}, {r1.tex, nullptr}, {r2.tex, nullptr}};
      pwlod_viewer* vr = nullptr;
      pwlod_viewer_create(&gpu, &vr);
      pwlod_viewer_load_octree(vr, dir.c_str());
      pwlod_viewer_set_params(vr, &prm);
      pwlod_viewer_set_camera(vr, &cP);
      pwlod_viewer_set_targets(vr, rts, 3, WGPUTextureFormat_RGBA8Unorm, W, H);
      struct First { std::mutex mu; bool got = false; pwlod_frame_stats st{}; } first;
      pwlod_viewer_start(vr, [](void* u, uint32_t, const pwlod_frame_stats* st) {
        First* f = static_cast<First*>(u);
        std::lock_guard<std::mutex> lk(f->mu);
        if (!f->got && st->frame_number == 1) { f->st = *st; f->got = true; }
      }, &first);
      for (int i = 0; i < 400; ++i) {
        { std::lock_guard<std::mutex> lk(first.mu); if (first.got) break; }
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
      }
      pwlod_viewer_stop(vr);
      pwlod_viewer_destroy(vr);
      for (OwnedTarget* x : {&r0, &r1, &r2}) ReleaseTarget(x);
      rep.check("V2 render thread lowest_spacing == selectVisible's (bit for bit)",
                first.got && first.st.nodes_drawn > 0 && bits(first.st.lowest_spacing, wantP),
                Fmt("frame %llu: %.17g vs %.17g", (unsigned long long)first.st.frame_number,
                    first.st.lowest_spacing, wantP));
    }
    // Potree's definition (D18) is over every POPPED node, so it does not depend
    // on what was drawn: the async first frame (0 nodes drawn, nodes only being
    // requested) must still report select's value. (Under the first v2 wording,
    // "among the nodes drawn", this frame reported 0.)
    {
      pwlod_params pa = prm; pa.async_loading = 1;
      pwlod_frame_stats sa{};
      viaC(cP, pa, &pts, &sa);
      rep.check("V2 async first frame (0 drawn) lowest_spacing == selectVisible's",
                sa.nodes_drawn == 0 && wantP > 0 && bits(sa.lowest_spacing, wantP),
                Fmt("%d nodes drawn, lowest_spacing %.17g vs select %.17g", sa.nodes_drawn,
                    sa.lowest_spacing, wantP));
    }
    // negative control: the largest spacing filled in must be caught
    {
      pwlod_frame_stats sn{};
      viaC(cP, prm, &pts, &sn, true);
      rep.check("V2 NEG largest spacing filled in -> judge reports it",
                !bits(sn.lowest_spacing, wantP) && sn.lowest_spacing == oct.nodes[0].spacing,
                Fmt("filled %.17g (root) vs select %.17g", sn.lowest_spacing, wantP));
    }
  }

  plr::ReleasePipe(&P);
  ReleaseTarget(&tgt);
  pwlod_viewer_destroy(v);
  if (plr::GpuErrorCount() != 0) rep.check("no WebGPU errors", false, plr::GpuErrorLog());
  pwlod_gpu_destroy(&gpu);
  return rep.finish();
}
