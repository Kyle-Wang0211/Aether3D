// Host test for Selection::lowestSpacing = Potree's per-frame lowestSpacing
// (DEVIATIONS.md D18; potree @ 5636cd4 Potree_update_visibility.js :114,
// :276-280, :413 -- min spacing over EVERY node popped from the queue, taken
// before the budget break :282 and the visibility test :286).
//
//   G1  the selection itself did not change: SweepHash (selection_sweep.h --
//       node list in order, numPoints, nodesConsidered, hitBudget, promoted,
//       unloaded; 9,600 calls incl. orthographic and streaming) equals the value
//       the code BEFORE this change produced (golden, per known tree; an unknown
//       tree reports SKIP)
//   L1  lowestSpacing == an independent reference: the instrumentation hook
//       (SelectParams::onPop) records every popped node, the test takes the min
//       of their spacings itself; bit for bit, every call of the sweep. The hook
//       fires exactly nodesConsidered times and does not change the result.
//   N1  negative control: the OLD definition (min over nodes that passed both
//       tests -- recorded exactly through a Residency whose state() is called
//       once per accepted node) must differ from the new value in >= 1 call;
//       the first such pose and both values are printed.
//   E1  nothing popped (empty tree) -> +infinity (the viewer reports it as 0)
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

static int g_fail = 0, g_skip = 0;
static void report(const char* name, bool ok, const std::string& detail) {
  std::printf("  %-4s %-62s %s\n", ok ? "PASS" : "FAIL", name, detail.c_str());
  if (!ok) g_fail++;
}
static void skip(const char* name, const std::string& why) {
  std::printf("  %-4s %-62s %s\n", "SKIP", name, why.c_str());
  g_skip++;
}

// Golden SweepHash from the code before D18 (engine 740c1dd, select.cpp with
// lowestSpacing after both tests), computed by selection_sweep.h against that
// revision's select.{h,cpp}.
struct Golden { int64_t points; size_t nodes; uint64_t hash; const char* name; };
static const Golden kGolden[] = {
    {25000, 82, 0xd75d302eccc381b1ull, "fixture"},
    {36232793, 16227, 0x88ca7530b246fb1bull, "36M"},
    {216655968, 104751, 0x9007c0d55aa9cdb0ull, "216M"},
};

struct Pops { std::vector<int32_t> nodes; };
static void OnPop(int32_t n, void* ctx) { static_cast<Pops*>(ctx)->nodes.push_back(n); }

struct Accepted { std::vector<int32_t> nodes; };
static NodeState RecordAccepted(int32_t n, void* ctx) {
  static_cast<Accepted*>(ctx)->nodes.push_back(n);
  return NodeState::Drawable;   // same walk as the plain overload
}

static bool SameBits(double a, double b) { return std::memcmp(&a, &b, sizeof a) == 0; }

int main(int argc, char** argv) {
  if (argc < 2) { std::fprintf(stderr, "usage: test_spacing <octree dir>\n"); return 2; }
  Octree oct = loadOctree(argv[1]);
  if (!oct.error.empty()) { std::fprintf(stderr, "load failed: %s\n", oct.error.c_str()); return 1; }
  std::printf("tree: %zu nodes, %lld points\n\n", oct.nodes.size(), (long long)oct.meta.points);

  int64_t calls = 0, refMismatch = 0, popCountMismatch = 0, hookChanged = 0, oldDiffers = 0;
  std::string firstDiff;
  long n = 0;
  int poseIndex = -1, callInPose = 0;
  const uint64_t h = pwlod_sweep::SweepHash(oct, &n, [&](const Camera& cam, const SelectParams& p,
                                                          const Selection& s, bool streaming) {
    (void)streaming;
    // pose index = calls / 24 (4 px x 3 budgets x 2 overloads per pose)
    poseIndex = (int)(calls / 24);
    callInPose = (int)(calls % 24);
    calls++;
    // L1: the same call with the pop recorder
    Pops pops;
    SelectParams q = p;
    q.onPop = &OnPop;
    q.onPopCtx = &pops;
    Selection r;
    if (streaming) {
      Residency res;
      res.state = &pwlod_sweep::SyntheticState;
      r = selectVisible(oct, cam, q, res);
    } else {
      r = selectVisible(oct, cam, q);
    }
    double ref = std::numeric_limits<double>::infinity();
    for (int32_t id : pops.nodes) {
      const double sp = oct.nodes[(size_t)id].spacing;
      if (sp != 0.0 && !std::isnan(sp)) ref = std::min(ref, sp);
    }
    if (!SameBits(r.lowestSpacing, ref)) refMismatch++;
    if ((int64_t)pops.nodes.size() != r.nodesConsidered) popCountMismatch++;
    if (!SameBits(r.lowestSpacing, s.lowestSpacing) || r.nodes != s.nodes || r.numPoints != s.numPoints)
      hookChanged++;
    // N1: the old definition, exactly -- min over accepted nodes
    if (!streaming) {
      Accepted acc;
      Residency rec;
      rec.state = &RecordAccepted;
      rec.ctx = &acc;
      (void)selectVisible(oct, cam, p, rec);
      double old = std::numeric_limits<double>::infinity();
      for (int32_t id : acc.nodes) {
        const double sp = oct.nodes[(size_t)id].spacing;
        if (sp > 0) old = std::min(old, sp);   // the old select.cpp line
      }
      if (!SameBits(old, s.lowestSpacing)) {
        oldDiffers++;
        if (firstDiff.empty()) {
          char b[400];
          std::snprintf(b, sizeof b,
                        "first at sweep pose %d (%s, px %.2f, budget %lld): old %.17g vs new %.17g "
                        "(%lld popped, %zu accepted, hitBudget %d)",
                        poseIndex, cam.orthographic ? "orthographic" : "perspective",
                        p.minimumNodePixelSize, (long long)p.pointBudget, old, s.lowestSpacing,
                        (long long)s.nodesConsidered, acc.nodes.size(), (int)s.hitBudget);
          firstDiff = b;
        }
      }
    }
    (void)callInPose;
  });

  // G1
  const Golden* g = nullptr;
  for (const Golden& x : kGolden)
    if (x.points == oct.meta.points && x.nodes == oct.nodes.size()) g = &x;
  char hb[64];
  std::snprintf(hb, sizeof hb, "%016llx", (unsigned long long)h);
  if (!g) {
    skip("G1 selection unchanged by D18 (golden SweepHash)", std::string("unknown tree, hash ") + hb);
  } else {
    char want[64];
    std::snprintf(want, sizeof want, "%016llx", (unsigned long long)g->hash);
    report("G1 selection unchanged by D18 (golden SweepHash)", h == g->hash,
           std::string(g->name) + ": " + hb + " vs golden " + want + ", " + std::to_string(n) + " calls");
  }
  report("L1 lowestSpacing == min over instrumented pops (bit for bit)",
         calls > 0 && refMismatch == 0 && popCountMismatch == 0 && hookChanged == 0,
         std::to_string(calls) + " calls, mismatches " + std::to_string(refMismatch) +
             ", pop-count mismatches " + std::to_string(popCountMismatch) + ", hook changed result " +
             std::to_string(hookChanged));
  {
    Octree empty;
    Camera cam;
    SelectParams p;
    const Selection s = selectVisible(empty, cam, p);
    report("E1 nothing popped -> +infinity (viewer reports 0)",
           std::isinf(s.lowestSpacing) && s.lowestSpacing > 0 && s.nodesConsidered == 0, "empty tree");
  }
  std::printf("\nnegative controls (each must be rejected):\n");
  report("N1 old definition (accepted nodes only) differs somewhere", oldDiffers > 0,
         std::to_string(oldDiffers) + " of " + std::to_string(calls / 2) + " plain calls differ; " + firstDiff);
  if (g_skip) std::printf("\n  %d check(s) skipped.\n", g_skip);
  std::printf("\n==== %s ====\n", g_fail == 0 ? (g_skip ? "PASS (with skips)" : "ALL PASS") : "FAILED");
  return g_fail == 0 ? 0 : 1;
}
