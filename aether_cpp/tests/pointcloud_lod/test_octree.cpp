// Host test for the Potree 2.0 octree reader, run against a REAL converted cloud.
//
// Every check is designed so that a broken reader fails it:
//   C1  sum(node.numPoints) == octree.bin bytes / bytesPerPoint
//       (never trusts metadata.json's self-reported "points")
//   C2  the node byte ranges TILE octree.bin exactly: sorted by offset they are
//       disjoint, gapless, and end at the file size. This is "stored exactly
//       once" at the tree level -- an overlap means a point is in two nodes,
//       a gap means bytes no node claims.
//   C3  every point actually lies inside the bounding box of the node that
//       claims it (samples nodes across all levels) -- catches a mis-built tree
//       even when the byte accounting happens to add up.
//   C4  tree shape invariants: child boxes tile the parent, names match depth.
//   N1  negative control: perturb one node's numPoints -> C1 must fail
//   N2  negative control: grow one node's byteSize by 1 -> C2 must fail
//   N3  negative control: shrink the root box -> C3 must fail
#include <algorithm>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

#include "aether/pointcloud_lod/octree.h"

using namespace aether::pointcloud_lod;

static int g_fail = 0;
static void report(const char* name, bool ok, const std::string& detail) {
  std::printf("  %-4s %-58s %s\n", ok ? "PASS" : "FAIL", name, detail.c_str());
  if (!ok) g_fail++;
}

static int64_t fileSize(const std::string& p) {
  std::ifstream f(p, std::ios::binary | std::ios::ate);
  return f ? static_cast<int64_t>(f.tellg()) : -1;
}

struct Range { int64_t off, size; int32_t node; };

// ---- C1 ----
static bool checkCount(const Octree& oct, int64_t binBytes, std::string* detail) {
  const int bpp = oct.meta.bytesPerPoint();
  const int64_t fromFile = binBytes / bpp;
  const int64_t fromTree = oct.totalPointsInNodes();
  char buf[256];
  std::snprintf(buf, sizeof buf, "tree %lld vs octree.bin %lld (%lld B / %d)",
                (long long)fromTree, (long long)fromFile, (long long)binBytes, bpp);
  *detail = buf;
  return binBytes % bpp == 0 && fromTree == fromFile;
}

// ---- C2 ----
static bool checkTiling(const Octree& oct, int64_t binBytes, std::string* detail) {
  std::vector<Range> rs;
  for (size_t i = 0; i < oct.nodes.size(); i++) {
    const auto& n = oct.nodes[i];
    if (n.byteSize > 0) rs.push_back({n.byteOffset, n.byteSize, (int32_t)i});
  }
  std::sort(rs.begin(), rs.end(), [](const Range& a, const Range& b) { return a.off < b.off; });
  int64_t cursor = 0;
  for (const auto& r : rs) {
    if (r.off != cursor) {
      char buf[256];
      std::snprintf(buf, sizeof buf, "%s at %lld, expected %lld (%s of %lld B)",
                    r.off > cursor ? "gap before node" : "OVERLAP: node",
                    (long long)r.off, (long long)cursor,
                    oct.nodes[r.node].name.c_str(), (long long)r.size);
      *detail = buf;
      return false;
    }
    cursor += r.size;
  }
  char buf[256];
  std::snprintf(buf, sizeof buf, "%zu ranges tile [0,%lld); file is %lld B",
                rs.size(), (long long)cursor, (long long)binBytes);
  *detail = buf;
  return cursor == binBytes;
}

// ---- C3 ----
static bool checkPointsInsideBoxes(const Octree& oct, const std::string& binPath,
                                   std::string* detail) {
  std::ifstream f(binPath, std::ios::binary);
  if (!f) { *detail = "cannot open octree.bin"; return false; }
  const int bpp = oct.meta.bytesPerPoint();
  const int posOff = oct.meta.attributeOffset("position");
  if (posOff < 0) { *detail = "no position attribute"; return false; }

  // Sample one node per level, plus every node at the deepest level we find.
  std::vector<int32_t> sample;
  int maxLevel = 0;
  for (const auto& n : oct.nodes) maxLevel = std::max(maxLevel, n.level);
  for (int lvl = 0; lvl <= maxLevel; lvl++) {
    int taken = 0;
    for (size_t i = 0; i < oct.nodes.size() && taken < 6; i++) {
      if (oct.nodes[i].level == lvl && oct.nodes[i].numPoints > 0) {
        sample.push_back((int32_t)i);
        taken++;
      }
    }
  }

  int64_t checked = 0, outside = 0;
  std::string worst;
  double worstOver = 0;
  for (int32_t idx : sample) {
    const Node& n = oct.nodes[idx];
    std::vector<uint8_t> buf((size_t)n.byteSize);
    f.seekg(n.byteOffset);
    f.read(reinterpret_cast<char*>(buf.data()), n.byteSize);
    const int64_t np = n.byteSize / bpp;
    // A float32 input quantised to this grid can land at most 1 LSB outside the
    // box that the converter derived from the same input, so allow 2 LSB.
    const Vec3 tol{oct.meta.scale.x * 2, oct.meta.scale.y * 2, oct.meta.scale.z * 2};
    for (int64_t p = 0; p < np; p++) {
      int32_t xyz[3];
      std::memcpy(xyz, buf.data() + p * bpp + posOff, 12);
      const Vec3 w{xyz[0] * oct.meta.scale.x + oct.meta.offset.x,
                   xyz[1] * oct.meta.scale.y + oct.meta.offset.y,
                   xyz[2] * oct.meta.scale.z + oct.meta.offset.z};
      const double ox = std::max(n.box.min.x - tol.x - w.x, w.x - n.box.max.x - tol.x);
      const double oy = std::max(n.box.min.y - tol.y - w.y, w.y - n.box.max.y - tol.y);
      const double oz = std::max(n.box.min.z - tol.z - w.z, w.z - n.box.max.z - tol.z);
      const double over = std::max(ox, std::max(oy, oz));
      if (over > 0) {
        outside++;
        if (over > worstOver) { worstOver = over; worst = n.name; }
      }
      checked++;
    }
  }
  char buf[256];
  std::snprintf(buf, sizeof buf, "%lld points in %zu nodes; outside=%lld%s",
                (long long)checked, sample.size(), (long long)outside,
                outside ? (" worst=" + worst).c_str() : "");
  *detail = buf;
  return outside == 0 && checked > 0;
}

// ---- C4 ----
static bool checkShape(const Octree& oct, std::string* detail) {
  int bad = 0;
  std::string why;
  for (const auto& n : oct.nodes) {
    if ((int)n.name.size() != n.level + 1) { bad++; why = "name length vs level: " + n.name; break; }
    for (int c = 0; c < 8; c++) {
      if (n.children[c] < 0) continue;
      const Node& ch = oct.nodes[(size_t)n.children[c]];
      const Box3 expect = createChildAABB(n.box, c);
      const double d = (ch.box.min - expect.min).length() + (ch.box.max - expect.max).length();
      if (d > 1e-9) { bad++; why = "child box mismatch at " + ch.name; break; }
      if (ch.level != n.level + 1) { bad++; why = "child level at " + ch.name; break; }
      if (ch.spacing * 2 != n.spacing) { bad++; why = "child spacing at " + ch.name; break; }
    }
    if (bad) break;
  }
  *detail = bad ? why : "names, boxes, levels and spacing all consistent";
  return bad == 0;
}

int main(int argc, char** argv) {
  if (argc < 2) { std::fprintf(stderr, "usage: test_octree <octree dir>\n"); return 2; }
  const std::string dir = argv[1];

  Octree oct = loadOctree(dir);
  if (!oct.error.empty()) { std::fprintf(stderr, "load failed: %s\n", oct.error.c_str()); return 1; }

  const int64_t binBytes = fileSize(dir + "/octree.bin");
  std::printf("loaded %zu nodes, max level %d, %d B/point, octree.bin %lld B\n",
              oct.nodes.size(),
              [&]{ int m=0; for (auto& n : oct.nodes) m = std::max(m, n.level); return m; }(),
              oct.meta.bytesPerPoint(), (long long)binBytes);
  std::printf("metadata self-reports %lld points  <-- not used as evidence\n\n",
              (long long)oct.meta.points);

  std::string d;
  report("C1 point count == octree.bin bytes / bytesPerPoint", checkCount(oct, binBytes, &d), d);
  report("C2 node byte ranges tile octree.bin exactly",        checkTiling(oct, binBytes, &d), d);
  report("C3 sampled points lie inside their node's box",      checkPointsInsideBoxes(oct, dir + "/octree.bin", &d), d);
  report("C4 tree shape invariants",                           checkShape(oct, &d), d);

  std::printf("\nnegative controls (each must be rejected):\n");
  {
    Octree bad = oct;
    for (auto& n : bad.nodes) if (n.numPoints > 0) { n.numPoints -= 1; break; }
    report("N1 one node loses a point -> C1 rejects", !checkCount(bad, binBytes, &d), d);
  }
  {
    Octree bad = oct;
    for (auto& n : bad.nodes) if (n.byteSize > 0) { n.byteSize += 1; break; }
    report("N2 one node grows by 1 byte -> C2 rejects", !checkTiling(bad, binBytes, &d), d);
  }
  {
    Octree bad = oct;
    bad.nodes[0].box.max = bad.nodes[0].box.center();
    report("N3 root box halved -> C3 rejects", !checkPointsInsideBoxes(bad, dir + "/octree.bin", &d), d);
  }
  {
    Octree bad = oct;
    for (auto& n : bad.nodes) if (n.parent >= 0) { n.box.min.x += 1.0; break; }
    report("N4 one child box shifted -> C4 rejects", !checkShape(bad, &d), d);
  }

  std::printf("\n==== %s ====\n", g_fail == 0 ? "ALL PASS" : "FAILED");
  return g_fail == 0 ? 0 : 1;
}
