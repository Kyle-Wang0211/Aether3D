// Host test for LOD selection, against a REAL converted cloud.
//
// The product requirement being tested is the user's own words:
//   "1 亿点原样存在盘上,任何一个点在你拉近到它时都能看见"
// S2 is that sentence turned into something that can fail: walk EVERY leaf node
// of the real tree, put the camera in front of it, and require the selector to
// return it. A leaf that is never reachable means points that can never be seen.
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <random>
#include <string>
#include <vector>

#include "aether/pointcloud_lod/select.h"

using namespace aether::pointcloud_lod;

static int g_fail = 0;
static int g_skip = 0;
static void report(const char* name, bool ok, const std::string& detail) {
  std::printf("  %-4s %-54s %s\n", ok ? "PASS" : "FAIL", name, detail.c_str());
  if (!ok) g_fail++;
}
// Some checks only mean something on a cloud large enough that the frame budget
// can actually bind. On a small fixture their premise is false, and a check
// whose premise is false must say so rather than pass quietly.
static void skip(const char* name, const std::string& why) {
  std::printf("  %-4s %-54s %s\n", "SKIP", name, why.c_str());
  g_skip++;
}

// ---- test-only camera helpers (row-major, WebGPU clip z in [0,1]) ----
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
  const Vec3 f = norm(target - eye);      // forward
  const Vec3 s = norm(cross(f, up));      // right
  const Vec3 u = cross(s, f);
  const double v[16] = {
      s.x,  s.y,  s.z,  -dot(s, eye),
      u.x,  u.y,  u.z,  -dot(u, eye),
     -f.x, -f.y, -f.z,   dot(f, eye),
      0,    0,    0,     1};
  std::copy(v, v + 16, m);
}
// Reverse-free WebGPU perspective: z_ndc in [0,1].
static void perspective(double fovYDeg, double aspect, double zn, double zf, double m[16]) {
  const double t = 1.0 / std::tan(fovYDeg * M_PI / 180.0 / 2.0);
  const double p[16] = {
      t / aspect, 0, 0,                    0,
      0,          t, 0,                    0,
      0,          0, zf / (zn - zf),       zn * zf / (zn - zf),
      0,          0, -1,                   0};
  std::copy(p, p + 16, m);
}

static Camera makeCamera(Vec3 eye, Vec3 target, double fovY, int w, int h,
                         double zn, double zf) {
  Camera cam;
  cam.position = eye;
  cam.fovYDegrees = fovY;
  cam.screenHeightPx = h;
  double v[16], pr[16];
  lookAt(eye, target, {0, 1, 0}, v);
  perspective(fovY, double(w) / double(h), zn, zf, pr);
  mul(pr, v, cam.viewProj);
  return cam;
}

int main(int argc, char** argv) {
  if (argc < 2) { std::fprintf(stderr, "usage: test_select <octree dir>\n"); return 2; }
  Octree oct = loadOctree(argv[1]);
  if (!oct.error.empty()) { std::fprintf(stderr, "load failed: %s\n", oct.error.c_str()); return 1; }

  const Box3 root = oct.nodes[0].box;
  const Vec3 c = root.center();
  const double R = root.boundingSphereRadius();
  std::printf("tree: %zu nodes, bounding radius %.3f\n\n", oct.nodes.size(), R);

  // ---------- S1: the budget is actually enforced ----------
  {
    bool ok = true;
    std::string worst;
    for (int64_t budget : {50000LL, 250000LL, 1000000LL, 3630000LL, 10000000LL}) {
      SelectParams p; p.pointBudget = budget;
      Camera cam = makeCamera({c.x, c.y, c.z + R * 2.5}, c, 60, 1170, 2532, 0.01, R * 20);
      Selection s = selectVisible(oct, cam, p);
      if (s.numPoints > budget) { ok = false; worst = "budget " + std::to_string(budget); break; }
    }
    report("S1 selection never exceeds the point budget", ok,
           ok ? "5 budgets from 50k to 10M all respected" : ("violated at " + worst));
  }

  // ---------- S2: every leaf is reachable by moving the camera to it ----------
  // "任何一个点在你拉近到它时都能看见"
  {
    std::vector<int32_t> leaves;
    for (size_t i = 0; i < oct.nodes.size(); i++) {
      const Node& n = oct.nodes[i];
      const bool hasChild = std::any_of(n.children.begin(), n.children.end(),
                                        [](int32_t x) { return x >= 0; });
      if (!hasChild && n.numPoints > 0) leaves.push_back((int32_t)i);
    }
    SelectParams p; p.pointBudget = 3630000;  // our measured 30 fps budget on A16
    int64_t reached = 0;
    std::vector<std::string> missed;
    for (int32_t li : leaves) {
      const Node& n = oct.nodes[(size_t)li];
      const Vec3 nc = n.box.center();
      const double nr = n.box.boundingSphereRadius();
      // stand just outside the node, looking at it -- "拉近到它"
      Camera cam = makeCamera({nc.x, nc.y, nc.z + nr * 3.0}, nc, 60, 1170, 2532,
                              nr * 0.01, R * 20);
      Selection s = selectVisible(oct, cam, p);
      if (std::find(s.nodes.begin(), s.nodes.end(), li) != s.nodes.end()) reached++;
      else if (missed.size() < 8) missed.push_back(n.name);
    }
    char buf[256];
    std::string m;
    for (auto& s : missed) m += " " + s;
    std::snprintf(buf, sizeof buf, "%lld / %zu leaves reached (%.2f%%)%s",
                  (long long)reached, leaves.size(),
                  100.0 * double(reached) / double(leaves.size()),
                  missed.empty() ? "" : (", missed:" + m).c_str());
    report("S2 EVERY leaf node is reachable by zooming to it",
           reached == (int64_t)leaves.size(), buf);
  }

  // ---------- S3: distance monotonicity ----------
  {
    SelectParams p; p.pointBudget = 3630000;
    int64_t near = 0, far = 0;
    { Camera cam = makeCamera({c.x, c.y, c.z + R * 0.15}, c, 60, 1170, 2532, 0.001, R*20);
      near = selectVisible(oct, cam, p).numPoints; }
    { Camera cam = makeCamera({c.x, c.y, c.z + R * 30.0}, c, 60, 1170, 2532, 0.001, R*200);
      far = selectVisible(oct, cam, p).numPoints; }
    char buf[160];
    std::snprintf(buf, sizeof buf, "near %lld pts, far %lld pts", (long long)near, (long long)far);
    report("S3 pulling back selects fewer points", far < near, buf);
  }

  // ---------- S4: the selection is a connected subtree ----------
  {
    SelectParams p; p.pointBudget = 1000000;
    Camera cam = makeCamera({c.x, c.y, c.z + R * 1.5}, c, 60, 1170, 2532, 0.01, R*20);
    Selection s = selectVisible(oct, cam, p);
    std::vector<char> in(oct.nodes.size(), 0);
    for (int32_t i : s.nodes) in[(size_t)i] = 1;
    std::string orphan;
    for (int32_t i : s.nodes) {
      int32_t par = oct.nodes[(size_t)i].parent;
      // an ancestor may legitimately hold 0 points (potree issue #1125 node);
      // walk up past those.
      while (par >= 0 && oct.nodes[(size_t)par].numPoints == 0) par = oct.nodes[(size_t)par].parent;
      if (par >= 0 && !in[(size_t)par]) { orphan = oct.nodes[(size_t)i].name; break; }
    }
    char buf[200];
    std::snprintf(buf, sizeof buf, "%zu nodes, %lld pts%s", s.nodes.size(),
                  (long long)s.numPoints,
                  orphan.empty() ? "" : (", orphan " + orphan).c_str());
    report("S4 selection is a connected subtree (no orphans)", orphan.empty(), buf);
  }

  // ---------- negative controls ----------
  std::printf("\nnegative controls (each must be rejected):\n");
  {
    // N1: a budget below the root's own point count must stop immediately.
    SelectParams p; p.pointBudget = 1;
    Camera cam = makeCamera({c.x, c.y, c.z + R * 2}, c, 60, 1170, 2532, 0.01, R*20);
    Selection s = selectVisible(oct, cam, p);
    char buf[160];
    std::snprintf(buf, sizeof buf, "budget 1 -> %lld pts, hitBudget=%d",
                  (long long)s.numPoints, (int)s.hitBudget);
    report("N1 an impossible budget yields ~nothing", s.numPoints <= 1 && s.hitBudget, buf);
  }
  {
    // N2: camera pointed away -- only the pinned levels 0-2 may come back.
    SelectParams p; p.pointBudget = 3630000;
    Camera cam = makeCamera({c.x, c.y, c.z + R * 3},
                            {c.x, c.y, c.z + R * 100}, 60, 1170, 2532, 0.01, R*20);
    Selection s = selectVisible(oct, cam, p);
    int maxLvl = 0;
    for (int32_t i : s.nodes) maxLvl = std::max(maxLvl, oct.nodes[(size_t)i].level);
    char buf[160];
    std::snprintf(buf, sizeof buf, "looking away -> %zu nodes, max level %d",
                  s.nodes.size(), maxLvl);
    report("N2 looking away selects only the pinned levels 0-2", maxLvl <= 2, buf);
  }
  {
    // N3: the budget check must be load-bearing. Pick a view where an unbounded
    // walk wants MORE than the budget, then show the budget actually cuts it.
    // (An earlier version of this control assumed the budget binds at the
    // closest viewpoint. It does not -- minimumNodePixelSize stops the descent
    // first -- so the control was testing a false premise.)
    Camera cam = makeCamera({c.x, c.y, c.z + R * 0.15}, c, 60, 1170, 2532, 0.001, R*20);
    SelectParams unbounded; unbounded.pointBudget = std::numeric_limits<int64_t>::max();
    const int64_t uncapped = selectVisible(oct, cam, unbounded).numPoints;
    SelectParams capped; capped.pointBudget = uncapped / 2;
    Selection s = selectVisible(oct, cam, capped);
    char buf[200];
    std::snprintf(buf, sizeof buf, "uncapped %lld -> budget %lld gave %lld, hitBudget=%d",
                  (long long)uncapped, (long long)capped.pointBudget,
                  (long long)s.numPoints, (int)s.hitBudget);
    report("N3 halving the budget actually cuts the selection",
           s.numPoints <= capped.pointBudget && s.hitBudget && uncapped > 0, buf);
  }
  {
    // N4: minimumNodePixelSize must be load-bearing too -- dropping it to 0
    // should let the walk descend much further at the same viewpoint.
    Camera cam = makeCamera({c.x, c.y, c.z + R * 0.15}, c, 60, 1170, 2532, 0.001, R*20);
    SelectParams a; a.pointBudget = std::numeric_limits<int64_t>::max();
    SelectParams b = a; b.minimumNodePixelSize = 0.0;
    const Selection sa = selectVisible(oct, cam, a);
    const Selection sb = selectVisible(oct, cam, b);
    int la = 0, lb = 0;
    for (int32_t i : sa.nodes) la = std::max(la, oct.nodes[(size_t)i].level);
    for (int32_t i : sb.nodes) lb = std::max(lb, oct.nodes[(size_t)i].level);
    char buf[220];
    std::snprintf(buf, sizeof buf,
                  "150px -> %lld pts maxLevel %d ; 0px -> %lld pts maxLevel %d",
                  (long long)sa.numPoints, la, (long long)sb.numPoints, lb);
    if (sb.numPoints == sa.numPoints && sb.numPoints >= oct.meta.points * 9 / 10) {
      char why[260];
      std::snprintf(why, sizeof why,
                    "cloud too small: 0px already returns %lld of the cloud's %lld "
                    "points, so the threshold cannot be what limits anything",
                    (long long)sb.numPoints, (long long)oct.meta.points);
      skip("N4 minimumNodePixelSize=150 is what stops the descent", why);
    } else {
      report("N4 minimumNodePixelSize=150 is what stops the descent",
             sb.numPoints > sa.numPoints && lb > la, buf);
    }
  }

  // ---------- what this actually costs at 30 fps ----------
  std::printf("\n30 fps budget (3.63M) at a few viewpoints:\n");
  for (double k : {0.15, 0.5, 1.0, 2.5, 8.0}) {
    SelectParams p; p.pointBudget = 3630000;
    Camera cam = makeCamera({c.x, c.y, c.z + R * k}, c, 60, 1170, 2532, 0.001, R*200);
    Selection s = selectVisible(oct, cam, p);
    int maxLvl = 0;
    for (int32_t i : s.nodes) maxLvl = std::max(maxLvl, oct.nodes[(size_t)i].level);
    SelectParams un; un.pointBudget = std::numeric_limits<int64_t>::max();
    const int64_t uncapped = selectVisible(oct, cam, un).numPoints;
    std::printf("  dist %5.2fR : %8lld pts  %5zu nodes  maxLevel %d  spacing %.4f  "
                "uncapped would be %lld %s\n",
                k, (long long)s.numPoints, s.nodes.size(), maxLvl, s.lowestSpacing,
                (long long)uncapped,
                s.hitBudget ? "<- BUDGET BINDS" : "<- screen-space caps it, budget idle");
  }

  // ---------- the adaptive controller ----------
  std::printf("\nQualityController, 33.3 ms target, starting at Potree's 150 px:\n");
  {
    // Simulate a device 3x slower than our A16 reference. The loop may only use
    // the previous frame's measured time -- exactly what the runtime will have.
    QualityController qc;
    SelectParams p; p.pointBudget = 3630000;        // hard ceiling, not the knob
    Camera cam = makeCamera({c.x, c.y, c.z + R * 1.0}, c, 60, 1170, 2532, 0.001, R*20);
    Selection s;
    double frameMs = 0;
    for (int i = 0; i < 400; i++) {
      p.minimumNodePixelSize = qc.pixelSize();
      s = selectVisible(oct, cam, p);
      frameMs = 0.20 + 9.12 * 3.0 * (double(s.numPoints) / 1e6);
      qc.onFrame(frameMs);
    }
    int lv = 0; for (int32_t i : s.nodes) lv = std::max(lv, oct.nodes[(size_t)i].level);
    char buf[240];
    std::snprintf(buf, sizeof buf,
                  "settled at %.1f px -> %lld pts, level %d, %.1f ms (%.1f fps)",
                  qc.pixelSize(), (long long)s.numPoints, lv, frameMs, 1000.0/frameMs);
    // The whole cloud costs this much; if that is already under the target the
    // controller has nothing to converge to and the check is meaningless.
    const double wholeCloudMs = 0.20 + 9.12 * 3.0 * (double(oct.meta.points) / 1e6);
    if (wholeCloudMs < 33.3) {
      char why[280];
      std::snprintf(why, sizeof why,
                    "cloud too small: drawing ALL %lld points costs %.1f ms, under the "
                    "33.3 ms target, so there is no frame pressure to converge against",
                    (long long)oct.meta.points, wholeCloudMs);
      skip("C1 controller converges to 30 fps on a 3x slower device", why);
    } else {
      report("C1 controller converges to 30 fps on a 3x slower device",
             frameMs <= 33.4 && frameMs > 26.0 && s.numPoints <= p.pointBudget, buf);
    }
  }
  {
    // The ceiling must still hold even when the controller wants more.
    QualityController::Config cfg; cfg.targetFrameMs = 100000.0;  // never "too slow"
    QualityController qc(cfg);
    SelectParams p; p.pointBudget = 500000;
    Camera cam = makeCamera({c.x, c.y, c.z + R * 1.0}, c, 60, 1170, 2532, 0.001, R*20);
    Selection s;
    for (int i = 0; i < 400; i++) { p.minimumNodePixelSize = qc.pixelSize();
      s = selectVisible(oct, cam, p); qc.onFrame(1.0); }
    char buf[200];
    std::snprintf(buf, sizeof buf, "px driven down to %.1f, budget 500k gave %lld pts",
                  qc.pixelSize(), (long long)s.numPoints);
    report("C2 the point budget remains a hard ceiling",
           s.numPoints <= 500000, buf);
  }

  if (g_skip) {
    std::printf("\n  %d check(s) skipped -- their premise does not hold on a cloud this\n"
                "  small. Run against a full-size cloud to exercise them.\n", g_skip);
  }
  std::printf("\n==== %s ====\n",
              g_fail == 0 ? (g_skip ? "PASS (with skips)" : "ALL PASS") : "FAILED");
  return g_fail == 0 ? 0 : 1;
}
