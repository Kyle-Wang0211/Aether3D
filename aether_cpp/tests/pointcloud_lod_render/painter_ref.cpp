// See painter_ref.h. Line numbers are sparse_cloud_view.dart / cloud_camera.dart
// @ 86a45cf.
#include "painter_ref.h"

#include <algorithm>
#include <cmath>
#include <numeric>

namespace painter_ref {

constexpr double kCamDistK = 8.0;   // cloud_camera.dart:315

Proj ProjectionFor(const CloudCam& c, double width, double height) {
  const double half = std::min(width, height) * 0.5;   // :69 size.shortestSide * 0.5
  Proj p;
  p.cosY = std::cos(c.yaw);
  p.sinY = std::sin(c.yaw);
  p.cosP = std::cos(c.pitch);
  p.sinP = std::sin(c.pitch);
  p.f = half * c.fillK * c.zoom;
  p.camDist = c.camDistOverride >= 0 ? c.camDistOverride : c.radius * kCamDistK;
  p.ox = width * 0.5 + c.panX;
  p.oy = height * 0.5 + c.panY;
  for (int k = 0; k < 3; ++k) p.pivot[k] = c.pivot[k];
  p.cosR = std::cos(c.roll);
  p.sinR = std::sin(c.roll);
  p.orthoMix = c.orthoMix;
  return p;
}

Fit EnsureFit(const std::vector<float>& xyz) {
  const size_t n = xyz.size() / 3;
  std::vector<double> xs(n), ys(n), zs(n);
  for (size_t i = 0; i < n; ++i) { xs[i] = xyz[i * 3]; ys[i] = xyz[i * 3 + 1]; zs[i] = xyz[i * 3 + 2]; }
  auto med = [](std::vector<double> a) { std::sort(a.begin(), a.end()); return a[a.size() >> 1]; };
  auto mad = [](const std::vector<double>& a, double m) {
    std::vector<double> b;
    for (double v : a) b.push_back(std::fabs(v - m));
    std::sort(b.begin(), b.end());
    const double r = b[b.size() >> 1];
    return r == 0 ? 1.0 : r;
  };
  const double mx = med(xs), myv = med(ys), mz = med(zs);
  const double kx = 8 * mad(xs, mx), ky = 8 * mad(ys, myv), kz = 8 * mad(zs, mz);
  double sx = 0, sy = 0, sz = 0;
  size_t cnt = 0;
  for (size_t i = 0; i < n; ++i) {
    if (std::fabs(xs[i] - mx) > kx || std::fabs(ys[i] - myv) > ky || std::fabs(zs[i] - mz) > kz) continue;
    sx += xs[i]; sy += ys[i]; sz += zs[i]; cnt++;
  }
  Fit f;
  f.cx = cnt > 0 ? sx / cnt : mx;
  f.cy = cnt > 0 ? sy / cnt : myv;
  f.cz = cnt > 0 ? sz / cnt : mz;
  std::vector<double> dd;
  for (size_t i = 0; i < n; ++i) {
    const double dx = xs[i] - f.cx, dy = ys[i] - f.cy, dz = zs[i] - f.cz;
    dd.push_back(std::sqrt(dx * dx + dy * dy + dz * dz));
  }
  std::sort(dd.begin(), dd.end());
  f.radius = dd.empty() ? 1 : std::max(1e-6, dd[std::min(dd.size() - 1, (size_t)std::floor(dd.size() * 0.995))]);
  std::vector<double> ysSorted = ys;
  std::sort(ysSorted.begin(), ysSorted.end());
  f.minY = ysSorted[(size_t)std::floor(ysSorted.size() * 0.05)];
  const double ySpan = ysSorted[std::min(ysSorted.size() - 1, (size_t)std::floor(ysSorted.size() * 0.95))] - f.minY;
  f.invYSpan = std::fabs(ySpan) < 1e-9 ? 1 : 1 / ySpan;
  return f;
}

Pt PaintPoint(const Proj& p, const plr::ViewerStyle& st, bool colored, const float* xyz, const uint8_t* rgb,
              bool visible, double fitRadius, double width, double height) {
  Pt o;
  if (!visible) { o.why = 1; return o; }                                  // :1602
  const double wx = xyz[0], wy = xyz[1], wz = xyz[2];
  const bool outside = st.selection_mode != 0 && !plr::SelectionContains(st, wx, wy, wz);   // :1608-1609
  if (outside && st.selection_mode == 2) { o.why = 2; return o; }        // :1610
  const double px = wx - p.pivot[0], py = wy - p.pivot[1], pz = wz - p.pivot[2];
  const double x1 = px * p.cosY + pz * p.sinY;                            // :1613-1616
  const double z1 = -px * p.sinY + pz * p.cosY;
  const double y2 = py * p.cosP - z1 * p.sinP;
  const double z2 = py * p.sinP + z1 * p.cosP;
  const double depth = z2 + p.camDist;                                    // :1617
  if (depth <= fitRadius * 0.02) { o.why = 3; return o; }                 // :1618
  const double mix = p.orthoMix;
  const double dd = mix == 1.0 ? p.camDist : (mix == 0.0 ? depth : depth + (p.camDist - depth) * mix);   // :1625-1627
  double vx = p.ox - x1 * p.f / dd;                                       // :1628-1629
  double vy = p.oy - y2 * p.f / dd;
  if (!(p.sinR == 0.0 && p.cosR == 1.0)) {                                // :1630-1634
    const double rx = vx - p.ox, ry = vy - p.oy;
    vx = p.ox + rx * p.cosR - ry * p.sinR;
    vy = p.oy + rx * p.sinR + ry * p.cosR;
  }
  if (vx < -24 || vx > width + 24 || vy < -24 || vy > height + 24) { o.why = 4; return o; }   // :1635-1640
  const double baseScale = st.point_size / 16.0;                          // :1598 (sprite 16 px)
  if (mix == 1.0) {
    o.scale = baseScale;                                                  // :1669-1670
  } else {
    const double sc = baseScale * (p.camDist / dd);                       // :1675
    o.scale = sc > st.max_sprite_scale ? st.max_sprite_scale : sc;        // :1676
  }
  o.vx = vx;
  o.vy = vy;
  o.depth = depth;
  o.argb = plr::DisplayArgb(st, colored, rgb ? rgb[0] : 0, rgb ? rgb[1] : 0, rgb ? rgb[2] : 0, wy);   // :1679
  if (outside) { o.argb = st.selection_out_argb; o.tinted = true; }      // :1680-1682
  o.drawn = true;
  return o;
}

void ViewProj(const Proj& p, double W, double H, double zn, double zf, double vp[16], double eye[3]) {
  // view rows (cloud_camera.dart:198-201): x1, y2, z2
  const double a[3] = {p.cosY, 0.0, p.sinY};
  const double b[3] = {p.sinY * p.sinP, p.cosP, -p.cosY * p.sinP};
  const double c[3] = {-p.sinY * p.cosP, p.sinP, p.cosY * p.cosP};
  auto affine = [&](const double r[3], double out[4]) {
    out[0] = r[0]; out[1] = r[1]; out[2] = r[2];
    out[3] = -(r[0] * p.pivot[0] + r[1] * p.pivot[1] + r[2] * p.pivot[2]);
  };
  double X1[4], Y2[4], Z2[4];
  affine(a, X1); affine(b, Y2); affine(c, Z2);
  double DEPTH[4] = {Z2[0], Z2[1], Z2[2], Z2[3] + p.camDist};
  const double m = p.orthoMix;
  double D[4];
  for (int k = 0; k < 4; ++k) D[k] = (1 - m) * DEPTH[k];
  D[3] += m * p.camDist;
  if (m == 1.0) { D[0] = D[1] = D[2] = 0; D[3] = p.camDist; }   // exact endpoint
  double SXD[4], SYD[4];
  for (int k = 0; k < 4; ++k) {
    SXD[k] = p.ox * D[k] + (-p.f * p.cosR) * X1[k] + (p.f * p.sinR) * Y2[k];
    SYD[k] = p.oy * D[k] + (-p.f * p.sinR) * X1[k] + (-p.f * p.cosR) * Y2[k];
  }
  const double dfar = m == 1.0 ? p.camDist : (1 - m) * zf + m * p.camDist;
  const double A = dfar / (zf - zn), B = -A * zn;
  for (int k = 0; k < 4; ++k) {
    vp[0 * 4 + k] = (2.0 / W) * SXD[k] - D[k];
    vp[1 * 4 + k] = D[k] - (2.0 / H) * SYD[k];
    vp[2 * 4 + k] = A * DEPTH[k];
    vp[3 * 4 + k] = D[k];
  }
  vp[2 * 4 + 3] += B;
  for (int k = 0; k < 3; ++k) eye[k] = p.pivot[k] - p.camDist * c[k];
}

namespace {
// The painter's sprite alpha (0..255) at a pixel centre, or -1 outside the
// sprite quad. R18: the 16x16 image sampled NEAREST (viewer_look.h); any other
// geometry: the analytic disc, quantized to the 8 bits an image holds.
int SpriteAlpha8(const Pt& q, const plr::ViewerStyle& st, bool table, int x, int y) {
  const double half = st.sprite_px / 2, s = q.scale;
  const double u = (x + 0.5 - (q.vx - half * s)) / s, v = (y + 0.5 - (q.vy - half * s)) / s;
  if (!(u >= 0 && u < st.sprite_px && v >= 0 && v < st.sprite_px)) return -1;
  if (table) return plr::kPainterSpriteAlpha[(int)std::floor(v)][(int)std::floor(u)];
  const double cov = std::clamp(st.disc_radius + 0.5 - std::hypot(u - half, v - half), 0.0, 1.0);
  return (int)std::lround(cov * 255.0);
}
inline int Div255(int x) { return (x + 127) / 255; }
}  // namespace

std::vector<uint8_t> Rasterize(const std::vector<Pt>& pts, const plr::ViewerStyle& st, int W, int H,
                               std::vector<uint8_t>* orderSensitive) {
  // The painter's canvas: 8-bit premultiplied RGBA, BlendMode.modulate of the
  // white sprite by the colour (src = colour * a / 255) then source-over,
  // dst = src + dst * (255 - a) / 255 (round to nearest). Checked against the
  // Dart painter's PNGs (parity_fixture_v3): <= 1 LSB on >= 99.94 % of pixels.
  const bool table = plr::UsesPainterSprite(st);
  std::vector<int> acc((size_t)W * H * 4, 0);
  std::vector<size_t> order;
  for (size_t i = 0; i < pts.size(); ++i) if (pts[i].drawn) order.push_back(i);
  std::stable_sort(order.begin(), order.end(), [&](size_t x, size_t y) { return pts[x].depth > pts[y].depth; });  // :1693-1694
  auto box = [&](const Pt& q, int* x0, int* x1, int* y0, int* y1) {
    const double half = st.sprite_px / 2 * q.scale;
    *x0 = std::max(0, (int)std::floor(q.vx - half) - 1); *x1 = std::min(W - 1, (int)std::ceil(q.vx + half) + 1);
    *y0 = std::max(0, (int)std::floor(q.vy - half) - 1); *y1 = std::min(H - 1, (int)std::ceil(q.vy + half) + 1);
  };
  for (size_t i : order) {
    const Pt& q = pts[i];
    const int c[4] = {(int)((q.argb >> 16) & 0xFF), (int)((q.argb >> 8) & 0xFF), (int)(q.argb & 0xFF),
                      (int)((q.argb >> 24) & 0xFF)};
    int x0, x1, y0, y1;
    box(q, &x0, &x1, &y0, &y1);
    for (int y = y0; y <= y1; ++y)
      for (int x = x0; x <= x1; ++x) {
        const int a = SpriteAlpha8(q, st, table, x, y);
        if (a <= 0) continue;
        int* d = &acc[((size_t)y * W + x) * 4];
        const int sa = Div255(c[3] * a);
        for (int k = 0; k < 4; ++k) d[k] = Div255(c[k] * a) + Div255(d[k] * (255 - sa));
      }
  }
  if (orderSensitive) {
    // pass 1: nearest fully covering fragment per pixel; pass 2: count the
    // partial fragments in front of it.
    std::vector<double> zfull((size_t)W * H, 1e300), zfull2((size_t)W * H, 1e300);
    std::vector<float> zn1((size_t)W * H, 0.0f), zn2((size_t)W * H, 0.0f);
    std::vector<uint16_t> partial((size_t)W * H, 0);
    for (int passNo = 0; passNo < 2; ++passNo)
      for (size_t i : order) {
        const Pt& q = pts[i];
        int x0, x1, y0, y1;
        box(q, &x0, &x1, &y0, &y1);
        for (int y = y0; y <= y1; ++y)
          for (int x = x0; x <= x1; ++x) {
            const int a = SpriteAlpha8(q, st, table, x, y);
            if (a <= 0) continue;
            const size_t px = (size_t)y * W + x;
            if (passNo == 0) {
              if (a >= 255) {
                if (q.depth < zfull[px]) {
                  zfull2[px] = zfull[px]; zn2[px] = zn1[px];
                  zfull[px] = q.depth; zn1[px] = q.zndc;
                } else if (q.depth < zfull2[px]) {
                  zfull2[px] = q.depth; zn2[px] = q.zndc;
                }
              }
            }
            else if (a < 255 && q.depth < zfull[px] && partial[px] < 60000) partial[px]++;
          }
      }
    orderSensitive->assign((size_t)W * H, 0);
    for (size_t px = 0; px < partial.size(); ++px) {
      (*orderSensitive)[px] = partial[px] >= 2 ? 1 : 0;
      // two fully covering fragments a float32 depth buffer cannot order
      if (zfull2[px] < 1e299) {
        const float a = zn1[px], b = zn2[px];
        const float ulp = std::nextafter(std::fabs(a), 2.0f) - std::fabs(a);
        if (std::fabs(b - a) <= 4.0f * ulp) (*orderSensitive)[px] = 2;
      }
    }
  }
  std::vector<uint8_t> out((size_t)W * H * 4);
  for (size_t i = 0; i < out.size(); ++i) out[i] = (uint8_t)std::clamp(acc[i], 0, 255);
  return out;
}

}  // namespace painter_ref
