// See viewer_look.h. Every function is the Dart of SparseCloudPainter
// (lib/ui/official_capture/sparse_cloud_view.dart @ 86a45cf) written in C++,
// expression for expression; line numbers are that file's. Dart `double.round()`
// and C++ std::round both round half away from zero; Dart `math.pow` / `math.log`
// are the platform libm, as std::pow / std::log are here.
#include "aether/pointcloud_lod_render/viewer_look.h"

#include <algorithm>
#include <cmath>

namespace aether::pointcloud_lod_render {

namespace {
double Clamp(double v, double lo, double hi) { return v < lo ? lo : (v > hi ? hi : v); }
constexpr double kLn2 = 0.6931471805599453;   // Dart math.ln2
}  // namespace

// :1056-1061
double SrgbDecode(int b) {
  const double c = b / 255.0;
  return c <= 0.04045 ? c / 12.92 : std::pow((c + 0.055) / 1.055, 2.4);
}

// :1063-1069
int SrgbEncode(double c) {
  const double v = Clamp(c, 0.0, 1.0);
  const double e = v <= 0.0031308 ? v * 12.92 : 1.055 * std::pow(v, 1 / 2.4) - 0.055;
  return (int)std::round(Clamp(e, 0.0, 1.0) * 255);
}

// :1073-1134 -- three.js r160 AgXToneMapping as the painter transcribed it.
void ToneAgx(double r, double g, double b, double exposure, double out[3]) {
  r *= exposure;
  g *= exposure;
  b *= exposure;
  // LINEAR_SRGB_TO_LINEAR_REC2020
  double x = 0.6274 * r + 0.3293 * g + 0.0433 * b;
  double y = 0.0691 * r + 0.9195 * g + 0.0113 * b;
  double z = 0.0164 * r + 0.0880 * g + 0.8956 * b;
  // AgXInsetMatrix
  const double ix = 0.856627153315983 * x + 0.0951212405381588 * y + 0.0482516061458583 * z;
  const double iy = 0.137318972929847 * x + 0.761241990602591 * y + 0.101439036467562 * z;
  const double iz = 0.11189821299995 * x + 0.0767994186031903 * y + 0.811302368396859 * z;
  const double minEv = -12.47393, maxEv = 4.026069;
  auto enc = [&](double v) {
    v = std::max(v, 1e-10);
    v = (std::log(v) / kLn2 - minEv) / (maxEv - minEv);
    v = Clamp(v, 0.0, 1.0);
    const double v2 = v * v;
    const double v4 = v2 * v2;
    return 15.5 * v4 * v2 - 40.14 * v4 * v + 31.96 * v4 - 6.868 * v2 * v + 0.4298 * v2 + 0.1191 * v -
           0.00232;
  };
  x = enc(ix);
  y = enc(iy);
  z = enc(iz);
  // AgXOutsetMatrix
  double or_ = 1.1271005818144368 * x - 0.11060664309660323 * y - 0.016493938717834573 * z;
  double og = -0.1413297634984383 * x + 1.157823702216272 * y - 0.016493938717834257 * z;
  double ob = -0.14132976349843826 * x - 0.11060664309660294 * y + 1.2519364065950405 * z;
  or_ = std::pow(std::max(0.0, or_), 2.2);
  og = std::pow(std::max(0.0, og), 2.2);
  ob = std::pow(std::max(0.0, ob), 2.2);
  // LINEAR_REC2020_TO_LINEAR_SRGB
  out[0] = Clamp(1.6605 * or_ - 0.5876 * og - 0.0728 * ob, 0.0, 1.0);
  out[1] = Clamp(-0.1246 * or_ + 1.1329 * og - 0.0083 * ob, 0.0, 1.0);
  out[2] = Clamp(-0.0182 * or_ - 0.1006 * og + 1.1187 * ob, 0.0, 1.0);
}

// :1137-1156 -- three.js ACESFilmicToneMapping.
void ToneAces(double r, double g, double b, double exposure, double out[3]) {
  const double e = exposure / 0.6;
  r *= e;
  g *= e;
  b *= e;
  double x = 0.59719 * r + 0.35458 * g + 0.04823 * b;
  double y = 0.07600 * r + 0.90834 * g + 0.01566 * b;
  double z = 0.02840 * r + 0.13383 * g + 0.83777 * b;
  auto fit = [](double v) {
    return (v * (v + 0.0245786) - 0.000090537) / (v * (0.983729 * v + 0.4329510) + 0.238081);
  };
  x = fit(x);
  y = fit(y);
  z = fit(z);
  out[0] = Clamp(1.60475 * x - 0.53108 * y - 0.07367 * z, 0.0, 1.0);
  out[1] = Clamp(-0.10208 * x + 1.10813 * y - 0.00605 * z, 0.0, 1.0);
  out[2] = Clamp(-0.00327 * x - 0.07276 * y + 1.07602 * z, 0.0, 1.0);
}

// :1164-1195 -- Khronos PBR Neutral (pbrNeutral.glsl), exposure first.
void TonePbrNeutral(double r, double g, double b, double exposure, double out[3]) {
  const double startCompression = 0.8 - 0.04;   // 0.76
  const double desaturation = 0.15;
  r *= exposure;
  g *= exposure;
  b *= exposure;
  const double x = std::min(r, std::min(g, b));
  const double offset = x < 0.08 ? x - 6.25 * x * x : 0.04;
  r -= offset;
  g -= offset;
  b -= offset;
  const double peak = std::max(r, std::max(g, b));
  if (peak < startCompression) { out[0] = r; out[1] = g; out[2] = b; return; }
  const double d = 1.0 - startCompression;
  const double newPeak = 1.0 - d * d / (peak + d - startCompression);
  const double s = newPeak / peak;
  r *= s;
  g *= s;
  b *= s;
  const double gg = 1.0 - 1.0 / (desaturation * (peak - newPeak) + 1.0);
  out[0] = r + (newPeak - r) * gg;
  out[1] = g + (newPeak - g) * gg;
  out[2] = b + (newPeak - b) * gg;
}

// :1216-1249, one point.
uint32_t DisplayArgb(const ViewerStyle& s, bool colored, uint8_t r8, uint8_t g8, uint8_t b8, double y) {
  double lr, lg, lb;
  if (colored) {
    lr = SrgbDecode(r8);
    lg = SrgbDecode(g8);
    lb = SrgbDecode(b8);
  } else {
    // Height-ramp gray fallback (uncolored clouds). (:1223-1229)
    const double t = Clamp((y - s.uncolored_min_y) * s.uncolored_inv_y_span, 0.0, 1.0);
    const int q = (int)Clamp(std::round(120 + t * 135), 0, 255);
    const double lum = SrgbDecode(q);
    lr = lum;
    lg = lum;
    lb = lum;
  }
  double m[3];
  switch (s.tone) {
    case 0: ToneAgx(lr, lg, lb, s.exposure, m); break;
    case 1: ToneAces(lr, lg, lb, s.exposure, m); break;
    case 2: TonePbrNeutral(lr, lg, lb, s.exposure, m); break;
    default:
      m[0] = Clamp(lr * s.exposure, 0.0, 1.0);
      m[1] = Clamp(lg * s.exposure, 0.0, 1.0);
      m[2] = Clamp(lb * s.exposure, 0.0, 1.0);
  }
  return 0xFF000000u | ((uint32_t)SrgbEncode(m[0]) << 16) | ((uint32_t)SrgbEncode(m[1]) << 8) |
         (uint32_t)SrgbEncode(m[2]);
}

// selection_box.dart:119-126
bool SelectionContains(const ViewerStyle& s, double wx, double wy, double wz) {
  const double* rot = s.selection_rot;
  const double px = wx - s.selection_center[0], py = wy - s.selection_center[1],
               pz = wz - s.selection_center[2];
  const double lx = rot[0] * px + rot[3] * py + rot[6] * pz;
  const double ly = rot[1] * px + rot[4] * py + rot[7] * pz;
  const double lz = rot[2] * px + rot[5] * py + rot[8] * pz;
  return std::fabs(lx) <= s.selection_size[0] / 2 && std::fabs(ly) <= s.selection_size[1] / 2 &&
         std::fabs(lz) <= s.selection_size[2] / 2;
}

bool ColourKeyDiffers(const ViewerStyle& a, const ViewerStyle& b) {
  return a.tone != b.tone || a.exposure != b.exposure || a.uncolored_min_y != b.uncolored_min_y ||
         a.uncolored_inv_y_span != b.uncolored_inv_y_span;
}

}  // namespace aether::pointcloud_lod_render
