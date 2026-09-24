// Host test for the ABI v3 viewer look (pwlod_style, PWLOD_PSIZE_VIEWER), the
// flat point-set source (pwlod_viewer_set_points) and the flat -> octree switch.
//
//   test_pointcloud_lod_render_viewer <fixture dir> <scratch dir>
//
// Reference: painter_ref.{h,cpp}, a double-precision transcription of the
// product painter (sparse_cloud_view.dart / cloud_camera.dart @ 86a45cf) with
// its 8-bit canvas and nearest-sampled sprite (R18). The Dart painter's own
// per-point numbers and PNGs (parity_fixture_v3, from the product side) judge
// both the engine and painter_ref in test_parity.cpp.
//
//   V1  per point, GPU (the vertex shader's own function, run by the parity
//       probe) vs the painter: screen x / y within 0.02 px, sprite scale within
//       1e-5 relative, colour (ARGB) EXACT, selection cull flag exact -- for
//       orthographic, perspective, orthoMix 0.5 and rolled cameras; coloured,
//       uncoloured (height ramp), four tones, TINT_OUTSIDE, CULL_OUTSIDE, mask.
//       Tolerances: positions go through float32 (node-relative coordinates,
//       a float32 matrix) where Dart uses double: |error| <= a few ulp of the
//       ~1e3 px screen coordinate (~1e-4 px); 0.02 px leaves 100x margin and is
//       still 1/50 of a pixel. Scale: one float32 division. Colours are baked in
//       double on the CPU (viewer_look.cpp), so they must match to the bit.
//   V2  whole image, GPU (pwlod_viewer_render_once) vs the far->near
//       source-over rasterization of the painter's sprites. The two may differ
//       only where two or more anti-aliased rims lie in front of the nearest
//       fully covered fragment (the painter blends those far->near, the GPU in
//       draw order; the reference marks these pixels "order-sensitive"), plus
//       8-bit rounding of a blend step and the texel picked where a pixel
//       centre sits on a sprite texel edge (float32 vs double position).
//       Judge: pixels with any of the four premultiplied channels off by > 8
//       OUTSIDE the order-sensitive set <= 0.05 % of the image, and PSNR >= 30 dB
//       over the whole image.
//   V3  set_points semantics: the arrays are copied (the caller scribbling on
//       them after the call changes nothing), the mask hides exactly its points
//       (points_drawn), stats.source == 1, lowest_spacing == 0.
//   V4  flat -> octree: load_octree of a tree built from the SAME points
//       replaces the flat set at the next frame (stats.source 1 -> 2) with the
//       camera and style untouched; once every node is drawn, coverage and
//       colour agree with the flat frame (tolerances measured, see the check).
//   N*  negative controls, each must be caught by the same comparison:
//       transposed view_proj, a wrong tone, TINT dropped, the mask ignored.
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

#include "aether/pointcloud_lod_render/pwlod_viewer.h"
#include "judges.h"
#include "painter_ref.h"

using namespace pwlod_judges;

namespace {

struct Cloud { std::vector<float> xyz; std::vector<uint8_t> rgb; size_t n = 0; };

// binary_little_endian, float x y z + uchar red green blue (the product's PLY)
bool ReadPly(const std::string& path, Cloud* c) {
  std::ifstream f(path, std::ios::binary);
  if (!f) return false;
  std::string line;
  size_t n = 0;
  while (std::getline(f, line)) {
    if (line.rfind("element vertex ", 0) == 0) n = std::stoull(line.substr(15));
    if (line.rfind("end_header", 0) == 0) break;
  }
  if (n == 0) return false;
  c->n = n;
  c->xyz.resize(n * 3);
  c->rgb.resize(n * 3);
  for (size_t i = 0; i < n; ++i) {
    char rec[15];
    if (!f.read(rec, 15)) return false;
    std::memcpy(&c->xyz[i * 3], rec, 12);
    std::memcpy(&c->rgb[i * 3], rec + 12, 3);
  }
  return true;
}

uint32_t RgbaToArgb(uint32_t rgba) {
  return ((rgba >> 24) << 24) | ((rgba & 0xFFu) << 16) | (((rgba >> 8) & 0xFFu) << 8) | ((rgba >> 16) & 0xFFu);
}

pwlod_style ToC(const plr::ViewerStyle& s) {
  pwlod_style o;
  pwlod_style_default(&o);
  o.point_size = (float)s.point_size;
  o.sprite_px = (float)s.sprite_px;
  o.disc_radius_px_at_scale1 = (float)s.disc_radius;
  o.max_sprite_scale = (float)s.max_sprite_scale;
  o.tone = (pwlod_tone)s.tone;
  o.exposure = (float)s.exposure;
  o.uncolored_min_y = (float)s.uncolored_min_y;
  o.uncolored_inv_y_span = (float)s.uncolored_inv_y_span;
  o.selection_mode = (pwlod_selection_mode)s.selection_mode;
  for (int k = 0; k < 3; ++k) { o.selection_center[k] = s.selection_center[k]; o.selection_size[k] = s.selection_size[k]; }
  for (int k = 0; k < 9; ++k) o.selection_rot_row_major[k] = s.selection_rot[k];
  o.selection_out_argb = s.selection_out_argb;
  return o;
}

// The style the engine will actually use: pwlod_style is float; round-trip it.
plr::ViewerStyle AsEngineSees(const plr::ViewerStyle& s) {
  const pwlod_style c = ToC(s);
  plr::ViewerStyle v = s;
  v.point_size = c.point_size; v.sprite_px = c.sprite_px; v.disc_radius = c.disc_radius_px_at_scale1;
  v.max_sprite_scale = c.max_sprite_scale; v.exposure = c.exposure;
  v.uncolored_min_y = c.uncolored_min_y; v.uncolored_inv_y_span = c.uncolored_inv_y_span;
  return v;
}

struct Case {
  const char* name;
  painter_ref::CloudCam cam;
  plr::ViewerStyle style;
  bool colored = true;
  bool mask = false;
};

}  // namespace

int main(int argc, char** argv) {
  if (argc < 3) { std::fprintf(stderr, "usage: %s <fixture dir> <scratch dir>\n", argv[0]); return 2; }
  const std::string dir = argv[1];
  std::error_code ec;
  std::filesystem::create_directories(argv[2], ec);
  Report rep;
  Cloud cl;
  if (!ReadPly(dir + "/source.ply", &cl)) { std::fprintf(stderr, "no %s/source.ply\n", dir.c_str()); return 1; }
  const painter_ref::Fit fit = painter_ref::EnsureFit(cl.xyz);
  std::printf("cloud: %zu points, fit radius %.4f, minY %.4f invYSpan %.4f\n\n", cl.n, fit.radius, fit.minY,
              fit.invYSpan);
  const uint32_t W = 600, H = 800;
  std::vector<uint8_t> mask(cl.n);
  for (size_t i = 0; i < cl.n; ++i) mask[i] = (i % 3 == 0) ? 0 : 1;

  pwlod_gpu gpu{};
  if (pwlod_gpu_create(nullptr, 0, &gpu) != PWLOD_OK) { std::fprintf(stderr, "gpu\n"); return 1; }
  plr::GpuCtx g;
  g.instance = gpu.instance; g.adapter = gpu.adapter; g.device = gpu.device; g.queue = gpu.queue;
  plr::Pipe P;
  std::string err;
  if (!plr::MakePipe(g, &P, WGPUTextureFormat_RGBA8Unorm, W, H, 0, &err)) { std::fprintf(stderr, "pipe\n"); return 1; }
  OwnedTarget tgt = MakeTarget(g, W, H);

  // ---- the cases ----
  painter_ref::CloudCam base;
  base.yaw = 0.6; base.pitch = -0.45; base.zoom = 1.0;
  base.pivot[0] = fit.cx; base.pivot[1] = fit.cy; base.pivot[2] = fit.cz;
  base.radius = fit.radius;
  base.orthoMix = 1.0;
  plr::ViewerStyle coloured;   // the product defaults (PBR Neutral, exposure 1, point size 3)
  plr::ViewerStyle ramp = coloured;
  ramp.uncolored_min_y = fit.minY;
  ramp.uncolored_inv_y_span = fit.invYSpan;
  plr::ViewerStyle tint = coloured;
  tint.selection_mode = 1;
  tint.selection_center[0] = fit.cx + 0.1 * fit.radius; tint.selection_center[1] = fit.cy; tint.selection_center[2] = fit.cz;
  tint.selection_size[0] = fit.radius; tint.selection_size[1] = 1.2 * fit.radius; tint.selection_size[2] = 0.8 * fit.radius;
  {   // a box rotated 30 deg about +y (SelectionBox.withYaw uses rotAboutAxisDeg(+y, -yaw))
    const double t = -30.0 * 3.14159265358979323846 / 180.0, c = std::cos(t), s = std::sin(t);
    const double R[9] = {c, 0, s, 0, 1, 0, -s, 0, c};
    std::copy(R, R + 9, tint.selection_rot);
  }
  plr::ViewerStyle cull = tint;
  cull.selection_mode = 2;
  std::vector<Case> cases;
  { Case c{"ortho coloured", base, coloured}; cases.push_back(c); }
  { Case c{"persp coloured", base, coloured}; c.cam.orthoMix = 0.0; c.cam.camDistOverride = 3.0 * fit.radius; cases.push_back(c); }
  { Case c{"mix0.5 coloured", base, coloured}; c.cam.orthoMix = 0.5; c.cam.camDistOverride = 3.0 * fit.radius; cases.push_back(c); }
  { Case c{"ortho roll", base, coloured}; c.cam.roll = 0.7; c.cam.panX = 23; c.cam.panY = -11; cases.push_back(c); }
  { Case c{"persp roll zoom", base, coloured}; c.cam.orthoMix = 0.0; c.cam.roll = -1.1; c.cam.zoom = 1.8; cases.push_back(c); }
  { Case c{"ortho uncoloured", base, ramp}; c.colored = false; cases.push_back(c); }
  { Case c{"ortho tint", base, tint}; cases.push_back(c); }
  { Case c{"persp tint", base, tint}; c.cam.orthoMix = 0.0; cases.push_back(c); }
  { Case c{"ortho cull", base, cull}; cases.push_back(c); }
  { Case c{"ortho mask", base, coloured}; c.mask = true; cases.push_back(c); }
  for (int tone : {0, 1, 3}) {
    Case c{tone == 0 ? "ortho AgX" : tone == 1 ? "ortho ACES" : "ortho None", base, coloured};
    c.style.tone = tone;
    c.style.exposure = tone == 0 ? 1.6 : 1.0;
    cases.push_back(c);
  }

  // Probe the GPU vertex math for a case; `vp` may be tampered with (negatives).
  struct ProbeResult { int64_t compared = 0, posBad = 0, scaleBad = 0, colourBad = 0, cullBad = 0, drawnMismatch = 0; double maxPos = 0; };
  auto probe = [&](const Case& cs_, const plr::ViewerStyle& gpuStyle, bool gpuMask, bool transpose) {
    ProbeResult r;
    const plr::ViewerStyle st = AsEngineSees(cs_.style);
    const plr::ViewerStyle gst = AsEngineSees(gpuStyle);
    const painter_ref::Proj pj = painter_ref::ProjectionFor(cs_.cam, W, H);
    double vp[16], eye[3];
    painter_ref::ViewProj(pj, W, H, 0.02 * fit.radius, 100.0 * pj.camDist + 10.0 * fit.radius, vp, eye);
    if (transpose) { double t[16]; for (int a = 0; a < 4; ++a) for (int b = 0; b < 4; ++b) t[a * 4 + b] = vp[b * 4 + a]; std::memcpy(vp, t, sizeof t); }
    plr::CamState cs{};
    std::memcpy(cs.vp, vp, sizeof vp);
    std::memcpy(cs.cam.viewProj, vp, sizeof vp);
    cs.cam.position = {eye[0], eye[1], eye[2]};
    cs.cam.cloudProjection = true;
    cs.cam.focalPx = pj.f;
    cs.cam.orbitDistance = pj.camDist;
    cs.cam.orthoMix = pj.orthoMix;
    cs.cam.screenWidthPx = (int)W;
    cs.cam.screenHeightPx = (int)H;
    plr::DrawParams dp;
    dp.viewer = &gst;
    plr::FlatSet fs;
    plr::UploadFlat(g, P, cl.xyz.data(), cl.rgb.data(), (cs_.mask && gpuMask) ? mask.data() : nullptr, cl.n,
                    cs_.colored, &gst, &fs);
    std::vector<plr::ViewerProbePoint> gp;
    for (const plr::GpuNode& c : fs.chunks) {
      auto part = plr::ProbeViewerPoints(g, &P, c, fs.origin, cs, dp);
      gp.insert(gp.end(), part.begin(), part.end());
    }
    plr::ReleaseFlat(&fs);
    size_t k = 0;   // GPU records are the uploaded points in order
    for (size_t i = 0; i < cl.n; ++i) {
      const bool uploaded = !((cs_.mask && gpuMask) && mask[i] == 0);
      const bool visible = !(cs_.mask && mask[i] == 0);
      const painter_ref::Pt ref = painter_ref::PaintPoint(pj, st, cs_.colored, &cl.xyz[i * 3], &cl.rgb[i * 3], visible,
                                                          fit.radius, W, H);
      if (!uploaded) { if (ref.drawn) r.drawnMismatch++; continue; }
      if (k >= gp.size()) { r.drawnMismatch++; continue; }
      const plr::ViewerProbePoint& q = gp[k++];
      if (!visible) { r.drawnMismatch++; continue; }   // the GPU has a point the painter never draws
      if (ref.why == 2) { if (q.culled != 1) r.cullBad++; continue; }
      if (!ref.drawn) continue;                          // behind the eye / off screen: clipped by the GPU
      r.compared++;
      if (q.culled != 0) { r.cullBad++; continue; }
      const double dx = std::fabs(q.x - ref.vx), dy = std::fabs(q.y - ref.vy);
      r.maxPos = std::max(r.maxPos, std::max(dx, dy));
      if (!(dx <= 0.02 && dy <= 0.02)) r.posBad++;
      if (!(std::fabs(q.scale - ref.scale) <= 1e-5 * ref.scale)) r.scaleBad++;
      if (RgbaToArgb(q.rgba) != ref.argb) r.colourBad++;
    }
    return r;
  };

  // Whole image through the C ABI.
  auto render = [&](const Case& cs_, const plr::ViewerStyle& gpuStyle, bool gpuMask, bool transpose,
                    pwlod_frame_stats* stOut) {
    const painter_ref::Proj pj = painter_ref::ProjectionFor(cs_.cam, W, H);
    pwlod_camera cam{};
    double eye[3];
    painter_ref::ViewProj(pj, W, H, 0.02 * fit.radius, 100.0 * pj.camDist + 10.0 * fit.radius, cam.view_proj_row_major, eye);
    if (transpose) { double t[16]; for (int a = 0; a < 4; ++a) for (int b = 0; b < 4; ++b) t[a * 4 + b] = cam.view_proj_row_major[b * 4 + a]; std::memcpy(cam.view_proj_row_major, t, sizeof t); }
    for (int k = 0; k < 3; ++k) cam.eye_world[k] = eye[k];
    cam.focal_px = pj.f; cam.orbit_distance = pj.camDist; cam.ortho_mix = pj.orthoMix;
    cam.viewport_width_px = W; cam.viewport_height_px = H;
    pwlod_viewer* v = nullptr;
    pwlod_viewer_create(&gpu, &v);
    pwlod_params prm; pwlod_params_default(&prm);
    for (float& c : prm.background_rgba) c = 0.0f;
    pwlod_viewer_set_params(v, &prm);
    const pwlod_style sty = ToC(gpuStyle);
    pwlod_viewer_set_style(v, &sty);
    pwlod_viewer_set_points(v, cl.xyz.data(), cl.rgb.data(), cl.n, cs_.colored ? 1 : 0,
                            (cs_.mask && gpuMask) ? mask.data() : nullptr);
    pwlod_viewer_set_camera(v, &cam);
    const pwlod_target t{tgt.tex, nullptr};
    pwlod_frame_stats st{};
    pwlod_viewer_render_once(v, &t, WGPUTextureFormat_RGBA8Unorm, W, H, &st);
    if (stOut) *stOut = st;
    Img im = Readback(g, tgt.tex, W, H);
    pwlod_viewer_destroy(v);
    return im;
  };
  std::vector<uint8_t> orderSens;
  auto reference = [&](const Case& cs_) {
    const plr::ViewerStyle st = AsEngineSees(cs_.style);
    const painter_ref::Proj pj = painter_ref::ProjectionFor(cs_.cam, W, H);
    std::vector<painter_ref::Pt> pts(cl.n);
    double vp[16], eye[3];
    painter_ref::ViewProj(pj, W, H, 0.02 * fit.radius, 100.0 * pj.camDist + 10.0 * fit.radius, vp, eye);
    for (size_t i = 0; i < cl.n; ++i) {
      pts[i] = painter_ref::PaintPoint(pj, st, cs_.colored, &cl.xyz[i * 3], &cl.rgb[i * 3], !(cs_.mask && mask[i] == 0),
                                       fit.radius, W, H);
      const double x = cl.xyz[i * 3], y = cl.xyz[i * 3 + 1], z = cl.xyz[i * 3 + 2];
      pts[i].zndc = (float)((vp[8] * x + vp[9] * y + vp[10] * z + vp[11]) / (vp[12] * x + vp[13] * y + vp[14] * z + vp[15]));
    }
    Img im; im.w = W; im.h = H;
    im.px = painter_ref::Rasterize(pts, st, (int)W, (int)H, &orderSens);
    return im;
  };
  // pixels differing by > 8 in any channel (ImgDiff's rule), outside / inside the order-sensitive set
  auto splitDiff = [&](const Img& a, const Img& b, const std::vector<uint8_t>& os, double* outside, double* inside) {
    uint64_t o = 0, in = 0;
    for (size_t i = 0; i < (size_t)W * H; ++i) {
      // any of the four premultiplied channels off by more than 8 (alpha is the
      // anti-aliased coverage here, not a 0/1 coverage flag)
      bool any = false;
      for (int c = 0; c < 4; ++c) any = any || std::abs((int)a.px[i * 4 + c] - (int)b.px[i * 4 + c]) > 8;
      if (!any) continue;
      if (os[i]) in++; else o++;
    }
    *outside = double(o) / double((size_t)W * H);
    *inside = double(in) / double((size_t)W * H);
  };

  // ---- V1 + V2 ----
  for (const Case& c : cases) {
    const ProbeResult r = probe(c, c.style, true, false);
    rep.check(Fmt("V1 per-point parity: %s", c.name).c_str(),
              r.compared > 0 && r.posBad == 0 && r.scaleBad == 0 && r.colourBad == 0 && r.cullBad == 0 &&
                  r.drawnMismatch == 0,
              Fmt("%lld points, max |dpos| %.2g px, pos %lld scale %lld colour %lld cull %lld drawn %lld bad",
                  (long long)r.compared, r.maxPos, (long long)r.posBad, (long long)r.scaleBad,
                  (long long)r.colourBad, (long long)r.cullBad, (long long)r.drawnMismatch));
    pwlod_frame_stats st{};
    const Img gi = render(c, c.style, true, false, &st);
    const Img ri = reference(c);
    const Diff d = ImgDiff(gi, ri);
    const ImgStat gs = Stat(gi);
    double outside = 0, inside = 0;
    splitDiff(gi, ri, orderSens, &outside, &inside);
    if (std::getenv("PWLOD_VIEWER_DUMP")) {   // diagnostic: the first differing pixels
      int shown = 0;
      for (size_t i = 0; i < (size_t)W * H && shown < 12; ++i) {
        bool any = false;
        for (int k = 0; k < 4; ++k) any = any || std::abs((int)gi.px[i * 4 + k] - (int)ri.px[i * 4 + k]) > 8;
        if (!any || orderSens[i]) continue;
        std::printf("    px (%zu,%zu) gpu %d %d %d %d ref %d %d %d %d\n", i % W, i / W, gi.px[i * 4], gi.px[i * 4 + 1],
                    gi.px[i * 4 + 2], gi.px[i * 4 + 3], ri.px[i * 4], ri.px[i * 4 + 1], ri.px[i * 4 + 2], ri.px[i * 4 + 3]);
        shown++;
      }
    }
    size_t sens = 0;
    for (uint8_t o : orderSens) sens += o;
    rep.check(Fmt("V2 whole image vs painter raster: %s", c.name).c_str(),
              outside <= 0.0005 && d.psnr >= 30.0 && gs.cover > 0.01,
              Fmt("differ >8: %.4f %% outside / %.4f %% inside the order-sensitive %.3f %%, PSNR %.1f dB, cov %.3f, %lld pts",
                  100.0 * outside, 100.0 * inside, 100.0 * double(sens) / (W * H), d.psnr, gs.cover,
                  (long long)st.points_drawn));
  }

  // ---- negative controls ----
  std::printf("\nnegative controls (each must be rejected):\n");
  {
    const Case& c = cases[1];   // perspective
    const ProbeResult r = probe(c, c.style, true, true);
    rep.check("N1 transposed view_proj: positions caught", r.posBad > r.compared / 2,
              Fmt("%lld of %lld points off", (long long)r.posBad, (long long)r.compared));
    const Img gi = render(c, c.style, true, true, nullptr);
    const Img ri = reference(c);
    double outside = 0, inside = 0;
    splitDiff(gi, ri, orderSens, &outside, &inside);
    rep.check("N1 transposed view_proj: image caught", outside > 0.0005,
              Fmt("%.2f %% px differ outside the order-sensitive set", 100.0 * outside));
  }
  {
    Case c = cases[0];
    plr::ViewerStyle wrong = c.style;
    wrong.tone = 1;   // ACES where the reference is PBR Neutral
    const ProbeResult r = probe(c, wrong, true, false);
    rep.check("N2 wrong tone: colours caught", r.colourBad > r.compared / 2,
              Fmt("%lld of %lld colours differ", (long long)r.colourBad, (long long)r.compared));
    const Img gi = render(c, wrong, true, false, nullptr);
    const Img ri = reference(c);
    double outside = 0, inside = 0;
    splitDiff(gi, ri, orderSens, &outside, &inside);
    rep.check("N2 wrong tone: image caught", outside > 0.0005,
              Fmt("%.2f %% px differ outside the order-sensitive set", 100.0 * outside));
  }
  {
    const Case& c = cases[6];   // ortho tint
    plr::ViewerStyle noTint = c.style;
    noTint.selection_mode = 0;
    const ProbeResult r = probe(c, noTint, true, false);
    rep.check("N3 TINT dropped: outside points caught", r.colourBad > 0,
              Fmt("%lld colours differ", (long long)r.colourBad));
  }
  {
    const Case& c = cases[9];   // ortho mask
    const ProbeResult r = probe(c, c.style, false, false);
    rep.check("N4 mask ignored: hidden points caught", r.drawnMismatch > 0,
              Fmt("%lld points drawn that the painter hides", (long long)r.drawnMismatch));
  }

  // ---- V3 set_points semantics ----
  {
    const Case& c = cases[9];
    pwlod_frame_stats st{};
    const Img a = render(c, c.style, true, false, &st);
    size_t visible = 0;
    for (uint8_t m : mask) visible += m ? 1 : 0;
    // scribble on the caller's arrays right after set_points: nothing may change
    const painter_ref::Proj pj = painter_ref::ProjectionFor(c.cam, W, H);
    pwlod_camera cam{};
    double eye[3];
    painter_ref::ViewProj(pj, W, H, 0.02 * fit.radius, 100.0 * pj.camDist + 10.0 * fit.radius, cam.view_proj_row_major, eye);
    for (int k = 0; k < 3; ++k) cam.eye_world[k] = eye[k];
    cam.focal_px = pj.f; cam.orbit_distance = pj.camDist; cam.ortho_mix = pj.orthoMix;
    cam.viewport_width_px = W; cam.viewport_height_px = H;
    pwlod_viewer* v = nullptr;
    pwlod_viewer_create(&gpu, &v);
    pwlod_params prm; pwlod_params_default(&prm);
    for (float& x : prm.background_rgba) x = 0.0f;
    pwlod_viewer_set_params(v, &prm);
    std::vector<float> xyz = cl.xyz;
    std::vector<uint8_t> rgb = cl.rgb, msk = mask;
    pwlod_viewer_set_points(v, xyz.data(), rgb.data(), cl.n, 1, msk.data());
    std::fill(xyz.begin(), xyz.end(), 0.0f);
    std::fill(rgb.begin(), rgb.end(), 255);
    std::fill(msk.begin(), msk.end(), 1);
    pwlod_viewer_set_camera(v, &cam);
    const pwlod_target t{tgt.tex, nullptr};
    pwlod_frame_stats st2{};
    pwlod_viewer_render_once(v, &t, WGPUTextureFormat_RGBA8Unorm, W, H, &st2);
    const Img b = Readback(g, tgt.tex, W, H);
    pwlod_viewer_destroy(v);
    rep.check("V3 set_points copies; mask hides its points; source 1; spacing 0",
              Stat(a).hash == Stat(b).hash && st.points_drawn == (int64_t)visible && st2.points_drawn == (int64_t)visible &&
                  st.source == 1 && st.lowest_spacing == 0.0,
              Fmt("points_drawn %lld (visible %zu of %zu), source %d, lowest_spacing %g, images %s",
                  (long long)st.points_drawn, visible, cl.n, st.source, st.lowest_spacing,
                  Stat(a).hash == Stat(b).hash ? "identical" : "DIFFER"));
  }

  // ---- V4 flat -> octree ----
  {
    Case c = cases[1];   // perspective, coloured
    const painter_ref::Proj pj = painter_ref::ProjectionFor(c.cam, W, H);
    pwlod_camera cam{};
    double eye[3];
    painter_ref::ViewProj(pj, W, H, 0.02 * fit.radius, 100.0 * pj.camDist + 10.0 * fit.radius, cam.view_proj_row_major, eye);
    for (int k = 0; k < 3; ++k) cam.eye_world[k] = eye[k];
    cam.focal_px = pj.f; cam.orbit_distance = pj.camDist; cam.ortho_mix = pj.orthoMix;
    cam.viewport_width_px = W; cam.viewport_height_px = H;
    auto run = [&](const plr::ViewerStyle& octStyle, bool shuffleFlat, Img* flatImg, Img* octImg,
                   pwlod_frame_stats* firstOct, pwlod_frame_stats* lastOct) {
      pwlod_viewer* v = nullptr;
      pwlod_viewer_create(&gpu, &v);
      pwlod_params prm; pwlod_params_default(&prm);
      for (float& x : prm.background_rgba) x = 0.0f;
      prm.async_loading = 0;
      prm.point_budget = 100000000;
      prm.target_frame_ms = 1000.0;   // the controller only ever lowers px here
      pwlod_viewer_set_params(v, &prm);
      const pwlod_style sty = ToC(c.style);
      pwlod_viewer_set_style(v, &sty);
      std::vector<uint8_t> rgb = cl.rgb;
      if (shuffleFlat) std::rotate(rgb.begin(), rgb.begin() + 3 * 7, rgb.end());
      pwlod_viewer_set_points(v, cl.xyz.data(), rgb.data(), cl.n, 1, nullptr);
      pwlod_viewer_set_camera(v, &cam);
      const pwlod_target t{tgt.tex, nullptr};
      pwlod_frame_stats st{};
      pwlod_viewer_render_once(v, &t, WGPUTextureFormat_RGBA8Unorm, W, H, &st);
      *flatImg = Readback(g, tgt.tex, W, H);
      pwlod_viewer_load_octree(v, dir.c_str());
      if (octStyle.tone != c.style.tone) { const pwlod_style s2 = ToC(octStyle); pwlod_viewer_set_style(v, &s2); }
      for (int f = 0; f < 400; ++f) {
        pwlod_viewer_render_once(v, &t, WGPUTextureFormat_RGBA8Unorm, W, H, &st);
        if (f == 0) *firstOct = st;
        if (st.points_drawn >= (int64_t)cl.n) break;
      }
      *lastOct = st;
      *octImg = Readback(g, tgt.tex, W, H);
      pwlod_viewer_destroy(v);
    };
    Img fImg, oImg;
    pwlod_frame_stats first{}, last{};
    run(c.style, false, &fImg, &oImg, &first, &last);
    const Diff d = ImgDiff(oImg, fImg);
    const ImgStat fs = Stat(fImg), os = Stat(oImg);
    rep.check("V4 flat -> octree: switch at the next frame, camera / style kept",
              first.source == 2 && last.source == 2 && last.points_drawn == (int64_t)cl.n,
              Fmt("first octree frame source %d (%lld pts), converged %lld / %zu pts, px %.2f", first.source,
                  (long long)first.points_drawn, (long long)last.points_drawn, cl.n, last.min_node_pixel_size));
    rep.check("V4 flat vs octree (same points): coverage and colour agree",
              std::fabs(fs.cover - os.cover) <= 0.002 && d.frac <= 0.01 && d.psnr >= 30.0,
              Fmt("coverage %.4f vs %.4f, %.3f %% px differ >8, PSNR %.1f dB", fs.cover, os.cover, 100.0 * d.frac, d.psnr));
    plr::ViewerStyle aces = c.style;
    aces.tone = 1;
    Img f2, o2;
    run(aces, false, &f2, &o2, &first, &last);
    const Diff dn = ImgDiff(o2, fImg);
    rep.check("V4 NEG octree drawn with another tone differs", dn.frac > 0.01 || dn.psnr < 30.0,
              Fmt("%.2f %% px differ, PSNR %.1f", 100.0 * dn.frac, dn.psnr));
    Img f3, o3;
    run(c.style, true, &f3, &o3, &first, &last);
    const Diff ds = ImgDiff(o3, f3);
    rep.check("V4 NEG flat colours shuffled differs from the octree", ds.frac > 0.01 || ds.psnr < 30.0,
              Fmt("%.2f %% px differ, PSNR %.1f", 100.0 * ds.frac, ds.psnr));
  }

  plr::ReleasePipe(&P);
  ReleaseTarget(&tgt);
  if (plr::GpuErrorCount() != 0) rep.check("no WebGPU errors", false, plr::GpuErrorLog());
  pwlod_gpu_destroy(&gpu);
  return rep.finish();
}
