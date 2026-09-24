// A CPU transcription of the product viewer's painter: the reference of
// test_viewer.cpp, itself judged against the Dart painter's own numbers and PNGs
// (parity_fixture_v3, produced by the product side) in test_parity.cpp.
//
// Source: lib/ui/official_capture/cloud_camera.dart (CloudCamera.projectionFor,
// CloudProjection) and lib/ui/official_capture/sparse_cloud_view.dart
// (SparseCloudPainter._ensureFit / paint) @ 86a45cf, double precision as in Dart.
// Also: the view_proj_row_major a shell must hand the engine for that
// projection (the header's pwlod_camera contract), and a far->near source-over
// rasterizer of the painter's sprites for whole-image comparisons.
#pragma once

#include <cstdint>
#include <vector>

#include "aether/pointcloud_lod_render/viewer_look.h"

namespace painter_ref {

namespace plr = aether::pointcloud_lod_render;

// CloudCamera (cloud_camera.dart:11-66)
struct CloudCam {
  double yaw = 0, pitch = 0, roll = 0, zoom = 1, panX = 0, panY = 0;
  double pivot[3] = {0, 0, 0};
  double radius = 1;             // fit radius (SparseCloudPainter.fitOf)
  double fillK = 6.5;            // kFitFillK (:316)
  double camDistOverride = -1;   // < 0 = null (radius * kCamDistK)
  double orthoMix = 0;           // explicit (the painter passes orthoMix or derives it)
};

// CloudProjection (cloud_camera.dart:68-128)
struct Proj {
  double cosY, sinY, cosP, sinP, f, camDist, ox, oy, pivot[3], cosR, sinR, orthoMix;
  double divisorAt(double depth) const {
    return orthoMix == 1.0 ? camDist : (orthoMix == 0.0 ? depth : depth + (camDist - depth) * orthoMix);
  }
};
Proj ProjectionFor(const CloudCam& c, double width, double height);

// SparseCloudPainter._ensureFit (sparse_cloud_view.dart:1459-1531)
struct Fit { double cx, cy, cz, radius, minY, invYSpan; };
Fit EnsureFit(const std::vector<float>& xyz);

// One point of paint() (:1601-1687): drawn?, screen position, sprite scale,
// depth, colour (after TINT). Culled by CULL / mask / behind the eye / off
// screen -> drawn = false with `why` set.
struct Pt {
  bool drawn = false;
  int why = 0;                   // 0 drawn, 1 mask, 2 selection cull, 3 behind eye, 4 off screen
  double vx = 0, vy = 0, scale = 0, depth = 0;
  uint32_t argb = 0;
  bool tinted = false;
  float zndc = 0;                // optional: the point's clip z / w as a float32 depth buffer holds it
};
Pt PaintPoint(const Proj& p, const plr::ViewerStyle& st, bool colored, const float* xyz, const uint8_t* rgb,
              bool visible, double fitRadius, double width, double height);

// The engine's pwlod_camera.view_proj_row_major for this projection: clip.w is
// divisorAt(depth) (affine in the point), clip.x/w and clip.y/w land on the
// painter's (vx, vy) incl. roll and the screen-X negation, z maps depth in
// [zn, zf] to [0, 1]. Eye = pivot - camDist * forward.
void ViewProj(const Proj& p, double width, double height, double zn, double zf, double vp[16],
              double eye[3]);

// Far->near source-over of every drawn point's sprite (the painter's
// drawRawAtlas + BlendMode.modulate + sort, :1692-1723) on a (0,0,0,0) canvas,
// in the canvas's 8 bits: the 16x16 sprite sampled nearest (R18,
// kPainterSpriteAlpha) for the product geometry, else the analytic disc.
// Returns RGBA8 (premultiplied, as the GPU target holds it).
// `orderSensitive` (optional) receives, per pixel, 1 where two or more partially
// covering sprite fragments (anti-aliased rims) lie in front of the nearest
// fully covering one: the only pixels whose result depends on the blending
// ORDER of those rims (the painter blends them far->near, a GPU in draw order);
// 2 where the two nearest fully covering fragments are a depth tie: their
// float32 depth-buffer values (Pt::zndc) within 4 ulp of each other, i.e. an
// order a float32 depth buffer fed by a float32 transform cannot resolve.
std::vector<uint8_t> Rasterize(const std::vector<Pt>& pts, const plr::ViewerStyle& st, int width, int height,
                               std::vector<uint8_t>* orderSensitive = nullptr);

}  // namespace painter_ref
