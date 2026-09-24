// The product viewer's look (pwlod_style, ABI v3) -- the CPU half.
//
// Ported line by line from the product's painter, SparseCloudPainter in
// lib/ui/official_capture/sparse_cloud_view.dart @ 86a45cf (the 168 shipping
// source), which itself carries three.js r160's AgX / ACESFilmic tone mapping
// (src/renderers/shaders/ShaderChunk/tonemapping_pars_fragment.glsl.js, MIT) and
// Khronos PBR Neutral (KhronosGroup/ToneMapping PBR_Neutral/pbrNeutral.glsl,
// Apache-2.0). Double precision, as in Dart, so a point's display colour is the
// painter's to the bit; the GPU only draws it.
//
// The per-point work that must stay dynamic (projection, sprite scale, the
// selection box) runs in the WGSL of lod_render.cpp.
#pragma once

#include <cstdint>

namespace aether::pointcloud_lod_render {

struct ViewerStyle {
  double point_size = 3.0;              // SparseCloudView._pointSize (:382)
  double sprite_px = 16.0;              // the 16x16 sprite (:812-828)
  double disc_radius = 7.0;             // drawCircle(Offset(8, 8), 7) (:819-825)
  double max_sprite_scale = 50.0 / 16.0;  // kMaxPointSpriteScale (:235)
  int tone = 2;                         // _tone (:384): 0 AgX, 1 ACES, 2 PBR Neutral, 3+ None
  double exposure = 1.0;                // _exposure (:383)
  double uncolored_min_y = 0.0;         // _minY (:1523)
  double uncolored_inv_y_span = 1.0;    // _invYSpan (:1530)
  int selection_mode = 0;               // 0 none, 1 tint outside, 2 cull outside
  double selection_center[3] = {0, 0, 0};
  double selection_size[3] = {1, 1, 1};
  double selection_rot[9] = {1, 0, 0, 0, 1, 0, 0, 0, 1};  // row-major, local -> world
  uint32_t selection_out_argb = 0xFFE05252u;               // kSelectionOutColor (:27)
};

// sparse_cloud_view.dart:1056-1061 / :1063-1069
double SrgbDecode(int b);
int SrgbEncode(double c);
// :1073-1134 AgX, :1137-1156 ACESFilmic, :1164-1195 PBR Neutral; out: linear sRGB
void ToneAgx(double r, double g, double b, double exposure, double out[3]);
void ToneAces(double r, double g, double b, double exposure, double out[3]);
void TonePbrNeutral(double r, double g, double b, double exposure, double out[3]);

// One point of _displayColors (:1216-1249): 0xAARRGGBB. `colored` is the
// painter's hasColor (:1575-1581; the caller's rule); `y` is the point's world y
// (the height ramp of uncoloured clouds, :1224-1229).
uint32_t DisplayArgb(const ViewerStyle& s, bool colored, uint8_t r, uint8_t g, uint8_t b, double y);

// SelectionBox.contains, lib/official_capture/selection_box.dart:119-126.
bool SelectionContains(const ViewerStyle& s, double wx, double wy, double wz);

// True when two styles give different display colours for the same point (the
// painter's colour cache key, :1207-1213, plus the uncoloured ramp domain).
bool ColourKeyDiffers(const ViewerStyle& a, const ViewerStyle& b);

// R18: the painter's sprite as it is actually drawn. _buildSprite (:812-828)
// rasterizes drawCircle(Offset(8, 8), 7, isAntiAlias) into a 16x16 image, and
// drawRawAtlas (:1715-1723) samples it with Paint()'s default FilterQuality.none,
// i.e. NEAREST texel: a screen pixel whose centre lies at sprite coordinate (u, v)
// (texels, origin top-left) gets alpha kPainterSpriteAlpha[floor v][floor u] / 255.
// The values are the Flutter rasterizer's coverage of that circle, recovered bit
// for bit from the painter's own output (parity_fixture_v3, product
// feat/lod-on-dense-168 @ 44bf12f, test/point_cloud_lod/
// painter_parity_fixture_v3_test.dart): every single-covered pixel of its 3x PNGs
// equals round(colour * alpha / 255) with these alphas (judge T0 of
// tests/pointcloud_lod_render/test_parity.cpp re-checks it on every run).
// Rows top -> bottom (screen down), columns left -> right.
extern const uint8_t kPainterSpriteAlpha[16][16];

// True for the product sprite geometry (16 px sprite, radius 7): the only one the
// table above describes. Any other pwlod_style geometry keeps the analytic disc
// (radius + 0.5 - distance, clamped), the header's own description.
bool UsesPainterSprite(const ViewerStyle& s);

}  // namespace aether::pointcloud_lod_render
