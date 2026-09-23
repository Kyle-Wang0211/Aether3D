// Host test for asynchronous loading + Potree's per-frame limits, against a
// REAL converted cloud (committed fixture, or any octree dir on the command line).
//
// A simulated renderer drives the library exactly as a real one would:
//   poll -> release GPU for drainEvicted -> streaming selectVisible ->
//   upload `promoted` -> touch drawn nodes -> request(unloaded)
//
//   A1  eventually complete: the streamed drawn set converges to exactly the
//       synchronous selection (same nodes, same point count) -- nothing lost
//   A2  never more than 2 promotions (GPU uploads) per frame   (:300)
//   A3  never more than maxNodesLoading loads in flight        (Potree.js:104)
//   A4  no holes: every drawn node's ancestors are all drawable, every frame;
//       and every node of the final selection is covered by a drawn
//       ancestor-or-self from the frame the root appears
//   A5  the same four under cache pressure while the camera moves, with
//       evictions and disposed descendants actually happening (non-vacuous)
//   C1  NodeCache::contains() does not change the LRU order or the hit counts
//   C2  the eviction callback fires for budget victims only
//   C3  Stats::droppedForCache counts the silent drop, and is 0 with room
//   D1  density = Potree's occupancy on hand-built nodes (1, 2, 100 per cell)
//
// Negative controls -- each must make its check fail:
//   N1  unlimited promotions  -> A2 fires
//   N2  maxNodesLoading = 64  -> A3 fires
//   N3  one node never loads  -> A1 fires
//   N4  a drawn node's parent removed from the GPU set -> A4 fires
//   N5  get() instead of contains() -> C1's victim changes
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <set>
#include <string>
#include <unordered_set>
#include <vector>

#include "aether/pointcloud_lod/stream.h"

using namespace aether::pointcloud_lod;

static int g_fail = 0;
static void report(const char* n, bool ok, const std::string& d) {
  std::printf("  %-4s %-56s %s\n", ok ? "PASS" : "FAIL", n, d.c_str());
  if (!ok) g_fail++;
}

// ---- camera helpers (row-major, WebGPU clip z in [0,1]), as in test_select ----
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
  const double t = 1.0/std::tan(fov*3.14159265358979323846/180.0/2.0);
  const double p[16] = { t/(double(w)/double(h)),0,0,0, 0,t,0,0,
                         0,0,zf/(zn-zf),zn*zf/(zn-zf), 0,0,-1,0 };
  mul(p, v, cam.viewProj);
  return cam;
}

// ---- simulated renderer ----
struct Sim {
  const Octree* oct = nullptr;
  AsyncNodeLoader* loader = nullptr;
  std::unordered_set<int32_t> gpu;      // "tree nodes"
  int32_t neverLoad = -1;               // N3
  bool ignoreEvictions = false;
  static NodeState state(int32_t n, void* ctx) {
    Sim* s = static_cast<Sim*>(ctx);
    if (s->gpu.count(n)) return NodeState::Drawable;
    if (n == s->neverLoad) return NodeState::Unloaded;
    return s->loader->state(n);
  }
};

struct FrameLog {
  size_t promoted = 0;
  int inFlight = 0;
  bool ancestorsOk = true;
  double coverage = 1.0;   // of the reference selection, by drawn ancestor-or-self
  bool rootDrawn = false;
};

// Every drawn node must have all its ancestors drawable (on the GPU).
static bool ancestorsDrawable(const Octree& oct, const std::vector<int32_t>& drawn,
                              const std::unordered_set<int32_t>& gpu) {
  for (int32_t n : drawn) {
    for (int32_t a = oct.nodes[(size_t)n].parent; a >= 0; a = oct.nodes[(size_t)a].parent)
      if (!gpu.count(a)) return false;
  }
  return true;
}

static double coverageOf(const Octree& oct, const std::vector<int32_t>& ref,
                         const std::unordered_set<int32_t>& gpu) {
  if (ref.empty()) return 1.0;
  size_t cov = 0;
  for (int32_t n : ref) {
    for (int32_t a = n; a >= 0; a = oct.nodes[(size_t)a].parent)
      if (gpu.count(a)) { cov++; break; }
  }
  return double(cov) / double(ref.size());
}

// One frame of the simulated renderer. Returns the streaming selection.
static Selection frame(Sim& sim, const Camera& cam, const SelectParams& p, int maxPromo,
                       const std::vector<int32_t>& ref, FrameLog* log) {
  sim.loader->poll();
  for (int32_t n : sim.loader->drainEvicted())
    if (!sim.ignoreEvictions) sim.gpu.erase(n);
  Residency r; r.state = &Sim::state; r.ctx = &sim; r.maxPromotionsPerFrame = maxPromo;
  Selection s = selectVisible(*sim.oct, cam, p, r);
  for (int32_t n : s.promoted) { sim.loader->touch(n); sim.gpu.insert(n); }   // upload
  for (int32_t n : s.nodes) sim.loader->touch(n);                              // :310
  sim.loader->request(s.unloaded);
  if (log) {
    log->promoted = s.promoted.size();
    log->inFlight = sim.loader->numNodesLoading();
    log->ancestorsOk = ancestorsDrawable(*sim.oct, s.nodes, sim.gpu);
    log->rootDrawn = sim.gpu.count(0) != 0;
    log->coverage = coverageOf(*sim.oct, ref, sim.gpu);
  }
  return s;
}

struct RunResult {
  bool converged = false;
  int frames = 0;
  size_t maxPromoted = 0;
  int maxInFlight = 0;
  bool ancestorsOk = true;
  double minCoverageAfterRoot = 1.0;
  std::set<int32_t> finalNodes;
  int64_t finalPoints = 0;
};

static RunResult streamUntilStable(const Octree& oct, const std::string& bin, const Camera& cam,
                                   const SelectParams& p, const std::vector<int32_t>& ref,
                                   int maxPromo, int maxLoading, int32_t neverLoad,
                                   size_t cacheBytes, int maxFrames) {
  AsyncNodeLoader::Config cfg; cfg.cacheBytes = cacheBytes; cfg.maxNodesLoading = maxLoading;
  cfg.workers = 4;
  AsyncNodeLoader loader(oct, bin, cfg);
  Sim sim; sim.oct = &oct; sim.loader = &loader; sim.neverLoad = neverLoad;
  RunResult rr;
  int quiet = 0;
  for (int f = 0; f < maxFrames; f++) {
    FrameLog lg;
    Selection s = frame(sim, cam, p, maxPromo, ref, &lg);
    rr.frames = f + 1;
    rr.maxPromoted = std::max(rr.maxPromoted, lg.promoted);
    rr.maxInFlight = std::max(rr.maxInFlight, lg.inFlight);
    rr.ancestorsOk = rr.ancestorsOk && lg.ancestorsOk;
    if (lg.rootDrawn) rr.minCoverageAfterRoot = std::min(rr.minCoverageAfterRoot, lg.coverage);
    rr.finalNodes = std::set<int32_t>(s.nodes.begin(), s.nodes.end());
    rr.finalPoints = 0;
    for (int32_t n : s.nodes) rr.finalPoints += oct.nodes[(size_t)n].numPoints;
    const bool idle = s.unloaded.empty() && s.promoted.empty() && loader.numNodesLoading() == 0;
    quiet = idle ? quiet + 1 : 0;
    if (quiet >= 3) { rr.converged = true; break; }
    if (loader.numNodesLoading() > 0) loader.waitAndPoll(50);
  }
  return rr;
}

// Loads every node of `nodes` into the loader's cache without drawing any, then
// runs ONE streaming frame: every node is Loaded, so the frame's promotions are
// bounded only by the promotion limit. Deterministic.
static size_t promotionsInPreloadedFrame(const Octree& oct, const std::string& bin, const Camera& cam,
                                         const SelectParams& p, const std::vector<int32_t>& nodes,
                                         int maxPromo, size_t cacheBytes) {
  AsyncNodeLoader::Config cfg; cfg.cacheBytes = cacheBytes; cfg.maxNodesLoading = 4; cfg.workers = 4;
  AsyncNodeLoader loader(oct, bin, cfg);
  std::vector<int32_t> all = nodes;
  for (int32_t n : nodes)   // ancestors too, so the whole path can be promoted in one frame
    for (int32_t a = oct.nodes[(size_t)n].parent; a >= 0; a = oct.nodes[(size_t)a].parent) all.push_back(a);
  for (int guard = 0; guard < 100000; guard++) {
    std::vector<int32_t> missing;
    for (int32_t n : all) if (!loader.cache().contains(n)) missing.push_back(n);
    if (missing.empty()) break;
    loader.request(missing);
    loader.waitAndPoll(50);
  }
  Sim sim; sim.oct = &oct; sim.loader = &loader;
  Residency r; r.state = &Sim::state; r.ctx = &sim; r.maxPromotionsPerFrame = maxPromo;
  return selectVisible(oct, cam, p, r).promoted.size();
}

// ---- synthetic octree for D1 ----
static Octree syntheticOctree() {
  Octree o;
  o.meta.scale = {1, 1, 1};
  o.meta.offset = {0, 0, 0};
  Attribute pos; pos.name = "position"; pos.size = 12; pos.numElements = 3; pos.elementSize = 4; pos.type = "int32";
  Attribute rgb; rgb.name = "rgb"; rgb.size = 6; rgb.numElements = 3; rgb.elementSize = 2; rgb.type = "uint16";
  o.meta.attributes = {pos, rgb};
  Node n; n.name = "r"; n.box.min = {0, 0, 0}; n.box.max = {32, 32, 32};
  n.children.fill(-1);
  o.nodes.push_back(n);
  return o;
}
static std::vector<uint8_t> records(const std::vector<std::array<int32_t, 3>>& pts) {
  std::vector<uint8_t> b(pts.size() * 18, 0);
  for (size_t i = 0; i < pts.size(); i++) std::memcpy(&b[i * 18], pts[i].data(), 12);
  return b;
}

int main(int argc, char** argv) {
  if (argc < 2) { std::fprintf(stderr, "usage: test_async <octree dir>\n"); return 2; }
  const std::string dir = argv[1];
  Octree oct = loadOctree(dir);
  if (!oct.error.empty()) { std::fprintf(stderr, "load failed: %s\n", oct.error.c_str()); return 1; }
  const std::string bin = dir + "/octree.bin";

  const Vec3 c = oct.nodes[0].box.center();
  const double R = oct.nodes[0].box.boundingSphereRadius();
  SelectParams p; p.pointBudget = 3630000;
  const Camera cam = makeCamera({c.x, c.y, c.z + R * 0.4}, c, 60, 1170, 2532, 0.001, R * 20);
  const Selection ref = selectVisible(oct, cam, p);           // the synchronous answer
  const std::set<int32_t> refSet(ref.nodes.begin(), ref.nodes.end());
  const size_t cacheBytes = (size_t)(2 * 15) * (size_t)p.pointBudget;   // viewer.js:1628
  std::printf("tree %zu nodes; reference selection %zu nodes, %lld points\n\n",
              oct.nodes.size(), ref.nodes.size(), (long long)ref.numPoints);

  // ---- A1-A4 ----
  const RunResult rr = streamUntilStable(oct, bin, cam, p, ref.nodes, 2, 4, -1, cacheBytes, 20000);
  {
    char b[240];
    std::snprintf(b, sizeof b, "converged=%d after %d frames; %zu vs %zu nodes, %lld vs %lld pts",
                  (int)rr.converged, rr.frames, rr.finalNodes.size(), refSet.size(),
                  (long long)rr.finalPoints, (long long)ref.numPoints);
    report("A1 streamed set converges to the synchronous selection",
           rr.converged && rr.finalNodes == refSet && rr.finalPoints == ref.numPoints, b);
    const size_t pre = promotionsInPreloadedFrame(oct, bin, cam, p, ref.nodes, 2, cacheBytes);
    std::snprintf(b, sizeof b, "stream: max %zu per frame; all-loaded frame: %zu promoted",
                  rr.maxPromoted, pre);
    report("A2 at most 2 promotions (GPU uploads) per frame",
           rr.maxPromoted >= 1 && rr.maxPromoted <= 2 && (ref.nodes.size() < 3 || pre == 2), b);
    std::snprintf(b, sizeof b, "max %d in flight", rr.maxInFlight);
    report("A3 at most maxNodesLoading=4 loads in flight",
           rr.maxInFlight <= 4 && rr.maxInFlight > 0, b);
    std::snprintf(b, sizeof b, "ancestors ok every frame=%d; min coverage after root %.4f",
                  (int)rr.ancestorsOk, rr.minCoverageAfterRoot);
    report("A4 no holes: drawn set ancestor-closed, reference covered",
           rr.ancestorsOk && rr.minCoverageAfterRoot == 1.0, b);
  }

  // ---- A5: cache pressure + camera motion ----
  {
    // Pressure on purpose: the cache sits at its 15 B x budget floor (half of
    // Potree's 2x) and the camera sweeps the tree, so LRU victims -- including
    // drawn nodes with drawn descendants -- really occur.
    SelectParams pp; pp.pointBudget = std::min<int64_t>(p.pointBudget, std::max<int64_t>(ref.numPoints / 2, (int64_t)oct.nodes[0].numPoints * 2));
    const size_t smallCache = (size_t)15 * (size_t)pp.pointBudget;
    AsyncNodeLoader::Config cfg; cfg.cacheBytes = smallCache; cfg.maxNodesLoading = 4; cfg.workers = 4;
    AsyncNodeLoader loader(oct, bin, cfg);
    Sim sim; sim.oct = &oct; sim.loader = &loader;
    bool ancOk = true, gpuInCache = true; size_t maxPromo = 0; int maxFly = 0;
    const int kFrames = 1200;
    for (int f = 0; f < kFrames; f++) {
      const double th = 6.283185307179586 * f / 300.0;
      const double d = R * (0.3 + 0.25 * std::sin(f * 0.013));
      const Vec3 eye{c.x + d * std::sin(th), c.y + 0.3 * R * std::cos(f * 0.021), c.z + d * std::cos(th)};
      // look at a point that wanders over the tree, not always the centre
      const Vec3 tgt{c.x + 0.3 * R * std::cos(f * 0.017), c.y, c.z + 0.3 * R * std::sin(f * 0.011)};
      const Camera cm = makeCamera(eye, tgt, 60, 1170, 2532, 0.001, R * 20);
      FrameLog lg;
      frame(sim, cm, pp, 2, {}, &lg);
      ancOk = ancOk && lg.ancestorsOk;
      maxPromo = std::max(maxPromo, lg.promoted);
      maxFly = std::max(maxFly, lg.inFlight);
      for (int32_t n : sim.gpu) if (!loader.cache().contains(n)) { gpuInCache = false; break; }
      if (loader.numNodesLoading() > 0) loader.waitAndPoll(2);
    }
    const auto& st = loader.stats();
    char b[300];
    std::snprintf(b, sizeof b, "%d frames: evicted %lld, disposed descendants %lld, ancestors ok=%d, "
                  "gpu subset of cache=%d, max promo %zu, max in flight %d",
                  kFrames, (long long)st.evicted, (long long)st.disposedDescendants, (int)ancOk,
                  (int)gpuInCache, maxPromo, maxFly);
    report("A5 invariants hold under eviction pressure (non-vacuous)",
           ancOk && gpuInCache && maxPromo <= 2 && maxFly <= 4 && st.evicted > 0 &&
               st.disposedDescendants > 0, b);
  }

  // ---- C1-C3 ----
  auto mkNode = [&](int32_t id, size_t pts) {
    NodePoints np; np.node = id; np.xyz.assign(pts * 3, 0.f); np.rgb.assign(pts * 3, 0); return np;
  };
  auto victimAfter = [&](bool useGet) {
    NodeCache cache(3 * 150);   // three 10-point nodes (15 B/pt) fit, a fourth evicts one
    cache.put(mkNode(1, 10)); cache.put(mkNode(2, 10)); cache.put(mkNode(3, 10));
    const int64_t h0 = cache.hits(), m0 = cache.misses();
    for (int i = 0; i < 5; i++) { if (useGet) cache.get(1); else (void)cache.contains(1); }
    const bool statsSame = cache.hits() == h0 && cache.misses() == m0;
    cache.put(mkNode(4, 10));
    int victim = -1;
    for (int k = 1; k <= 3; k++) if (!cache.contains(k)) victim = k;
    return std::make_pair(victim, statsSame);
  };
  {
    const auto r1 = victimAfter(false);
    char b[160]; std::snprintf(b, sizeof b, "victim %d (LRU = 1), hit/miss counters unchanged=%d",
                               r1.first, (int)r1.second);
    report("C1 contains() leaves LRU order and stats alone", r1.first == 1 && r1.second, b);
  }
  {
    struct Rec { std::vector<int32_t> ev; static void cb(int32_t n, void* c) { static_cast<Rec*>(c)->ev.push_back(n); } } rec;
    NodeCache cache(3 * 150);
    cache.setEvictionCallback(&Rec::cb, &rec);
    cache.put(mkNode(1, 10)); cache.put(mkNode(2, 10)); cache.put(mkNode(3, 10));
    cache.put(mkNode(2, 10));   // replace: not an eviction
    cache.erase(3);             // explicit: not an eviction
    cache.put(mkNode(5, 10)); cache.put(mkNode(6, 10));   // 1,2,5,6 -> budget 3 -> evict LRU = 1
    char b[160]; std::snprintf(b, sizeof b, "callback saw %zu eviction(s): %s", rec.ev.size(),
                               rec.ev.size() == 1 && rec.ev[0] == 1 ? "[1]" : "unexpected");
    report("C2 eviction callback fires for budget victims only", rec.ev.size() == 1 && rec.ev[0] == 1, b);
  }
  {
    int64_t selBytes = 0;
    for (int32_t n : ref.nodes) selBytes += (int64_t)oct.nodes[(size_t)n].numPoints * 15;
    NodeLoader small(oct, bin, (size_t)std::max<int64_t>(selBytes / 4, 1));
    NodeLoader::Stats s1; auto got1 = small.load(ref, &s1);
    NodeLoader big(oct, bin, (size_t)selBytes * 2 + 1024);
    NodeLoader::Stats s2; auto got2 = big.load(ref, &s2);
    char b[200]; std::snprintf(b, sizeof b, "quarter cache: dropped %lld (= %zu - %zu); ample cache: dropped %lld",
                               (long long)s1.droppedForCache, ref.nodes.size(), got1.size(),
                               (long long)s2.droppedForCache);
    report("C3 Stats::droppedForCache counts the silent drop",
           ref.nodes.size() > 1 && s1.droppedForCache > 0 &&
               s1.droppedForCache == (int64_t)(ref.nodes.size() - got1.size()) &&
               s2.droppedForCache == 0 && got2.size() == ref.nodes.size(), b);
  }

  // ---- D1 ----
  {
    Octree so = syntheticOctree();
    std::vector<std::array<int32_t, 3>> same(100, {{1, 1, 1}});
    std::vector<std::array<int32_t, 3>> spread, pairs;
    for (int i = 0; i < 8; i++) spread.push_back({{i * 4, (i * 3) % 32, (i * 5) % 32}});
    for (int i = 0; i < 32; i++) { pairs.push_back({{i, 0, 0}}); pairs.push_back({{i, 0, 0}}); }
    auto dens = [&](const std::vector<std::array<int32_t, 3>>& v) {
      auto b = records(v); return decodeNode(so, 0, b.data(), (int64_t)b.size()).density; };
    const double d100 = dens(same), d1 = dens(spread), d2 = dens(pairs);
    char b[160]; std::snprintf(b, sizeof b, "same cell -> %.0f, 8 distinct cells -> %.0f, 2 per cell -> %.0f",
                               d100, d1, d2);
    report("D1 density = Potree occupancy (DecoderWorker.js:154)", d100 == 100 && d1 == 1 && d2 == 2, b);
  }

  std::printf("\nnegative controls (each must be caught):\n");
  {
    const size_t pre = promotionsInPreloadedFrame(oct, bin, cam, p, ref.nodes, 1 << 30, cacheBytes);
    char b[160]; std::snprintf(b, sizeof b, "unlimited promotions -> %zu in the all-loaded frame", pre);
    report("N1 A2 catches unlimited promotions", ref.nodes.size() >= 3 && pre > 2, b);
  }
  {
    const RunResult n2 = streamUntilStable(oct, bin, cam, p, ref.nodes, 2, 64, -1, cacheBytes, 20000);
    char b[160]; std::snprintf(b, sizeof b, "maxNodesLoading=64 -> max %d in flight", n2.maxInFlight);
    report("N2 A3 catches a raised loading limit", ref.nodes.size() <= 4 || n2.maxInFlight > 4, b);
  }
  {
    const int32_t victim = ref.nodes.size() > 1 ? ref.nodes.back() : -1;
    const RunResult n3 = streamUntilStable(oct, bin, cam, p, ref.nodes, 2, 4, victim, cacheBytes, 3000);
    char b[160]; std::snprintf(b, sizeof b, "node %d never loads -> final %zu vs %zu nodes",
                               victim, n3.finalNodes.size(), refSet.size());
    report("N3 A1 catches a node that never loads", victim >= 0 && n3.finalNodes != refSet, b);
  }
  {
    // A converged frame is ancestor-closed; remove the parent of its deepest node.
    std::unordered_set<int32_t> gpu(rr.finalNodes.begin(), rr.finalNodes.end());
    for (int32_t n : rr.finalNodes)
      for (int32_t a = oct.nodes[(size_t)n].parent; a >= 0; a = oct.nodes[(size_t)a].parent) gpu.insert(a);
    std::vector<int32_t> drawn(rr.finalNodes.begin(), rr.finalNodes.end());
    int32_t deepest = -1;
    for (int32_t n : drawn) if (deepest < 0 || oct.nodes[(size_t)n].level > oct.nodes[(size_t)deepest].level) deepest = n;
    const bool before = ancestorsDrawable(oct, drawn, gpu);
    if (deepest >= 0 && oct.nodes[(size_t)deepest].parent >= 0) gpu.erase(oct.nodes[(size_t)deepest].parent);
    const bool after = ancestorsDrawable(oct, drawn, gpu);
    char b[160]; std::snprintf(b, sizeof b, "intact frame ok=%d, parent removed ok=%d", (int)before, (int)after);
    report("N4 A4 catches a drawn node without its parent", before && !after, b);
  }
  {
    const auto r5 = victimAfter(true);
    char b[160]; std::snprintf(b, sizeof b, "with get(): victim %d, counters unchanged=%d", r5.first, (int)r5.second);
    report("N5 C1 tells contains() from get()", r5.first != 1 && !r5.second, b);
  }

  std::printf("\n%s (%d failure%s)\n", g_fail ? "FAILED" : "ALL PASSED", g_fail, g_fail == 1 ? "" : "s");
  return g_fail ? 1 : 0;
}
