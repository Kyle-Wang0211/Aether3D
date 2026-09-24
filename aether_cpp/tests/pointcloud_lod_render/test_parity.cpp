// Host test: the ABI v3 viewer against the product painter's OWN numbers and
// pixels -- not against our transcription of it (painter_ref, whose own gap to
// the painter this test also reports).
//
//   test_pointcloud_lod_render_parity <parity_fixture_v3 dir> <scratch dir>
//
// The fixture comes from the product side (feat/lod-on-dense-168 @ 44bf12f,
// test/point_cloud_lod/painter_parity_fixture_v3_test.dart): the real Dart
// SparseCloudPainter with its real 16x16 sprite, a 1536-point cloud (coloured,
// and the same points uncoloured = height ramp), 27 groups = 7 cameras
// (orthographic default / zoom+pan / roll, the capture perspective with
// camDistOverride, orthoMix 0.5, perspective near with roll, perspective at the
// 50/16 size cap) x looks (plain, TINT_OUTSIDE, CULL_OUTSIDE, visibility mask,
// wrong-length mask). Per group: every point's vx / vy / scale / argb / draw
// order (or drawn = false), the projection scalars, the style, and the painted
// frame as PNG at 1x and 3x (canvas.scale(3), like the phone) on black.
//
// The test plays the shell: pwlod_camera from the projection scalars
// (painter_ref::ViewProj; near plane = the painter's near cull, 0.02 R). At a
// device pixel ratio d the target is d x the logical size and focal_px, the
// origin, point_size and max_sprite_scale are multiplied by d (the painter
// scales its canvas; pwlod_style and pwlod_camera are in target pixels). A mask
// of the wrong length is dropped by the shell (the painter ignores it; the ABI
// cannot see a length).
//
//   T0  the engine's sprite (R18, kPainterSpriteAlpha) IS the painter's: every
//       3x pixel covered by exactly one sprite quad and >= 0.02 texel from a
//       texel edge equals round(colour * alpha / 255) in all three channels, no
//       exception. NEG: the analytic disc (radius + 0.5 - r) must fail.
//   P1  per point, the GPU vertex math (the parity probe) vs the Dart numbers,
//       1x and 3x: identical drawn set (mask, CULL_OUTSIDE, near cull, and the
//       painter's 24 px off-screen skip applied to the GPU's own position --
//       a skipped point's sprite cannot reach the screen: its outermost
//       non-zero texel is < 7.1 texels x 50/16 = 22.2 px from the centre);
//       drawn points: |dx|, |dy| <= 0.02 logical px, scale within 1e-5
//       relative, ARGB exact. Tolerances: the GPU projects in float32 (a
//       float32 matrix on centred coordinates) where Dart uses double; measured
//       <= 2e-4 px, so 0.02 px keeps 100x margin and is 1/50 of a pixel. Scale:
//       one float32 division. Colours are baked in double (viewer_look.cpp).
//   P2  whole frame, GPU (pwlod_viewer_render_once) vs the Dart PNG, RGB, 1x
//       and 3x. The only admitted differences (see the judge for the numbers):
//       (a) ORDER: pixels where two or more partially covering sprite texels lie
//       in front of the nearest fully covering one, or where the two nearest
//       full ones are a float32 depth tie -- the painter blends far->near, the
//       GPU occludes with a depth buffer and blends rims in draw order (R14);
//       marked from the Dart numbers (positions, scale, draw_order) by
//       painter_ref::Rasterize and excluded; (b) the 8-bit rounding of each
//       blend (GPU: float then one rounding; painter: rounding per step), <= a
//       few LSB; (c) texel choice at a texel edge: the GPU position differs from
//       Dart's by <= 2e-4 px, so a pixel centre within that of a sprite texel
//       edge may take the neighbouring texel.
//   R   painter_ref (the transcription test_viewer judges against) vs the same
//       Dart numbers: R0 ProjectionFor vs the projection scalars (1e-9), R1
//       PaintPoint per point (drawn set and argb exact; position / scale within
//       the float32 rounding of the fixture's atlas numbers). Its raster vs the
//       PNG is reported per group next to the engine's.
//   N1  transposed view_proj    must fail P1 (positions) and P2
//   N2  wrong tone (ACES)       must fail P1 (argb) and P2
//   N3  TINT_OUTSIDE dropped    must fail P1 (argb) and P2
//   N4  visibility mask ignored must fail P1 (drawn set) and P2
//   N5  the analytic disc (the engine before R18) must fail P2 at 3x
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

#include "aether/pointcloud_lod_render/pwlod_viewer.h"
#include "judges.h"
#include "nlohmann/json.hpp"
#include "painter_ref.h"
#include "png_read.h"

using namespace pwlod_judges;
using Json = nlohmann::json;

namespace {

// ---- exception-free JSON access (this test is built with -fno-exceptions) ----
const Json* Field(const Json& j, const char* k) {
  if (!j.is_object()) return nullptr;
  const auto it = j.find(k);
  return it == j.end() ? nullptr : &*it;
}
bool Num(const Json& j, const char* k, double* out) {
  const Json* f = Field(j, k);
  if (!f || !f->is_number()) return false;
  *out = f->get<double>();
  return true;
}
bool NumArr(const Json& j, const char* k, std::vector<double>* out) {
  const Json* f = Field(j, k);
  if (!f || !f->is_array()) return false;
  out->clear();
  for (const Json& e : *f) {
    if (!e.is_number()) return false;
    out->push_back(e.get<double>());
  }
  return true;
}
bool Str(const Json& j, const char* k, std::string* out) {
  const Json* f = Field(j, k);
  if (!f || !f->is_string()) return false;
  *out = f->get<std::string>();
  return true;
}
bool Bool(const Json& j, const char* k, bool* out) {
  const Json* f = Field(j, k);
  if (!f || !f->is_boolean()) return false;
  *out = f->get<bool>();
  return true;
}
bool ReadJson(const std::string& path, Json* out) {
  std::ifstream f(path, std::ios::binary);
  if (!f) return false;
  std::stringstream ss;
  ss << f.rdbuf();
  *out = Json::parse(ss.str(), nullptr, /*allow_exceptions=*/false);
  return !out->is_discarded();
}

struct Cloud { std::vector<float> xyz; std::vector<uint8_t> rgb; size_t n = 0; };

struct DartPt {
  bool drawn = false;
  double vx = 0, vy = 0, scale = 0, tx = 0, ty = 0;
  uint32_t argb = 0;
  int64_t order = -1;
};

struct Group {
  std::string name, cloud, png1, png3, vis_kind;
  bool colored = true;
  double size[2] = {0, 0};
  painter_ref::CloudCam cam;           // for ProjectionFor (R0)
  painter_ref::Proj proj;              // the fixture's scalars
  pwlod_style style{};                 // logical px, as the painter uses it
  plr::ViewerStyle dstyle;             // the same in double (painter_ref)
  double near_cull = 0, margin = 24;
  std::vector<uint8_t> mask;           // empty = none / dropped by the shell
  std::vector<DartPt> pts;
};

bool LoadCloud(const std::string& path, Cloud* c) {
  Json j;
  std::vector<double> xyz, rgb;
  double n = 0;
  if (!ReadJson(path, &j) || !Num(j, "n", &n) || !NumArr(j, "xyz_float32", &xyz) || !NumArr(j, "rgb_u8", &rgb))
    return false;
  c->n = (size_t)n;
  if (xyz.size() != c->n * 3 || rgb.size() != c->n * 3) return false;
  c->xyz.resize(xyz.size());
  c->rgb.resize(rgb.size());
  for (size_t i = 0; i < xyz.size(); ++i) c->xyz[i] = (float)xyz[i];   // exact: the values are float32
  for (size_t i = 0; i < rgb.size(); ++i) c->rgb[i] = (uint8_t)rgb[i];
  return true;
}

bool LoadGroup(const std::string& path, Group* g, std::string* why) {
  Json j;
  if (!ReadJson(path, &j)) { *why = "unreadable json"; return false; }
  std::vector<double> sz, piv, cen, siz, rot;
  bool ok = Str(j, "name", &g->name) && Str(j, "cloud", &g->cloud) && Bool(j, "colored", &g->colored) &&
            NumArr(j, "size_logical", &sz) && sz.size() == 2 && Str(j, "png_1x", &g->png1) && Str(j, "png_3x", &g->png3);
  if (!ok) { *why = "header fields"; return false; }
  g->size[0] = sz[0]; g->size[1] = sz[1];
  const Json* cam = Field(j, "camera");
  const Json* pr = Field(j, "projection");
  const Json* st = Field(j, "style");
  const Json* vis = Field(j, "visibility");
  const Json* pts = Field(j, "points");
  if (!cam || !pr || !st || !vis || !pts || !pts->is_array()) { *why = "sections"; return false; }
  // camera (R0: ProjectionFor must reproduce the projection)
  painter_ref::CloudCam& c = g->cam;
  std::vector<double> cpiv;
  ok = Num(*cam, "yaw", &c.yaw) && Num(*cam, "pitch", &c.pitch) && Num(*cam, "roll", &c.roll) &&
       Num(*cam, "zoom", &c.zoom) && Num(*cam, "pan_x", &c.panX) && Num(*cam, "pan_y", &c.panY) &&
       NumArr(*cam, "pivot", &cpiv) && cpiv.size() == 3 && Num(*cam, "ortho_mix", &c.orthoMix) &&
       Num(*cam, "fill_k", &c.fillK) && Num(*cam, "fit_radius", &c.radius);
  if (!ok) { *why = "camera"; return false; }
  for (int k = 0; k < 3; ++k) c.pivot[k] = cpiv[k];
  const Json* cdo = Field(*cam, "cam_dist_override");
  c.camDistOverride = (cdo && cdo->is_number()) ? cdo->get<double>() : -1.0;
  painter_ref::Proj& p = g->proj;
  ok = Num(*pr, "cos_y", &p.cosY) && Num(*pr, "sin_y", &p.sinY) && Num(*pr, "cos_p", &p.cosP) &&
       Num(*pr, "sin_p", &p.sinP) && Num(*pr, "f", &p.f) && Num(*pr, "cam_dist", &p.camDist) &&
       Num(*pr, "ox", &p.ox) && Num(*pr, "oy", &p.oy) && NumArr(*pr, "pivot", &piv) && piv.size() == 3 &&
       Num(*pr, "ortho_mix", &p.orthoMix) && Num(*pr, "cos_r", &p.cosR) && Num(*pr, "sin_r", &p.sinR);
  if (!ok) { *why = "projection"; return false; }
  for (int k = 0; k < 3; ++k) p.pivot[k] = piv[k];
  // style
  double ps, spx, dr, mx, tone, expo, miny, inv, outc;
  std::string mode;
  ok = Num(*st, "point_size", &ps) && Num(*st, "sprite_px", &spx) && Num(*st, "disc_radius_px_at_scale1", &dr) &&
       Num(*st, "max_sprite_scale", &mx) && Num(*st, "tone", &tone) && Num(*st, "exposure", &expo) &&
       Num(*st, "uncolored_min_y", &miny) && Num(*st, "uncolored_inv_y_span", &inv) &&
       Str(*st, "selection_mode", &mode) && Num(*st, "selection_out_argb", &outc) &&
       Num(*st, "near_cull_depth", &g->near_cull) && Num(*st, "offscreen_margin_px", &g->margin);
  if (!ok) { *why = "style"; return false; }
  pwlod_style& s = g->style;
  pwlod_style_default(&s);
  s.point_size = (float)ps; s.sprite_px = (float)spx; s.disc_radius_px_at_scale1 = (float)dr;
  s.max_sprite_scale = (float)mx; s.tone = (pwlod_tone)(int)tone; s.exposure = (float)expo;
  s.uncolored_min_y = (float)miny; s.uncolored_inv_y_span = (float)inv;
  s.selection_out_argb = (uint32_t)outc;
  s.selection_mode = mode == "tint" ? PWLOD_SEL_TINT_OUTSIDE : mode == "cull" ? PWLOD_SEL_CULL_OUTSIDE : PWLOD_SEL_NONE;
  plr::ViewerStyle& d = g->dstyle;
  d.point_size = ps; d.sprite_px = spx; d.disc_radius = dr; d.max_sprite_scale = mx; d.tone = (int)tone;
  d.exposure = expo; d.uncolored_min_y = miny; d.uncolored_inv_y_span = inv;
  d.selection_mode = (int)s.selection_mode; d.selection_out_argb = s.selection_out_argb;
  if (s.selection_mode != PWLOD_SEL_NONE) {
    if (!NumArr(*st, "selection_center", &cen) || !NumArr(*st, "selection_size", &siz) ||
        !NumArr(*st, "selection_rot_row_major", &rot) || cen.size() != 3 || siz.size() != 3 || rot.size() != 9) {
      *why = "selection box"; return false;
    }
    for (int k = 0; k < 3; ++k) {
      s.selection_center[k] = d.selection_center[k] = cen[k];
      s.selection_size[k] = d.selection_size[k] = siz[k];
    }
    for (int k = 0; k < 9; ++k) s.selection_rot_row_major[k] = d.selection_rot[k] = rot[k];
  }
  // visibility: the shell passes a mask only when its length is the cloud's
  if (!Str(*vis, "kind", &g->vis_kind)) { *why = "visibility"; return false; }
  std::vector<double> m;
  if (g->vis_kind != "none" && NumArr(*vis, "mask_u8", &m)) {
    g->mask.resize(m.size());
    for (size_t i = 0; i < m.size(); ++i) g->mask[i] = (uint8_t)m[i];
  }
  // points
  for (const Json& e : *pts) {
    DartPt q;
    if (!Bool(e, "drawn", &q.drawn)) { *why = "point"; return false; }
    if (q.drawn) {
      double argb = 0, order = 0;
      std::vector<double> rst;
      if (!Num(e, "vx", &q.vx) || !Num(e, "vy", &q.vy) || !Num(e, "scale", &q.scale) || !Num(e, "argb", &argb) ||
          !Num(e, "draw_order", &order) || !NumArr(e, "rst", &rst) || rst.size() != 4) {
        *why = "drawn point"; return false;
      }
      q.argb = (uint32_t)argb;
      q.order = (int64_t)order;
      q.tx = rst[2]; q.ty = rst[3];
    }
    g->pts.push_back(q);
  }
  return true;
}

// The frame as the shell hands it to the engine at device pixel ratio d.
struct Frame {
  uint32_t W = 0, H = 0;
  painter_ref::Proj pd;     // projection in target pixels
  double vp[16], eye[3];
  pwlod_camera cam{};
  pwlod_style style{};
  plr::ViewerStyle vstyle;  // what the engine sees (from the float pwlod_style)
};
plr::ViewerStyle ToStyle(const pwlod_style& s) {   // = pwlod_viewer.cpp ToStyle
  plr::ViewerStyle v;
  v.point_size = s.point_size; v.sprite_px = s.sprite_px; v.disc_radius = s.disc_radius_px_at_scale1;
  v.max_sprite_scale = s.max_sprite_scale; v.tone = (int)s.tone; v.exposure = s.exposure;
  v.uncolored_min_y = s.uncolored_min_y; v.uncolored_inv_y_span = s.uncolored_inv_y_span;
  v.selection_mode = (int)s.selection_mode;
  for (int k = 0; k < 3; ++k) { v.selection_center[k] = s.selection_center[k]; v.selection_size[k] = s.selection_size[k]; }
  for (int k = 0; k < 9; ++k) v.selection_rot[k] = s.selection_rot_row_major[k];
  v.selection_out_argb = s.selection_out_argb;
  return v;
}
Frame MakeFrame(const Group& g, double d, const pwlod_style& logicalStyle, bool transpose) {
  Frame F;
  F.W = (uint32_t)std::lround(g.size[0] * d);
  F.H = (uint32_t)std::lround(g.size[1] * d);
  F.pd = g.proj;
  F.pd.f *= d; F.pd.ox *= d; F.pd.oy *= d;
  const double zf = 100.0 * g.proj.camDist + 10.0 * g.cam.radius;
  painter_ref::ViewProj(F.pd, F.W, F.H, g.near_cull, zf, F.vp, F.eye);
  if (transpose) {
    double t[16];
    for (int a = 0; a < 4; ++a) for (int b = 0; b < 4; ++b) t[a * 4 + b] = F.vp[b * 4 + a];
    std::memcpy(F.vp, t, sizeof t);
  }
  std::memcpy(F.cam.view_proj_row_major, F.vp, sizeof F.vp);
  for (int k = 0; k < 3; ++k) F.cam.eye_world[k] = F.eye[k];
  F.cam.focal_px = F.pd.f;
  F.cam.orbit_distance = F.pd.camDist;
  F.cam.ortho_mix = F.pd.orthoMix;
  F.cam.viewport_width_px = F.W;
  F.cam.viewport_height_px = F.H;
  F.style = logicalStyle;
  F.style.point_size = (float)(logicalStyle.point_size * d);
  F.style.max_sprite_scale = (float)(logicalStyle.max_sprite_scale * d);
  F.vstyle = ToStyle(F.style);
  return F;
}

float Zndc(const double vp[16], const float* p) {
  const double x = p[0], y = p[1], z = p[2];
  return (float)((vp[8] * x + vp[9] * y + vp[10] * z + vp[11]) / (vp[12] * x + vp[13] * y + vp[14] * z + vp[15]));
}

inline int Div255(int x) { return (x + 127) / 255; }

// P2 bounds. Outside the order-sensitive set a pixel can still differ by a whole
// texel step where its centre sits on a sprite texel edge: the painter decides
// that tie in its own float32 arithmetic (Skia's inverse atlas transform), and
// the painter's frame rebuilt from its own per-point numbers in double already
// disagrees with its PNG on up to 0.0009 % of pixels (reported per group as
// "painter model"); the GPU adds its <= 2e-4 px position error. Measured engine
// worst 0.0010 % (1x) / 0.0005 % (3x) -> bound 0.005 %: 5x the worst, and the
// smallest negative control (mask ignored) sits at 0.89 %. PSNR outside the set
// (RGB): 8-bit blend rounding is <= 1-2 LSB; the texel-edge ties above are what
// lower it; measured worst 60.0 dB (1x) / 62.8 dB (3x) -> bound 50 dB.
constexpr double kP2Outside = 0.00005;
constexpr double kP2Psnr = 50.0;

struct PerPoint {
  int64_t compared = 0, drawnMismatch = 0, posBad = 0, scaleBad = 0, colourBad = 0;
  double maxPos = 0, maxScaleRel = 0;
};
struct ImgCmp { double outside = 0, inside = 0, sens = 0, psnr = 0, psnrOutside = 0; int maxOutside = 0; };

// RGB of `a` (RGBA, alpha ignored) vs the PNG `ref`: pixels with any channel off
// by > 8 outside / inside the order-sensitive set; PSNR over RGB.
ImgCmp CompareRgb(const std::vector<uint8_t>& a, const std::vector<uint8_t>& ref, const std::vector<uint8_t>& os,
                  size_t npx) {
  ImgCmp c;
  uint64_t o = 0, in = 0, s = 0;
  double se = 0, seOut = 0;
  for (size_t i = 0; i < npx; ++i) {
    int m = 0;
    for (int k = 0; k < 3; ++k) {
      const int dlt = std::abs((int)a[i * 4 + k] - (int)ref[i * 4 + k]);
      m = std::max(m, dlt);
      se += double(dlt) * dlt;
      if (!os[i]) seOut += double(dlt) * dlt;
    }
    if (os[i]) s++;
    if (m > 8) { if (os[i]) in++; else { o++; } }
    if (!os[i]) c.maxOutside = std::max(c.maxOutside, m);
  }
  c.outside = double(o) / double(npx);
  c.inside = double(in) / double(npx);
  c.sens = double(s) / double(npx);
  const double mse = se / (3.0 * double(npx));
  c.psnr = mse == 0 ? 99.0 : 10.0 * std::log10(255.0 * 255.0 / mse);
  const double mseOut = seOut / (3.0 * double(npx - s));
  c.psnrOutside = mseOut == 0 ? 99.0 : 10.0 * std::log10(255.0 * 255.0 / mseOut);
  return c;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 3) { std::fprintf(stderr, "usage: %s <parity_fixture_v3 dir> <scratch dir>\n", argv[0]); return 2; }
  const std::string dir = argv[1];
  std::error_code ec;
  std::filesystem::create_directories(argv[2], ec);
  Report rep;

  Json index;
  if (!ReadJson(dir + "/index.json", &index)) { std::fprintf(stderr, "no %s/index.json\n", dir.c_str()); return 1; }
  std::string schema, contract;
  Str(index, "schema", &schema);
  Str(index, "contract", &contract);
  rep.check("fixture: schema v3 against the v3 header",
            schema == "pw_painter_parity_fixture_index/v3" &&
                contract.find("4e867aa338c40f1d4c2389626b8de790083ce5cf62441a7349aa1bc19a3b8509") != std::string::npos,
            schema + " / " + contract);
  std::vector<std::string> names;
  if (const Json* gs = Field(index, "groups"); gs && gs->is_array())
    for (const Json& e : *gs) { std::string n; if (Str(e, "name", &n)) names.push_back(n); }
  std::vector<Group> groups(names.size());
  for (size_t k = 0; k < names.size(); ++k) {
    std::string why;
    if (!LoadGroup(dir + "/" + names[k] + ".json", &groups[k], &why)) {
      std::fprintf(stderr, "group %s: %s\n", names[k].c_str(), why.c_str());
      return 1;
    }
  }
  Cloud colored, uncolored;
  if (!LoadCloud(dir + "/cloud_colored.json", &colored) || !LoadCloud(dir + "/cloud_uncolored.json", &uncolored)) {
    std::fprintf(stderr, "clouds\n");
    return 1;
  }
  std::printf("fixture: %zu groups, %zu points\n\n", groups.size(), colored.n);
  rep.check("fixture: every group listed in index.json, every point listed", groups.size() >= 26 && [&] {
    for (const Group& g : groups) if (g.pts.size() != colored.n) return false;
    return true;
  }(), Fmt("%zu groups", groups.size()));

  pwlod_gpu gpu{};
  if (pwlod_gpu_create(nullptr, 0, &gpu) != PWLOD_OK) { std::fprintf(stderr, "gpu\n"); return 1; }
  plr::GpuCtx gx;
  gx.instance = gpu.instance; gx.adapter = gpu.adapter; gx.device = gpu.device; gx.queue = gpu.queue;
  const double dprs[2] = {1.0, 3.0};
  const uint32_t W1 = (uint32_t)std::lround(groups[0].size[0]), H1 = (uint32_t)std::lround(groups[0].size[1]);
  plr::Pipe pipes[2];
  OwnedTarget tgts[2];
  std::string err;
  for (int k = 0; k < 2; ++k) {
    const uint32_t w = (uint32_t)std::lround(W1 * dprs[k]), h = (uint32_t)std::lround(H1 * dprs[k]);
    if (!plr::MakePipe(gx, &pipes[k], WGPUTextureFormat_RGBA8Unorm, w, h, 0, &err)) { std::fprintf(stderr, "pipe\n"); return 1; }
    tgts[k] = MakeTarget(gx, w, h);
  }
  const Cloud* clouds[2] = {&colored, &uncolored};
  auto cloudOf = [&](const Group& g) { return g.cloud == "cloud_uncolored.json" ? clouds[1] : clouds[0]; };

  // ---- T0: the sprite ----
  {
    int64_t used = 0, bad = 0, badAnalytic = 0;
    for (const Group& g : groups) {
      std::vector<uint8_t> png;
      int pw = 0, ph = 0;
      if (!pwlod_png::ReadRgba(dir + "/" + g.png3, &png, &pw, &ph)) { rep.check("T0 png", false, g.png3); continue; }
      const double d = 3.0;
      std::vector<uint16_t> cnt((size_t)pw * ph, 0);
      auto quad = [&](const DartPt& q, int* x0, int* x1, int* y0, int* y1) {
        const double S = q.scale * d, tx = q.tx * d, ty = q.ty * d;
        *x0 = std::max(0, (int)std::floor(tx) - 1); *x1 = std::min(pw - 1, (int)std::ceil(tx + 16 * S) + 1);
        *y0 = std::max(0, (int)std::floor(ty) - 1); *y1 = std::min(ph - 1, (int)std::ceil(ty + 16 * S) + 1);
      };
      for (const DartPt& q : g.pts) {
        if (!q.drawn) continue;
        int x0, x1, y0, y1;
        quad(q, &x0, &x1, &y0, &y1);
        for (int y = y0; y <= y1; ++y) for (int x = x0; x <= x1; ++x) cnt[(size_t)y * pw + x]++;
      }
      for (const DartPt& q : g.pts) {
        if (!q.drawn) continue;
        const double S = q.scale * d, tx = q.tx * d, ty = q.ty * d;
        const int c[3] = {(int)((q.argb >> 16) & 0xFF), (int)((q.argb >> 8) & 0xFF), (int)(q.argb & 0xFF)};
        int x0, x1, y0, y1;
        quad(q, &x0, &x1, &y0, &y1);
        for (int y = y0; y <= y1; ++y)
          for (int x = x0; x <= x1; ++x) {
            if (cnt[(size_t)y * pw + x] != 1) continue;
            const double u = (x + 0.5 - tx) / S, v = (y + 0.5 - ty) / S;
            if (!(u >= 0 && u < 16 && v >= 0 && v < 16)) continue;
            const double fu = u - std::floor(u), fv = v - std::floor(v);
            if (std::min({fu, 1 - fu, fv, 1 - fv}) < 0.02) continue;
            const int a = plr::kPainterSpriteAlpha[(int)v][(int)u];
            const int an = (int)std::lround(std::clamp(7.5 - std::hypot(u - 8, v - 8), 0.0, 1.0) * 255.0);
            bool okT = true, okA = true;
            for (int k = 0; k < 3; ++k) {
              const int got = png[((size_t)y * pw + x) * 4 + k];
              okT = okT && got == Div255(c[k] * a);
              okA = okA && got == Div255(c[k] * an);
            }
            used++;
            bad += okT ? 0 : 1;
            badAnalytic += okA ? 0 : 1;
          }
      }
    }
    rep.check("T0 engine sprite table == the painter's sprite (3x, single-covered pixels)",
              used > 100000 && bad == 0, Fmt("%lld pixels, %lld differ", (long long)used, (long long)bad));
    rep.check("T0 NEG analytic disc is not the painter's sprite", badAnalytic > used / 20,
              Fmt("%lld of %lld pixels differ", (long long)badAnalytic, (long long)used));
  }

  // ---- the per-point probe ----
  auto probe = [&](const Group& g, int di, const Frame& F, bool useMask) {
    PerPoint r;
    const Cloud& cl = *cloudOf(g);
    const double d = dprs[di];
    plr::CamState cs{};
    std::memcpy(cs.vp, F.vp, sizeof F.vp);
    std::memcpy(cs.cam.viewProj, F.vp, sizeof F.vp);
    cs.cam.position = {F.eye[0], F.eye[1], F.eye[2]};
    cs.cam.cloudProjection = true;
    cs.cam.focalPx = F.pd.f;
    cs.cam.orbitDistance = F.pd.camDist;
    cs.cam.orthoMix = F.pd.orthoMix;
    cs.cam.screenWidthPx = (int)F.W;
    cs.cam.screenHeightPx = (int)F.H;
    plr::DrawParams dp;
    dp.viewer = &F.vstyle;
    const bool masked = useMask && g.mask.size() == cl.n;
    plr::FlatSet fs;
    plr::UploadFlat(gx, pipes[di], cl.xyz.data(), cl.rgb.data(), masked ? g.mask.data() : nullptr, cl.n, g.colored,
                    &F.vstyle, &fs);
    std::vector<plr::ViewerProbePoint> gp;
    for (const plr::GpuNode& c : fs.chunks) {
      auto part = plr::ProbeViewerPoints(gx, &pipes[di], c, fs.origin, cs, dp);
      gp.insert(gp.end(), part.begin(), part.end());
    }
    plr::ReleaseFlat(&fs);
    const double m = g.margin * d;
    size_t k = 0;
    for (size_t i = 0; i < cl.n; ++i) {
      const bool uploaded = !(masked && g.mask[i] == 0);
      bool drawn = false;
      const plr::ViewerProbePoint* q = nullptr;
      if (uploaded && k < gp.size()) {
        q = &gp[k++];
        drawn = q->culled == 0 && q->w > 0 && q->z >= 0 && q->z <= 1 && q->x >= -m && q->x <= F.W + m &&
                q->y >= -m && q->y <= F.H + m;
      }
      const DartPt& t = g.pts[i];
      if (drawn != t.drawn) { r.drawnMismatch++; continue; }
      if (!drawn) continue;
      r.compared++;
      const double dx = std::fabs(q->x / d - t.vx), dy = std::fabs(q->y / d - t.vy);
      r.maxPos = std::max(r.maxPos, std::max(dx, dy));
      if (!(dx <= 0.02 && dy <= 0.02)) r.posBad++;
      const double rel = std::fabs(q->scale / d - t.scale) / t.scale;
      r.maxScaleRel = std::max(r.maxScaleRel, rel);
      if (!(rel <= 1e-5)) r.scaleBad++;
      const uint32_t argb = ((q->rgba >> 24) << 24) | ((q->rgba & 0xFFu) << 16) | (((q->rgba >> 8) & 0xFFu) << 8) |
                            ((q->rgba >> 16) & 0xFFu);
      if (argb != t.argb) r.colourBad++;
    }
    if (k != gp.size()) r.drawnMismatch += (int64_t)(gp.size() - k);
    return r;
  };
  auto render = [&](const Group& g, int di, const Frame& F, bool useMask) {
    const Cloud& cl = *cloudOf(g);
    pwlod_viewer* v = nullptr;
    pwlod_viewer_create(&gpu, &v);
    pwlod_params prm;
    pwlod_params_default(&prm);   // background 0,0,0,1: the painter's black clear
    pwlod_viewer_set_params(v, &prm);
    pwlod_viewer_set_style(v, &F.style);
    const bool masked = useMask && g.mask.size() == cl.n;
    pwlod_viewer_set_points(v, cl.xyz.data(), cl.rgb.data(), cl.n, g.colored ? 1 : 0, masked ? g.mask.data() : nullptr);
    pwlod_viewer_set_camera(v, &F.cam);
    const pwlod_target t{tgts[di].tex, nullptr};
    pwlod_frame_stats st{};
    pwlod_viewer_render_once(v, &t, WGPUTextureFormat_RGBA8Unorm, F.W, F.H, &st);
    Img im = Readback(gx, tgts[di].tex, F.W, F.H);
    pwlod_viewer_destroy(v);
    return im;
  };
  // The painter's frame rebuilt from the Dart numbers (+ the order-sensitive
  // set), and from painter_ref's own per-point transcription.
  auto dartRaster = [&](const Group& g, const Frame& F, double d, std::vector<uint8_t>* os) {
    const Cloud& cl = *cloudOf(g);
    std::vector<painter_ref::Pt> pts(cl.n);
    for (size_t i = 0; i < cl.n; ++i) {
      const DartPt& t = g.pts[i];
      painter_ref::Pt& p = pts[i];
      p.drawn = t.drawn;
      if (!t.drawn) continue;
      p.vx = t.vx * d; p.vy = t.vy * d; p.scale = t.scale * d; p.argb = t.argb;
      p.depth = -double(t.order);   // the painter's far -> near order
      p.zndc = Zndc(F.vp, &cl.xyz[i * 3]);
    }
    return painter_ref::Rasterize(pts, F.vstyle, (int)F.W, (int)F.H, os);
  };
  auto refRaster = [&](const Group& g, const Frame& F, double d) {
    const Cloud& cl = *cloudOf(g);
    std::vector<painter_ref::Pt> pts(cl.n);
    const bool masked = g.mask.size() == cl.n;
    for (size_t i = 0; i < cl.n; ++i) {
      pts[i] = painter_ref::PaintPoint(g.proj, g.dstyle, g.colored, &cl.xyz[i * 3], &cl.rgb[i * 3],
                                       !(masked && g.mask[i] == 0), g.cam.radius, g.size[0], g.size[1]);
      pts[i].vx *= d; pts[i].vy *= d; pts[i].scale *= d;
      pts[i].zndc = Zndc(F.vp, &cl.xyz[i * 3]);
    }
    return painter_ref::Rasterize(pts, F.vstyle, (int)F.W, (int)F.H, nullptr);
  };

  // ---- R0 / R: painter_ref vs the Dart numbers ----
  {
    double maxProj = 0;
    int64_t drawnBad = 0, colourBad = 0, compared = 0;
    double maxPos = 0, maxScale = 0;
    for (const Group& g : groups) {
      const painter_ref::Proj p = painter_ref::ProjectionFor(g.cam, g.size[0], g.size[1]);
      const double a[] = {p.cosY, p.sinY, p.cosP, p.sinP, p.f, p.camDist, p.ox, p.oy, p.cosR, p.sinR, p.orthoMix,
                          p.pivot[0], p.pivot[1], p.pivot[2]};
      const double b[] = {g.proj.cosY, g.proj.sinY, g.proj.cosP, g.proj.sinP, g.proj.f, g.proj.camDist, g.proj.ox,
                          g.proj.oy, g.proj.cosR, g.proj.sinR, g.proj.orthoMix, g.proj.pivot[0], g.proj.pivot[1],
                          g.proj.pivot[2]};
      for (size_t k = 0; k < sizeof a / sizeof a[0]; ++k) maxProj = std::max(maxProj, std::fabs(a[k] - b[k]));
      const Cloud& cl = *cloudOf(g);
      const bool masked = g.mask.size() == cl.n;
      for (size_t i = 0; i < cl.n; ++i) {
        const painter_ref::Pt q = painter_ref::PaintPoint(g.proj, g.dstyle, g.colored, &cl.xyz[i * 3], &cl.rgb[i * 3],
                                                          !(masked && g.mask[i] == 0), g.cam.radius, g.size[0],
                                                          g.size[1]);
        const DartPt& t = g.pts[i];
        if (q.drawn != t.drawn) { drawnBad++; continue; }
        if (!q.drawn) continue;
        compared++;
        maxPos = std::max({maxPos, std::fabs(q.vx - t.vx), std::fabs(q.vy - t.vy)});
        maxScale = std::max(maxScale, std::fabs(q.scale - t.scale) / t.scale);
        if (q.argb != t.argb) colourBad++;
      }
    }
    rep.check("R0 painter_ref ProjectionFor == the fixture's projection scalars", maxProj <= 1e-9,
              Fmt("max |diff| %.3g over %zu groups x 14 scalars", maxProj, groups.size()));
    // The fixture's per-point numbers are the painter's Float32List atlas
    // (vx = rst[2] + 8 * scale): float32. Bounds: a float32 half-ulp at < 1024 px
    // is 3.1e-5 px, plus 8 x scale's; scale's half-ulp is 6e-8 relative.
    rep.check("R1 painter_ref PaintPoint == Dart per point (drawn set, position, scale, argb)",
              drawnBad == 0 && colourBad == 0 && maxPos <= 1e-4 && maxScale <= 1e-7,
              Fmt("%lld drawn points, drawn-set %lld, argb %lld differ, max |dpos| %.2g px, max scale rel %.2g",
                  (long long)compared, (long long)drawnBad, (long long)colourBad, maxPos, maxScale));
  }

  // ---- P1 / P2 per group ----
  std::printf("\nper group (P1 per point; P2 image: %% px with a channel off by > 8 outside the order-sensitive set):\n");
  double worstOut[2] = {0, 0}, worstPsnr[2] = {99, 99}, worstRefOut[2] = {0, 0}, worstModelOut[2] = {0, 0};
  int worstMax[2] = {0, 0};
  double maxPosAll = 0, maxScaleAll = 0;
  for (const Group& g : groups) {
    for (int di = 0; di < 2; ++di) {
      const double d = dprs[di];
      const Frame F = MakeFrame(g, d, g.style, false);
      const PerPoint r = probe(g, di, F, true);
      maxPosAll = std::max(maxPosAll, r.maxPos);
      maxScaleAll = std::max(maxScaleAll, r.maxScaleRel);
      rep.check(Fmt("P1 %s %gx", g.name.c_str(), d).c_str(),
                r.compared > 0 && r.drawnMismatch == 0 && r.posBad == 0 && r.scaleBad == 0 && r.colourBad == 0,
                Fmt("%lld drawn, drawn-set %lld, pos %lld (max %.2g px), scale %lld (max rel %.2g), argb %lld",
                    (long long)r.compared, (long long)r.drawnMismatch, (long long)r.posBad, r.maxPos,
                    (long long)r.scaleBad, r.maxScaleRel, (long long)r.colourBad));
      std::vector<uint8_t> png;
      int pw = 0, ph = 0;
      if (!pwlod_png::ReadRgba(dir + "/" + (di == 0 ? g.png1 : g.png3), &png, &pw, &ph) || (uint32_t)pw != F.W ||
          (uint32_t)ph != F.H) {
        rep.check(Fmt("P2 %s %gx png", g.name.c_str(), d).c_str(), false, "unreadable / size");
        continue;
      }
      std::vector<uint8_t> os;
      const std::vector<uint8_t> model = dartRaster(g, F, d, &os);
      const Img gi = render(g, di, F, true);
      const size_t npx = (size_t)F.W * F.H;
      if (std::getenv("PWLOD_PARITY_DUMP")) {   // diagnostic: the engine frame, raw RGBA
        std::ofstream o(std::string(argv[2]) + "/" + g.name + (di == 0 ? "_1x" : "_3x") + ".rgba", std::ios::binary);
        o.write(reinterpret_cast<const char*>(gi.px.data()), (std::streamsize)gi.px.size());
      }
      const ImgCmp c = CompareRgb(gi.px, png, os, npx);
      const std::vector<uint8_t> none(npx, 0);
      const ImgCmp cm = CompareRgb(model, png, none, npx);                 // the painter model itself
      const ImgCmp cr = CompareRgb(refRaster(g, F, d), png, os, npx);      // painter_ref end to end
      worstOut[di] = std::max(worstOut[di], c.outside);
      worstPsnr[di] = std::min(worstPsnr[di], c.psnrOutside);
      worstMax[di] = std::max(worstMax[di], c.maxOutside);
      worstRefOut[di] = std::max(worstRefOut[di], cr.outside);
      worstModelOut[di] = std::max(worstModelOut[di], cm.outside);
      rep.check(Fmt("P2 %s %gx", g.name.c_str(), d).c_str(), c.outside <= kP2Outside && c.psnrOutside >= kP2Psnr,
                Fmt("engine %.4f %% px, PSNR %.1f dB outside the order-sensitive %.3f %% (%.4f %% differ there, "
                    "PSNR all %.1f) | painter model %.4f %% | painter_ref %.4f %%",
                    100.0 * c.outside, c.psnrOutside, 100.0 * c.sens, 100.0 * c.inside, c.psnr, 100.0 * cm.outside,
                    100.0 * cr.outside));
    }
  }
  std::printf("\n  summary: P1 max |dpos| %.2g logical px, max scale rel %.2g; P2 worst outside 1x %.4f %% / 3x "
              "%.4f %%, worst PSNR outside 1x %.1f / 3x %.1f dB, worst channel outside the set 1x %d / 3x %d; painter model "
              "vs PNG worst 1x %.4f %% / 3x %.4f %%; painter_ref vs PNG worst 1x %.4f %% / 3x %.4f %%\n",
              maxPosAll, maxScaleAll, 100 * worstOut[0], 100 * worstOut[1], worstPsnr[0], worstPsnr[1], worstMax[0],
              worstMax[1], 100 * worstModelOut[0], 100 * worstModelOut[1], 100 * worstRefOut[0],
              100 * worstRefOut[1]);

  // ---- negative controls ----
  std::printf("\nnegative controls (each must be rejected):\n");
  auto find = [&](const char* n) -> const Group& {
    for (const Group& g : groups) if (g.name == n) return g;
    return groups[0];
  };
  auto negImage = [&](const Group& g, int di, const Frame& F, bool useMask) {
    std::vector<uint8_t> png;
    int pw = 0, ph = 0;
    pwlod_png::ReadRgba(dir + "/" + (di == 0 ? g.png1 : g.png3), &png, &pw, &ph);
    std::vector<uint8_t> os;
    const Frame Fok = MakeFrame(g, dprs[di], g.style, false);
    dartRaster(g, Fok, dprs[di], &os);
    const Img gi = render(g, di, F, useMask);
    return CompareRgb(gi.px, png, os, (size_t)F.W * F.H);
  };
  {
    const Group& g = find("colored__persp_capture__plain");
    const Frame F = MakeFrame(g, 3.0, g.style, true);
    const PerPoint r = probe(g, 1, F, true);
    const ImgCmp c = negImage(g, 1, F, true);
    rep.check("N1 transposed view_proj", (r.posBad + r.drawnMismatch) > (int64_t)colored.n / 2 && c.outside > kP2Outside,
              Fmt("P1 %lld pos + %lld drawn-set of %zu; P2 %.2f %% px", (long long)r.posBad,
                  (long long)r.drawnMismatch, colored.n, 100.0 * c.outside));
  }
  {
    const Group& g = find("colored__ortho_default__plain");
    pwlod_style s = g.style;
    s.tone = PWLOD_TONE_ACES;
    const Frame F = MakeFrame(g, 3.0, s, false);
    const PerPoint r = probe(g, 1, F, true);
    const ImgCmp c = negImage(g, 1, F, true);
    rep.check("N2 wrong tone (ACES for PBR Neutral)", r.colourBad > r.compared / 2 && c.outside > kP2Outside,
              Fmt("P1 %lld of %lld argb; P2 %.2f %% px", (long long)r.colourBad, (long long)r.compared,
                  100.0 * c.outside));
  }
  {
    const Group& g = find("colored__ortho_default__tint");
    pwlod_style s = g.style;
    s.selection_mode = PWLOD_SEL_NONE;
    const Frame F = MakeFrame(g, 3.0, s, false);
    const PerPoint r = probe(g, 1, F, true);
    const ImgCmp c = negImage(g, 1, F, true);
    rep.check("N3 TINT_OUTSIDE dropped", r.colourBad > 0 && c.outside > kP2Outside,
              Fmt("P1 %lld argb; P2 %.2f %% px", (long long)r.colourBad, 100.0 * c.outside));
  }
  {
    const Group& g = find("colored__ortho_default__mask");
    const Frame F = MakeFrame(g, 3.0, g.style, false);
    const PerPoint r = probe(g, 1, F, false);
    const ImgCmp c = negImage(g, 1, F, false);
    rep.check("N4 visibility mask ignored", r.drawnMismatch > 0 && c.outside > kP2Outside,
              Fmt("P1 %lld drawn-set; P2 %.2f %% px", (long long)r.drawnMismatch, 100.0 * c.outside));
  }
  {
    // The engine before R18: the header's analytic disc. A radius one float ulp
    // above 7 keeps it (UsesPainterSprite needs exactly 16 / 7).
    double worst = 0, worstPs = 99;
    for (const char* n : {"colored__ortho_default__plain", "colored__persp_capture__plain"}) {
      const Group& g = find(n);
      pwlod_style s = g.style;
      s.disc_radius_px_at_scale1 = std::nextafter(7.0f, 8.0f);
      const Frame F = MakeFrame(g, 3.0, s, false);
      const ImgCmp c = negImage(g, 1, F, true);
      worst = std::max(worst, c.outside);
      worstPs = std::min(worstPs, c.psnr);
    }
    rep.check("N5 analytic disc (the engine before R18)", worst > kP2Outside,
              Fmt("worst %.3f %% px, PSNR %.1f dB", 100.0 * worst, worstPs));
  }

  for (int k = 0; k < 2; ++k) { plr::ReleasePipe(&pipes[k]); ReleaseTarget(&tgts[k]); }
  if (plr::GpuErrorCount() != 0) rep.check("no WebGPU errors", false, plr::GpuErrorLog());
  pwlod_gpu_destroy(&gpu);
  return rep.finish();
}
