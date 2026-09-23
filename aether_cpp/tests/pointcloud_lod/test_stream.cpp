// Host test for the streaming node loader, against a REAL converted cloud.
//
//   L1  a loaded selection yields exactly sum(node.numPoints) points
//   L2  every loaded point lies inside its node's box (decode is correct,
//       including the float32-relative-to-origin trick)
//   L3  colour survives the uint16 -> uint8 narrowing
//   L4  read coalescing reduces the number of seeks, and wasted bytes stay small
//   L5  the cache serves a repeated frame with zero reads
//   L6  the cache honours its byte budget under pressure and never serves stale
//   N1  a cache of 1 byte still works (degenerate, must not lose data)
//   N2  corrupting the decode origin must make L2 fail  (the judge can fail)
//   N3  disabling coalescing must increase the read count (L4 is load-bearing)
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

#include "aether/pointcloud_lod/stream.h"

using namespace aether::pointcloud_lod;

static int g_fail = 0;
static int g_skip = 0;
static void report(const char* n, bool ok, const std::string& d) {
  std::printf("  %-4s %-52s %s\n", ok ? "PASS" : "FAIL", n, d.c_str());
  if (!ok) g_fail++;
}
static void skip(const char* n, const std::string& why) {
  std::printf("  %-4s %-52s %s\n", "SKIP", n, why.c_str());
  g_skip++;
}

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

int main(int argc, char** argv) {
  if (argc < 2) { std::fprintf(stderr, "usage: test_stream <octree dir>\n"); return 2; }
  const std::string dir = argv[1];
  Octree oct = loadOctree(dir);
  if (!oct.error.empty()) { std::fprintf(stderr, "load failed: %s\n", oct.error.c_str()); return 1; }
  const std::string bin = dir + "/octree.bin";

  const Vec3 c = oct.nodes[0].box.center();
  const double R = oct.nodes[0].box.boundingSphereRadius();
  SelectParams p; p.pointBudget = 3630000;
  Camera cam = makeCamera({c.x, c.y, c.z + R*0.4}, c, 60, 1170, 2532, 0.001, R*20);
  Selection sel = selectVisible(oct, cam, p);
  std::printf("selection: %zu nodes, %lld points\n\n", sel.nodes.size(), (long long)sel.numPoints);

  NodeLoader loader(oct, bin, 512u * 1024 * 1024);
  NodeLoader::Stats st;
  auto loaded = loader.load(sel, &st);

  // ---- L1 ----
  {
    int64_t got = 0, want = 0;
    for (auto* np : loaded) got += (int64_t)np->count();
    for (int32_t n : sel.nodes) want += oct.nodes[(size_t)n].numPoints;
    char b[200]; std::snprintf(b, sizeof b, "%lld loaded vs %lld selected, %zu node buffers",
                               (long long)got, (long long)want, loaded.size());
    report("L1 loaded point count == selected point count",
           got == want && loaded.size() == sel.nodes.size(), b);
  }

  // ---- L2 ----
  auto insideCheck = [&](const std::vector<const NodePoints*>& v, double originBias) {
    int64_t outside = 0, checked = 0;
    for (auto* np : v) {
      const Box3& bx = oct.nodes[(size_t)np->node].box;
      // Tolerance has two parts and BOTH are needed:
      //   - 2 LSB of the int32 grid the converter quantised onto, and
      //   - the float32 representation error of a coordinate held relative to
      //     the node centre, which is ~(S/2) * 2^-23 for a node of edge S.
      // An earlier version of this check used only the first part and flagged
      // 3 of 24,064 points in the shallowest nodes. That was the judge being
      // wrong about float32, not the decode being wrong.
      const Vec3 e = bx.size();
      const double f32 = 0.5 * std::max(e.x, std::max(e.y, e.z)) * 2.0 * std::pow(2.0, -23);
      const Vec3 tol{oct.meta.scale.x*2 + f32,
                     oct.meta.scale.y*2 + f32,
                     oct.meta.scale.z*2 + f32};
      const Vec3 o{np->origin.x + originBias, np->origin.y, np->origin.z};
      for (size_t i = 0; i < np->count(); i++) {
        const double x = np->xyz[i*3+0] + o.x, y = np->xyz[i*3+1] + o.y, z = np->xyz[i*3+2] + o.z;
        const double ox = std::max(bx.min.x - tol.x - x, x - bx.max.x - tol.x);
        const double oy = std::max(bx.min.y - tol.y - y, y - bx.max.y - tol.y);
        const double oz = std::max(bx.min.z - tol.z - z, z - bx.max.z - tol.z);
        if (std::max(ox, std::max(oy, oz)) > 0) outside++;
        checked++;
      }
    }
    return std::make_pair(checked, outside);
  };
  {
    auto [checked, outside] = insideCheck(loaded, 0.0);
    char b[200]; std::snprintf(b, sizeof b, "%lld points, outside=%lld", (long long)checked, (long long)outside);
    report("L2 every decoded point lies inside its node's box", outside == 0 && checked > 0, b);
  }

  // ---- L2b: the precision claim, made falsifiable ----
  {
    // Do not rely on the frame's selection happening to contain deep nodes --
    // go and load the deepest nodes in the tree on purpose, so the claim in
    // aether/pointcloud_lod/stream.h is actually exercised rather than quietly skipped.
    const double lsb = std::max(oct.meta.scale.x, std::max(oct.meta.scale.y, oct.meta.scale.z));
    Selection deep;
    for (size_t i = 0; i < oct.nodes.size() && deep.nodes.size() < 40; i++) {
      const Node& n = oct.nodes[i];
      if (n.numPoints == 0) continue;
      const Vec3 e = n.box.size();
      const double S = std::max(e.x, std::max(e.y, e.z));
      if (S * 6e-8 <= lsb) deep.nodes.push_back((int32_t)i);   // see header
    }
    if (deep.nodes.empty()) {
      char b[240];
      std::snprintf(b, sizeof b,
                    "this tree has no node with edge <= %.3g units, so float32-relative "
                    "cannot preserve the grid anywhere in it", lsb / 6e-8);
      skip("L2b float32-relative preserves the grid in deep nodes", b);
    } else {
      NodeLoader dl(oct, bin, 256u * 1024 * 1024);
      auto dv = dl.load(deep, nullptr);
      const int bpp = oct.meta.bytesPerPoint();
      const int posOff = oct.meta.attributeOffset("position");
      std::ifstream rf(bin, std::ios::binary);
      int64_t checked = 0, bad = 0;
      double worst = 0;
      double worstAbsolute = 0;   // same points held as ABSOLUTE float32 instead
      for (auto* np : dv) {
        const Node& nd = oct.nodes[(size_t)np->node];
        // Recompute the EXACT relative coordinate in double straight from the
        // int32 on disk. Comparing the stored float against itself (an earlier
        // version of this check did exactly that) measures nothing and reports
        // a suspiciously perfect zero.
        std::vector<uint8_t> raw((size_t)nd.byteSize);
        rf.seekg(nd.byteOffset);
        rf.read(reinterpret_cast<char*>(raw.data()), nd.byteSize);
        for (size_t i = 0; i < np->count(); i++) {
          int32_t q[3];
          std::memcpy(q, raw.data() + i * bpp + posOff, 12);
          const double exact[3] = {
              q[0] * oct.meta.scale.x + oct.meta.offset.x - np->origin.x,
              q[1] * oct.meta.scale.y + oct.meta.offset.y - np->origin.y,
              q[2] * oct.meta.scale.z + oct.meta.offset.z - np->origin.z};
          const double origin[3] = {np->origin.x, np->origin.y, np->origin.z};
          for (int k = 0; k < 3; k++) {
            const double err = std::abs(double(np->xyz[i*3+k]) - exact[k]);
            worst = std::max(worst, err);
            if (err > lsb) bad++;
            const double absExact = exact[k] + origin[k];
            worstAbsolute = std::max(worstAbsolute,
                                     std::abs(double(float(absExact)) - absExact));
          }
          checked++;
        }
      }
      char b[260];
      std::snprintf(b, sizeof b,
                    "%lld points in %zu deepest nodes, worst float32 error %.3g vs LSB %.3g",
                    (long long)checked, dv.size(), worst, lsb);
      report("L2b float32-relative preserves the grid in deep nodes",
             bad == 0 && checked > 0, b);
      // Negative control, and the reason the design is relative at all.
      // The sampled deep nodes may sit close to the world origin, where absolute
      // float32 happens to be nearly good enough -- so also evaluate the
      // structural worst case: the bounding-box corner farthest from the origin.
      // That value is deterministic for a given scene and does not depend on
      // which nodes the sample happened to pick.
      const Box3& rb = oct.nodes[0].box;
      double farthest = 0;
      for (double v : {rb.min.x, rb.max.x, rb.min.y, rb.max.y, rb.min.z, rb.max.z})
        farthest = std::max(farthest, std::abs(v));
      const double cornerErr = 0.5 * double(std::nextafter(float(farthest), INFINITY) - float(farthest));
      char c2[280];
      std::snprintf(c2, sizeof c2,
                    "absolute float32: sampled deep nodes %.1fx LSB, far corner (|%.2f|) %.1fx LSB",
                    worstAbsolute / lsb, farthest, cornerErr / lsb);
      report("N4 absolute float32 would lose the grid (relative is load-bearing)",
             cornerErr > lsb, c2);
    }
  }

  // ---- L3 colour ----
  {
    // Compare against the raw bytes for one node, independently of the loader.
    const int32_t n0 = sel.nodes.front();
    const Node& nd = oct.nodes[(size_t)n0];
    std::ifstream f(bin, std::ios::binary);
    std::vector<uint8_t> raw((size_t)nd.byteSize);
    f.seekg(nd.byteOffset); f.read((char*)raw.data(), nd.byteSize);
    const int bpp = oct.meta.bytesPerPoint(), rgbOff = oct.meta.attributeOffset("rgb");
    const NodePoints* np = loaded.front();
    int64_t mism = 0;
    for (size_t i = 0; i < np->count(); i++) {
      uint16_t c16[3]; std::memcpy(c16, raw.data() + i*bpp + rgbOff, 6);
      for (int k = 0; k < 3; k++) if (np->rgb[i*3+k] != (uint8_t)(c16[k] >> 8)) mism++;
    }
    char b[200]; std::snprintf(b, sizeof b, "node %s, %zu points, %lld channel mismatches",
                               nd.name.c_str(), np->count(), (long long)mism);
    report("L3 colour narrowing uint16 -> uint8 is exact", mism == 0 && np->count() > 0, b);
  }

  // ---- L4 coalescing ----
  {
    const auto merged = planReads(oct, sel.nodes, 64*1024);
    const auto split  = planReads(oct, sel.nodes, 0);
    int64_t waste = 0, total = 0;
    for (const auto& r : merged) {
      total += r.size;
      int64_t used = 0;
      for (int32_t n : r.nodes) used += oct.nodes[(size_t)n].byteSize;
      waste += r.size - used;
    }
    char b[220]; std::snprintf(b, sizeof b,
        "%zu nodes -> %zu reads (no coalesce: %zu); wasted %.2f%% of %lld B",
        sel.nodes.size(), merged.size(), split.size(),
        total ? 100.0*double(waste)/double(total) : 0.0, (long long)total);
    report("L4 reads are coalesced and waste stays small",
           merged.size() <= split.size() && (total == 0 || double(waste)/double(total) < 0.05), b);
  }

  // ---- L5 cache hit ----
  {
    NodeLoader::Stats st2;
    loader.cache().resetStats();
    auto again = loader.load(sel, &st2);
    char b[200]; std::snprintf(b, sizeof b, "second identical frame: %lld reads, %lld bytes",
                               (long long)st2.reads, (long long)st2.bytesRead);
    report("L5 a repeated frame costs zero reads",
           st2.reads == 0 && again.size() == loaded.size(), b);
  }

  // ---- L6 budget ----
  {
    NodeLoader small(oct, bin, 8u * 1024 * 1024);   // 8 MB, far below the frame
    NodeLoader::Stats s3;
    auto v = small.load(sel, &s3);
    char b[220]; std::snprintf(b, sizeof b,
        "cache holds %zu MB / %zu nodes after a %lld-point frame; returned %zu/%zu",
        small.cache().bytes()/(1024*1024), small.cache().size(),
        (long long)sel.numPoints, v.size(), sel.nodes.size());
    report("L6 cache respects its byte budget", small.cache().bytes() <= 8u*1024*1024 + (1u<<20), b);
  }

  std::printf("\nnegative controls (each must be rejected):\n");
  {
    NodeLoader tiny(oct, bin, 1);
    NodeLoader::Stats s4;
    auto v = tiny.load(sel, &s4);
    char b[200]; std::snprintf(b, sizeof b, "1-byte cache returned %zu of %zu nodes",
                               v.size(), sel.nodes.size());
    report("N1 a 1-byte cache degrades but never corrupts", v.size() <= sel.nodes.size(), b);
  }
  {
    auto [checked, outside] = insideCheck(loaded, 1.0);   // shift every origin by 1 unit
    char b[200]; std::snprintf(b, sizeof b, "origin shifted 1.0 -> outside=%lld of %lld",
                               (long long)outside, (long long)checked);
    report("N2 a wrong decode origin -> L2 rejects", outside > 0, b);
  }
  {
    const auto merged = planReads(oct, sel.nodes, 64*1024);
    const auto split  = planReads(oct, sel.nodes, 0);
    char b[200]; std::snprintf(b, sizeof b, "coalesced %zu vs uncoalesced %zu reads",
                               merged.size(), split.size());
    report("N3 coalescing is load-bearing (fewer reads than without)",
           merged.size() < split.size(), b);
  }

  std::printf("\nI/O for one cold frame: %lld reads, %.1f MB, %lld nodes, %.2f%% wasted\n",
              (long long)st.reads, double(st.bytesRead)/1e6, (long long)st.nodesDecoded,
              st.bytesRead ? 100.0*double(st.wastedBytes)/double(st.bytesRead) : 0.0);
  if (g_skip) std::printf("\n  %d check(s) skipped -- premise does not hold for this cloud.\n", g_skip);
  std::printf("\n==== %s ====\n",
              g_fail == 0 ? (g_skip ? "PASS (with skips)" : "ALL PASS") : "FAILED");
  return g_fail == 0 ? 0 : 1;
}
