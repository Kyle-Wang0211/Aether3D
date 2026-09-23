// A/B: which knob should the frame-time controller drive?
//
//   Arm A (what is implemented now, deviation D11)
//       minimumNodePixelSize is fixed at Potree's 150; the controller moves the
//       POINT BUDGET.
//   Arm B (CesiumJS's own shape)
//       the controller moves the QUALITY THRESHOLD -- here
//       minimumNodePixelSize, Potree's analogue of Cesium's screenSpaceError --
//       and the point budget is only a hard ceiling.
//
// Both arms are given the SAME frame-time target and the SAME cost model, so
// the only thing that differs is which knob the loop turns. The question the
// measurement answers: at an identical 33.3 ms budget, how many points does
// each arm actually put on screen, and how deep does it get?
//
// Cost model is our own A16 measurement: frameMs = 0.20 + 9.12 * N_million.
// It is a measurement of OUR renderer, not a published figure; the comparison
// between arms does not depend on its absolute accuracy, only on it being the
// same for both arms.
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

#include "aether/pointcloud_lod/select.h"

using namespace aether::pointcloud_lod;

static void mul(const double a[16], const double b[16], double o[16]) {
  for (int r = 0; r < 4; r++) for (int c = 0; c < 4; c++) {
    double s = 0; for (int k = 0; k < 4; k++) s += a[r*4+k]*b[k*4+c]; o[r*4+c] = s; }
}
static Vec3 nrm(Vec3 v){ double l=v.length(); return l>0?Vec3{v.x/l,v.y/l,v.z/l}:v; }
static Vec3 crs(Vec3 a,Vec3 b){ return {a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x}; }
static double dt(Vec3 a,Vec3 b){ return a.x*b.x+a.y*b.y+a.z*b.z; }
static Camera makeCamera(Vec3 eye, Vec3 tgt, double fov, int w, int h, double zn, double zf) {
  Camera cam; cam.position = eye; cam.fovYDegrees = fov; cam.screenHeightPx = h;
  const Vec3 f = nrm(tgt - eye), s = nrm(crs(f, {0,1,0})), u = crs(s, f);
  const double v[16] = { s.x,s.y,s.z,-dt(s,eye), u.x,u.y,u.z,-dt(u,eye),
                        -f.x,-f.y,-f.z,dt(f,eye), 0,0,0,1 };
  const double t = 1.0/std::tan(fov*M_PI/180.0/2.0);
  const double p[16] = { t/(double(w)/double(h)),0,0,0, 0,t,0,0,
                         0,0,zf/(zn-zf),zn*zf/(zn-zf), 0,0,-1,0 };
  mul(p, v, cam.viewProj);
  return cam;
}

// our A16 measurement
static double costMs(int64_t pts, double slowdown) {
  return 0.20 + 9.12 * slowdown * (double(pts) / 1e6);
}

struct Result { int64_t pts; int maxLevel; double ms; double knob; };

// Arm A: fixed 150 px, controller moves the budget.
// This reproduces the retired BudgetController inline, on purpose: arm A is no
// longer shipped, but this file is the evidence for that decision and has to
// stay runnable.
static Result armA(const Octree& oct, const Camera& cam, double targetMs, double slowdown) {
  int64_t budget = 3630000;
  const double kStep = 1.02;
  const int64_t kMin = 50 * 1000, kMax = 8 * 1000 * 1000;
  Selection s;
  for (int i = 0; i < 400; i++) {
    SelectParams p; p.pointBudget = budget;         // 150 px stays at Potree's default
    s = selectVisible(oct, cam, p);
    const double ms = costMs(s.numPoints, slowdown);
    if (ms > targetMs) budget = std::max(int64_t(double(budget) / kStep), kMin);
    else if (ms < targetMs * 0.85) budget = std::min(int64_t(double(budget) * kStep), kMax);
  }
  int lv = 0; for (int32_t n : s.nodes) lv = std::max(lv, oct.nodes[(size_t)n].level);
  return {s.numPoints, lv, costMs(s.numPoints, slowdown), double(budget)};
}

// Arm B: budget is a hard ceiling, controller moves minimumNodePixelSize using
// the SAME multiplicative *1.02 / /1.02 step (Cesium3DTileset.js:3023, 3032).
static Result armB(const Octree& oct, const Camera& cam, double targetMs, double slowdown) {
  double px = 150.0;                       // start where Potree starts
  const double kStep = 1.02;
  const double kMinPx = 1.0, kMaxPx = 4000.0;
  Selection s;
  for (int i = 0; i < 400; i++) {
    SelectParams p;
    p.pointBudget = 3630000;               // hard ceiling, not the knob
    p.minimumNodePixelSize = px;
    s = selectVisible(oct, cam, p);
    const double ms = costMs(s.numPoints, slowdown);
    if (ms > targetMs) px = std::min(px * kStep, kMaxPx);          // coarser
    else if (ms < targetMs * 0.85) px = std::max(px / kStep, kMinPx);  // finer
  }
  int lv = 0; for (int32_t n : s.nodes) lv = std::max(lv, oct.nodes[(size_t)n].level);
  return {s.numPoints, lv, costMs(s.numPoints, slowdown), px};
}

int main(int argc, char** argv) {
  if (argc < 2) { std::fprintf(stderr, "usage: test_ab_knob <octree dir> [slowdown]\n"); return 2; }
  Octree oct = loadOctree(argv[1]);
  if (!oct.error.empty()) { std::fprintf(stderr, "load failed: %s\n", oct.error.c_str()); return 1; }
  const double slowdown = argc > 2 ? std::atof(argv[2]) : 1.0;

  const Vec3 c = oct.nodes[0].box.center();
  const double R = oct.nodes[0].box.boundingSphereRadius();
  const double targetMs = 1000.0 / 30.0;

  std::printf("%s  (%lld points, %zu nodes)  device = %.1fx our A16\n",
              argv[1], (long long)oct.meta.points, oct.nodes.size(), slowdown);
  std::printf("target %.1f ms (30 fps); cost model 0.20 + %.2f ms per million\n\n",
              targetMs, 9.12 * slowdown);
  std::printf("  %-8s | %-32s | %-32s | %s\n", "distance",
              "A: fixed 150px, budget moves", "B: budget ceiling, 150px moves", "verdict");
  std::printf("  ---------+----------------------------------+----------------------------------+--------\n");

  int bWins = 0, aWins = 0, ties = 0;
  for (double k : {0.15, 0.3, 0.5, 1.0, 2.0, 4.0}) {
    Camera cam = makeCamera({c.x, c.y, c.z + R*k}, c, 60, 1170, 2532, 0.001, R*200);
    const Result a = armA(oct, cam, targetMs, slowdown);
    const Result b = armB(oct, cam, targetMs, slowdown);
    const char* verdict;
    if (b.pts > a.pts * 1.05)      { verdict = "B more detail"; bWins++; }
    else if (a.pts > b.pts * 1.05) { verdict = "A more detail"; aWins++; }
    else                           { verdict = "tie";           ties++; }
    std::printf("  %6.2fR   | %8lld pts L%d %5.1fms bud %5.2fM | %8lld pts L%d %5.1fms px %6.1f | %s\n",
                k, (long long)a.pts, a.maxLevel, a.ms, a.knob/1e6,
                   (long long)b.pts, b.maxLevel, b.ms, b.knob, verdict);
  }

  std::printf("\n  B better at %d of 6 viewpoints, A at %d, tie at %d\n", bWins, aWins, ties);

  // Both arms must still honour the 30 fps target -- more detail is worthless if
  // it blows the frame time.
  bool overBudget = false;
  for (double k : {0.15, 0.3, 0.5, 1.0, 2.0, 4.0}) {
    Camera cam = makeCamera({c.x, c.y, c.z + R*k}, c, 60, 1170, 2532, 0.001, R*200);
    if (armA(oct, cam, targetMs, slowdown).ms > targetMs + 0.01) overBudget = true;
    if (armB(oct, cam, targetMs, slowdown).ms > targetMs + 0.01) overBudget = true;
  }
  std::printf("  frame-time target honoured by both arms at every viewpoint: %s\n",
              overBudget ? "NO <- a win that breaks 30 fps is not a win" : "yes");
  return 0;
}
