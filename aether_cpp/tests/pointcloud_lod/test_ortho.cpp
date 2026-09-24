// Host test for the orthographic selection branch (DEVIATIONS.md D17:
// CesiumJS Cesium3DTile.js:943-954 @ 113c068e9af3, pixelSize =
// max(frustum h, frustum w) / max(viewport w, h), no distance term).
//
//   O1  zoom in  (frustum height 3 x the leaf's bounding radius): EVERY leaf is
//       selected -- the orthographic form of test_select's S2
//   O2  zoom out (frustum height covering the whole cloud): every leaf whose
//       predicted size there is below minimumNodePixelSize is NOT selected
//   O3  budget still a hard ceiling in orthographic mode
//   N1  negative control: the zoom-in camera moved far back along its axis and
//       fed to the PERSPECTIVE formula (orthographic = false, same matrix) must
//       give a different selection -- the ortho branch is load-bearing
//   N2  negative control: the orthographic walk with its frustum 1000x too
//       large must lose the leaf -- O1 does not pass for every frustum
// Camera helpers: lookAt is test_select.cpp's; the orthographic matrix is
// three.js Matrix4.makeOrthographic, WebGPUCoordinateSystem branch
// (src/math/Matrix4.js:1200-1244 @ 6101189ee28b), row-major (D4).
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <limits>
#include <string>
#include <vector>

#include "aether/pointcloud_lod/select.h"

using namespace aether::pointcloud_lod;

static int g_fail = 0;
static int g_skip = 0;
static void report(const char* name, bool ok, const std::string& detail) {
  std::printf("  %-4s %-62s %s\n", ok ? "PASS" : "FAIL", name, detail.c_str());
  if (!ok) g_fail++;
}
static void skip(const char* name, const std::string& why) {
  std::printf("  %-4s %-62s %s\n", "SKIP", name, why.c_str());
  g_skip++;
}

static void mul(const double a[16], const double b[16], double o[16]) {
  for (int r = 0; r < 4; r++)
    for (int c = 0; c < 4; c++) {
      double s = 0;
      for (int k = 0; k < 4; k++) s += a[r * 4 + k] * b[k * 4 + c];
      o[r * 4 + c] = s;
    }
}
static Vec3 norm(Vec3 v) {
  const double l = v.length();
  return l > 0 ? Vec3{v.x / l, v.y / l, v.z / l} : v;
}
static Vec3 cross(Vec3 a, Vec3 b) {
  return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x};
}
static double dot(Vec3 a, Vec3 b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
static void lookAt(Vec3 eye, Vec3 target, Vec3 up, double m[16]) {
  const Vec3 f = norm(target - eye);
  const Vec3 s = norm(cross(f, up));
  const Vec3 u = cross(s, f);
  const double v[16] = {
      s.x,  s.y,  s.z,  -dot(s, eye),
      u.x,  u.y,  u.z,  -dot(u, eye),
     -f.x, -f.y, -f.z,   dot(f, eye),
      0,    0,    0,     1};
  std::copy(v, v + 16, m);
}
// Matrix4.js:1204-1208, :1226-1227 (WebGPU), :1237-1240 -- symmetric frustum.
static void orthographic(double width, double height, double zn, double zf, double m[16]) {
  const double x = 2.0 / width, y = 2.0 / height;
  const double c = -1.0 / (zf - zn), d = -zn / (zf - zn);
  const double p[16] = {
      x, 0, 0, 0,
      0, y, 0, 0,
      0, 0, c, d,
      0, 0, 0, 1};
  std::copy(p, p + 16, m);
}

constexpr int kW = 1170, kH = 2532;

static Camera orthoCamera(Vec3 eye, Vec3 target, double frustumH, double zn, double zf) {
  Camera cam;
  cam.position = eye;
  cam.screenHeightPx = kH;
  cam.screenWidthPx = kW;
  cam.orthographic = true;
  cam.orthoHeight = frustumH;
  cam.orthoWidth = frustumH * double(kW) / double(kH);
  double v[16], pr[16];
  lookAt(eye, target, {0, 1, 0}, v);
  orthographic(cam.orthoWidth, cam.orthoHeight, zn, zf, pr);
  mul(pr, v, cam.viewProj);
  return cam;
}

static bool has(const Selection& s, int32_t n) {
  return std::find(s.nodes.begin(), s.nodes.end(), n) != s.nodes.end();
}

int main(int argc, char** argv) {
  if (argc < 2) { std::fprintf(stderr, "usage: test_ortho <octree dir>\n"); return 2; }
  Octree oct = loadOctree(argv[1]);
  if (!oct.error.empty()) { std::fprintf(stderr, "load failed: %s\n", oct.error.c_str()); return 1; }
  const double R = oct.nodes[0].box.boundingSphereRadius();
  const Vec3 c = oct.nodes[0].box.center();
  std::vector<int32_t> leaves;
  for (size_t i = 0; i < oct.nodes.size(); i++) {
    const Node& n = oct.nodes[i];
    const bool hasChild = std::any_of(n.children.begin(), n.children.end(),
                                      [](int32_t x) { return x >= 0; });
    if (!hasChild && n.numPoints > 0) leaves.push_back((int32_t)i);
  }
  std::printf("tree: %zu nodes, %zu leaves, bounding radius %.3f\n\n", oct.nodes.size(),
              leaves.size(), R);
  SelectParams p;
  p.pointBudget = 3630000;   // test_select's S2 budget; minimumNodePixelSize = Potree's 150

  // O1 + O2 + N1 + N2, per leaf
  int64_t inSel = 0, outJudged = 0, outRejected = 0, n1Differs = 0, n2Lost = 0;
  std::string missIn, missOut;
  for (int32_t li : leaves) {
    const Node& n = oct.nodes[(size_t)li];
    const Vec3 nc = n.box.center();
    const double nr = n.box.boundingSphereRadius();
    const Vec3 eye{nc.x, nc.y, nc.z + nr * 3.0};
    // O1: zoomed in
    const Camera in = orthoCamera(eye, nc, 3.0 * nr, nr * 0.01, R * 20);
    const Selection sIn = selectVisible(oct, in, p);
    if (has(sIn, li)) inSel++;
    else if (missIn.size() < 80) missIn += " " + n.name;
    // O2: zoomed out to the whole cloud (frustum height 2R), same axis
    const Vec3 eyeOut{nc.x, nc.y, c.z + R * 3.0};
    const double outH = 2.0 * R;
    const double predicted = nr / (outH / double(kH));   // Cesium3DTile.js:951-954, h > w here
    if (predicted < p.minimumNodePixelSize) {
      outJudged++;
      const Camera out = orthoCamera(eyeOut, {nc.x, nc.y, c.z}, outH, R * 0.01, R * 20);
      if (!has(selectVisible(oct, out, p), li)) outRejected++;
      else if (missOut.size() < 80) missOut += " " + n.name;
    }
    // N1: the zoom-in frustum, eye moved 50R back, perspective formula misused
    const Vec3 eyeFar{nc.x, nc.y, nc.z + R * 50.0};
    Camera far = orthoCamera(eyeFar, nc, 3.0 * nr, R * 0.01, R * 100);
    const Selection sFarOrtho = selectVisible(oct, far, p);
    far.orthographic = false;   // same matrix, Potree's perspective size with fov 60
    const Selection sFarPersp = selectVisible(oct, far, p);
    if (sFarOrtho.nodes != sFarPersp.nodes) n1Differs++;
    // N2: frustum 1000x too large
    const Camera huge = orthoCamera(eye, nc, 3000.0 * nr, nr * 0.01, R * 20);
    if (!has(selectVisible(oct, huge, p), li)) n2Lost++;
  }
  const int64_t L = (int64_t)leaves.size();
  report("O1 zoomed in (frustum 3x leaf radius): every leaf selected", inSel == L,
         std::to_string(inSel) + " / " + std::to_string(L) + (missIn.empty() ? "" : ", missed:" + missIn));
  if (outJudged == 0) {
    skip("O2 zoomed out (frustum = whole cloud): small leaves not selected",
         "no leaf is smaller than 150 px at that zoom on this tree");
  } else {
    report("O2 zoomed out (frustum = whole cloud): small leaves not selected", outRejected == outJudged,
           std::to_string(outRejected) + " / " + std::to_string(outJudged) + " judged leaves rejected" +
               (missOut.empty() ? "" : ", still selected:" + missOut));
  }
  {
    bool ok = true;
    std::string worst;
    for (int64_t budget : {50000LL, 250000LL, 1000000LL, 3630000LL}) {
      SelectParams q; q.pointBudget = budget; q.minimumNodePixelSize = 1.0;
      const Camera cam = orthoCamera({c.x, c.y, c.z + R * 2.5}, c, 2.0 * R, 0.01, R * 20);
      const Selection s = selectVisible(oct, cam, q);
      if (s.numPoints > budget) { ok = false; worst = std::to_string(budget); break; }
    }
    report("O3 orthographic: selection never exceeds the point budget", ok,
           ok ? "4 budgets from 50k to 3.63M respected at 1 px" : "violated at " + worst);
  }
  std::printf("\nnegative controls (each must be rejected):\n");
  report("N1 same frustum through the perspective formula differs",
         n1Differs > 0,
         std::to_string(n1Differs) + " / " + std::to_string(L) + " leaves' selections differ");
  // Only the root is pushed unconditionally (select.cpp :79), so a root that is
  // itself a leaf is the one leaf N2 cannot lose.
  const int64_t losable = L - ((leaves.size() == 1 && leaves[0] == 0) ? 1 : 0);
  report("N2 frustum 1000x too large loses every (non-root) leaf", losable > 0 && n2Lost == losable,
         std::to_string(n2Lost) + " / " + std::to_string(losable) + " leaves lost");
  if (g_skip) std::printf("\n  %d check(s) skipped -- premise false on this tree.\n", g_skip);
  std::printf("\n==== %s ====\n",
              g_fail == 0 ? (g_skip ? "PASS (with skips)" : "ALL PASS") : "FAILED");
  return g_fail == 0 ? 0 : 1;
}
