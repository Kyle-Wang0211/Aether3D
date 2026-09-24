// Host test for node selection under the product viewer's CloudProjection
// (DEVIATIONS.md D19: screenPixelRadius = radius * focalPx / divisorAt(d),
// lib/ui/official_capture/cloud_camera.dart:126-128 @ 86a45cf).
//
//   P1  perspective endpoint (orthoMix = 0, focalPx = 0.5*H / tan(fov/2)) gives
//       the SAME selection as the Potree perspective path over the sweep's
//       perspective poses (selection_sweep.h): node SET, numPoints,
//       nodesConsidered, hitBudget, promoted / unloaded sets and lowestSpacing
//       bit for bit in EVERY call; node ORDER bit for bit too, except where two
//       nodes' Potree weights are a tie to within 4 ulp. Why the exception exists:
//       the v3 camera carries focal_px, not the fov, so the endpoint computes
//       radius * (f / d) where Potree computes radius * (0.5H / (tan(fov/2) d));
//       the two differ by <= 2 ulp (measured), which can swap two tied nodes in
//       the priority queue and nothing else. Each such swap is checked to be a
//       tie; a swap between non-tied weights fails the test.
//   P2  orthographic endpoint (orthoMix = 1, focalPx = orbitDistance / pixelSize)
//       gives the SAME selection as the D17 path, bit for bit, over the sweep's
//       orthographic poses.
//   M1  orthoMix = 0.5: every leaf is still reachable by zooming to it (S2 form)
//       and the selection differs from both endpoints somewhere (the divisor is
//       really interpolated).
//   N1  negative control: the perspective poses fed through the ORTHOGRAPHIC
//       endpoint, and the orthographic poses through the PERSPECTIVE endpoint,
//       must give different selections.
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <limits>
#include <string>
#include <vector>

#include "aether/pointcloud_lod/select.h"
#include "selection_sweep.h"

using namespace aether::pointcloud_lod;

static int g_fail = 0;
static void report(const char* name, bool ok, const std::string& detail) {
  std::printf("  %-4s %-66s %s\n", ok ? "PASS" : "FAIL", name, detail.c_str());
  if (!ok) g_fail++;
}

constexpr double kPi = 3.14159265358979323846;

// v2 camera -> the same view as a CloudProjection camera.
static Camera ToCloud(const Camera& c, double orbit, double mix, bool fromOrtho) {
  Camera v = c;
  v.cloudProjection = true;
  v.orbitDistance = orbit;
  v.orthoMix = mix;
  if (!fromOrtho) {
    v.focalPx = 0.5 * double(c.screenHeightPx) / std::tan(c.fovYDegrees * kPi / 180.0 / 2.0);
  } else {
    const double pixelSize = std::max(c.orthoHeight, c.orthoWidth) /
                             double(std::max(c.screenWidthPx, c.screenHeightPx));
    v.focalPx = orbit / pixelSize;
  }
  return v;
}

static bool SameExceptOrder(const Selection& a, const Selection& b) {
  auto sorted = [](std::vector<int32_t> v) { std::sort(v.begin(), v.end()); return v; };
  return sorted(a.nodes) == sorted(b.nodes) && a.numPoints == b.numPoints &&
         a.nodesConsidered == b.nodesConsidered && a.hitBudget == b.hitBudget &&
         sorted(a.promoted) == sorted(b.promoted) && sorted(a.unloaded) == sorted(b.unloaded) &&
         std::memcmp(&a.lowestSpacing, &b.lowestSpacing, sizeof(double)) == 0;
}

// Potree's weight of `node` for camera `c` (select.cpp perspective branch, :368-381).
static double PotreeWeight(const Octree& oct, const Camera& c, int32_t node) {
  const Node& n = oct.nodes[(size_t)node];
  const Vec3 cc = n.box.center();
  const double dx = c.position.x - cc.x, dy = c.position.y - cc.y, dz = c.position.z - cc.z;
  const double distance = std::sqrt(dx * dx + dy * dy + dz * dz);
  const double radius = n.box.boundingSphereRadius();
  if (distance - radius < 0) return std::numeric_limits<double>::max();
  const double slope = std::tan(c.fovYDegrees * kPi / 180.0 / 2.0);
  return radius * (0.5 * double(c.screenHeightPx) / (slope * distance));
}

static bool Same(const Selection& a, const Selection& b) {
  return a.nodes == b.nodes && a.numPoints == b.numPoints && a.nodesConsidered == b.nodesConsidered &&
         a.hitBudget == b.hitBudget && a.promoted == b.promoted && a.unloaded == b.unloaded &&
         std::memcmp(&a.lowestSpacing, &b.lowestSpacing, sizeof(double)) == 0;
}

int main(int argc, char** argv) {
  if (argc < 2) { std::fprintf(stderr, "usage: test_cloudproj <octree dir>\n"); return 2; }
  Octree oct = loadOctree(argv[1]);
  if (!oct.error.empty()) { std::fprintf(stderr, "load failed: %s\n", oct.error.c_str()); return 1; }
  std::printf("tree: %zu nodes, %lld points\n\n", oct.nodes.size(), (long long)oct.meta.points);
  const double R = oct.nodes[0].box.boundingSphereRadius();

  int64_t perspCalls = 0, perspDiff = 0, orthoCalls = 0, orthoDiff = 0;
  int64_t perspOrderOnly = 0, perspOrderNonTie = 0;
  std::string tieDetail;
  int64_t negPersp = 0, negOrtho = 0, midVsP = 0, midVsO = 0, midCalls = 0;
  for (int i = 0; i < 400; ++i) {
    const Camera c = pwlod_sweep::SweepCamera(oct, i);
    const bool ortho = c.orthographic;
    // orbit distance: the sweep camera's own eye -> origin-of-view distance; any
    // positive value is valid (it only enters the orthographic and mixed forms)
    const double orbit = std::max(1e-6, (c.position - oct.nodes[0].box.center()).length() + 0.25 * R);
    const Camera same = ToCloud(c, orbit, ortho ? 1.0 : 0.0, ortho);
    const Camera wrong = ToCloud(c, orbit, ortho ? 0.0 : 1.0, ortho);
    const Camera mid = ToCloud(c, orbit, 0.5, ortho);
    for (double px : {150.0, 30.0, 8.16, 1.0})
      for (long long b : {1000000LL, 3630000LL, 20000000LL}) {
        SelectParams p;
        p.pointBudget = b;
        p.minimumNodePixelSize = px;
        Residency r;
        r.state = &pwlod_sweep::SyntheticState;
        for (int streaming = 0; streaming < 2; ++streaming) {
          auto sel = [&](const Camera& cam) {
            return streaming ? selectVisible(oct, cam, p, r) : selectVisible(oct, cam, p);
          };
          const Selection s2 = sel(c), s3 = sel(same), sw = sel(wrong), sm = sel(mid);
          if (ortho) { orthoCalls++; if (!Same(s2, s3)) orthoDiff++; if (!Same(s2, sw)) negOrtho++; }
          else {
            perspCalls++;
            if (!SameExceptOrder(s2, s3)) perspDiff++;
            else if (!Same(s2, s3)) {
              perspOrderOnly++;
              // the list whose order differs: nodes, else promoted, else unloaded
              const std::vector<int32_t>* la = &s2.nodes;
              const std::vector<int32_t>* lb = &s3.nodes;
              if (*la == *lb) { la = &s2.promoted; lb = &s3.promoted; }
              if (*la == *lb) { la = &s2.unloaded; lb = &s3.unloaded; }
              size_t k = 0;
              while (k < la->size() && (*la)[k] == (*lb)[k]) ++k;
              if (k >= la->size()) { perspOrderNonTie++; continue; }   // cannot happen: Same() failed
              const double wa = PotreeWeight(oct, c, (*la)[k]), wb = PotreeWeight(oct, c, (*lb)[k]);
              const double rel = std::fabs(wa - wb) / std::max(wa, wb);
              if (!(rel <= 4.0 * std::numeric_limits<double>::epsilon())) perspOrderNonTie++;
              if (tieDetail.empty()) {
                char b2[200];
                std::snprintf(b2, sizeof b2, "; first at pose %d (%s list): %s <-> %s, weights %.17g / %.17g", i,
                              la == &s2.nodes ? "nodes" : la == &s2.promoted ? "promoted" : "unloaded",
                              oct.nodes[(size_t)(*la)[k]].name.c_str(), oct.nodes[(size_t)(*lb)[k]].name.c_str(), wa, wb);
                tieDetail = b2;
              }
            }
            if (!Same(s2, sw)) negPersp++;
          }
          midCalls++;
          if (!Same(sm, ortho ? sw : s3)) midVsP++;   // vs the perspective endpoint
          if (!Same(sm, ortho ? s3 : sw)) midVsO++;   // vs the orthographic endpoint
        }
      }
  }
  report("P1 perspective endpoint == Potree path (set/counts bit for bit)",
         perspCalls > 0 && perspDiff == 0,
         std::to_string(perspDiff) + " / " + std::to_string(perspCalls) + " selections differ");
  report("P1 order differences are 4-ulp weight ties only", perspOrderNonTie == 0,
         std::to_string(perspOrderOnly) + " order-only, " + std::to_string(perspOrderNonTie) + " not a tie" + tieDetail);
  report("P2 orthographic endpoint == D17 path (bit for bit)", orthoCalls > 0 && orthoDiff == 0,
         std::to_string(orthoDiff) + " / " + std::to_string(orthoCalls) + " selections differ");

  // M1 reachability at orthoMix = 0.5, S2 form (camera in front of each leaf)
  {
    int64_t leaves = 0, reached = 0;
    std::string missed;
    for (size_t i = 0; i < oct.nodes.size(); ++i) {
      const Node& n = oct.nodes[i];
      if (std::any_of(n.children.begin(), n.children.end(), [](int32_t x) { return x >= 0; }) ||
          n.numPoints == 0)
        continue;
      leaves++;
      const Vec3 nc = n.box.center();
      const double nr = n.box.boundingSphereRadius();
      Camera cam = pwlod_sweep::SweepCamera(oct, 0);   // for the matrix layout only
      // eye in front of the leaf, looking at it (test_select S2), 60 deg, 1170x2532
      const Vec3 e{nc.x, nc.y, nc.z + nr * 3.0};
      const double zn = nr * 0.01, zf = R * 20, fov = 60.0;
      const double t = 1.0 / std::tan(fov * kPi / 360.0), a = 1170.0 / 2532.0;
      const double P[16] = {t / a, 0, 0, 0, 0, t, 0, 0, 0, 0, zf / (zn - zf), zn * zf / (zn - zf), 0, 0, -1, 0};
      const double V[16] = {1, 0, 0, -e.x, 0, 1, 0, -e.y, 0, 0, 1, -e.z, 0, 0, 0, 1};
      for (int rr = 0; rr < 4; rr++)
        for (int cc = 0; cc < 4; cc++) {
          double acc = 0;
          for (int k = 0; k < 4; k++) acc += P[rr * 4 + k] * V[k * 4 + cc];
          cam.viewProj[rr * 4 + cc] = acc;
        }
      cam.position = e;
      cam.orthographic = false;
      cam.fovYDegrees = fov;
      cam.screenHeightPx = 2532;
      cam.screenWidthPx = 1170;
      const Camera m = ToCloud(cam, nr * 3.0, 0.5, false);
      SelectParams p;
      p.pointBudget = 3630000;
      const Selection s = selectVisible(oct, m, p);
      if (std::find(s.nodes.begin(), s.nodes.end(), (int32_t)i) != s.nodes.end()) reached++;
      else if (missed.size() < 60) missed += " " + n.name;
    }
    report("M1 orthoMix 0.5: every leaf reachable by zooming to it", leaves > 0 && reached == leaves,
           std::to_string(reached) + " / " + std::to_string(leaves) + (missed.empty() ? "" : ", missed:" + missed));
    report("M1 orthoMix 0.5 differs from both endpoints somewhere", midVsP > 0 && midVsO > 0,
           "vs perspective " + std::to_string(midVsP) + ", vs orthographic " + std::to_string(midVsO) +
               " of " + std::to_string(midCalls));
  }
  std::printf("\nnegative controls (each must be rejected):\n");
  report("N1 perspective poses through the orthographic endpoint differ", negPersp > 0,
         std::to_string(negPersp) + " / " + std::to_string(perspCalls));
  report("N1 orthographic poses through the perspective endpoint differ", negOrtho > 0,
         std::to_string(negOrtho) + " / " + std::to_string(orthoCalls));
  std::printf("\n==== %s ====\n", g_fail == 0 ? "ALL PASS" : "FAILED");
  return g_fail == 0 ? 0 : 1;
}
