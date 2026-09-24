// Host test for the on-device octree builder, against the committed 25,000-point
// fixture (tests/pointcloud_lod/fixture: source.ply + the octree the DESKTOP
// PotreeConverter @8bfad98 built from it through tools/pointcloud_lod/ply2las.py).
//
//   test_pointcloud_lod_build <fixture dir> <scratch dir>
//
// Every check can fail, and each has a negative control that must be rejected:
//   E1  port vs desktop, same input (ply2las.py values rebuilt in memory):
//       node-name set, per-node count, per-node MULTISET of 18-byte records,
//       metadata.json text (except "name")
//   E2  1 thread + a 4 KiB octree ring (forces the write-through path and
//       wrap-around): still identical to the desktop tree
//   L1  product path (PLY): count = octree.bin bytes / 18 == input count
//   L2  per-axis sorted positions within 2 LSB of the float32 input
//   L3  per-channel colour histograms identical (8-bit input, 16-bit v*257 output)
//   B1  bad inputs return an error instead of aborting (a crash fails the test);
//       positive control: the valid fixture still builds
// Checks whose premise does not hold on this data report SKIP with the reason.
//
// The product-path output is left in <scratch dir>/ply so that the reader's own
// tests (test_pointcloud_lod_octree / _select / _stream) run against it next.
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <map>
#include <string>
#include <vector>

#include "aether/pointcloud_lod/octree.h"
#include "aether/pointcloud_lod_build/build.h"
#include "las_source.h"

namespace fs = std::filesystem;
namespace plb = aether::pointcloud_lod_build;

static int g_fail = 0;
static void report(const char* name, bool ok, const std::string& detail) {
  std::printf("  %-4s %-62s %s\n", ok ? "PASS" : "FAIL", name, detail.c_str());
  if (!ok) g_fail++;
}
static void skip(const char* name, const std::string& why) { std::printf("  %-4s %-62s %s\n", "SKIP", name, why.c_str()); }

static std::vector<uint8_t> readAll(const std::string& p) {
  std::ifstream f(p, std::ios::binary | std::ios::ate);
  if (!f) return {};
  std::vector<uint8_t> b(size_t(f.tellg()));
  f.seekg(0);
  f.read(reinterpret_cast<char*>(b.data()), std::streamsize(b.size()));
  return b;
}

// ---------------------------------------------------------------------------
// A tree = node name -> sorted list of its 18-byte records. Parsed exactly like
// potree OctreeLoader.js:151-232 (independent of the library under test).
using Record = std::array<uint8_t, 18>;
struct TreeNode { uint32_t numPoints = 0; std::vector<Record> records; };
using Tree = std::map<std::string, TreeNode>;

static bool loadTree(const std::string& dir, Tree* tree, std::string* why) {
  auto H = readAll(dir + "/hierarchy.bin");
  auto O = readAll(dir + "/octree.bin");
  std::string meta;
  { std::ifstream f(dir + "/metadata.json"); meta.assign(std::istreambuf_iterator<char>(f), {}); }
  auto k = meta.find("\"firstChunkSize\": ");
  if (H.empty() || k == std::string::npos) { *why = "missing files in " + dir; return false; }
  int64_t first = std::atoll(meta.c_str() + k + 18);
  struct Pending { std::string name; uint64_t off, size; };
  std::vector<Pending> pending = {{"r", 0, uint64_t(first)}};
  while (!pending.empty()) {
    Pending p = pending.back();
    pending.pop_back();
    if (p.size % 22 || p.off + p.size > H.size()) { *why = "bad hierarchy chunk"; return false; }
    std::vector<std::string> order = {p.name};
    for (size_t i = 0; i < p.size / 22; i++) {
      if (i >= order.size()) { *why = "hierarchy chunk longer than its node list"; return false; }
      const uint8_t* r = H.data() + p.off + 22 * i;
      uint8_t type = r[0], mask = r[1];
      uint32_t n; uint64_t bo, bs;
      std::memcpy(&n, r + 2, 4); std::memcpy(&bo, r + 6, 8); std::memcpy(&bs, r + 14, 8);
      const std::string cur = order[i];
      if (type == 2) { pending.push_back({cur, bo, bs}); continue; }
      if (tree->count(cur)) { *why = "duplicate node " + cur; return false; }
      if (bs % 18 || bo + bs > O.size()) { *why = "node range outside octree.bin: " + cur; return false; }
      TreeNode tn;
      tn.numPoints = n;
      for (uint64_t j = 0; j < bs / 18; j++) { Record rec; std::memcpy(rec.data(), O.data() + bo + 18 * j, 18); tn.records.push_back(rec); }
      std::sort(tn.records.begin(), tn.records.end());
      (*tree)[cur] = std::move(tn);
      for (int c = 0; c < 8; c++) if (mask & (1 << c)) order.push_back(cur + char('0' + c));
    }
  }
  return true;
}

static bool sameTree(const Tree& a, const Tree& b, std::string* detail) {
  int64_t onlyA = 0, onlyB = 0, countDiff = 0, setDiff = 0;
  for (auto& [name, n] : a) {
    auto it = b.find(name);
    if (it == b.end()) { onlyA++; continue; }
    if (n.numPoints != it->second.numPoints || n.records.size() != it->second.records.size()) countDiff++;
    else if (n.records != it->second.records) setDiff++;
  }
  for (auto& [name, n] : b) if (!a.count(name)) onlyB++;
  *detail = std::to_string(a.size()) + " vs " + std::to_string(b.size()) + " nodes; only-left " + std::to_string(onlyA) +
            ", only-right " + std::to_string(onlyB) + ", count diff " + std::to_string(countDiff) +
            ", multiset diff " + std::to_string(setDiff);
  return onlyA == 0 && onlyB == 0 && countDiff == 0 && setDiff == 0;
}

static std::string metadataWithoutName(const std::string& dir) {
  std::ifstream f(dir + "/metadata.json");
  std::string line, out;
  while (std::getline(f, line)) {
    if (line.rfind("\t\"name\": ", 0) == 0) continue;  // top-level "name" only (attributes are deeper)
    out += line + "\n";
  }
  return out;
}

// ---------------------------------------------------------------------------
// Lossless checks against the PLY (L1-L3)
struct Ply { std::vector<float> xyz; std::vector<uint8_t> rgb; };
static Ply readPly(const std::string& p) {
  auto b = readAll(p);
  std::string s(b.begin(), b.end());
  size_t h = s.find("end_header\n") + 11;
  int64_t n = std::atoll(s.c_str() + s.find("element vertex ") + 15);
  Ply ply;
  ply.xyz.resize(size_t(3 * n)); ply.rgb.resize(size_t(3 * n));
  for (int64_t i = 0; i < n; i++) {
    std::memcpy(&ply.xyz[size_t(3 * i)], b.data() + h + 15 * i, 12);
    std::memcpy(&ply.rgb[size_t(3 * i)], b.data() + h + 15 * i + 12, 3);
  }
  return ply;
}

struct Decoded { std::vector<double> xyz; std::vector<uint16_t> rgb; double scale[3]; };
static Decoded decode(const std::vector<uint8_t>& octree, const aether::pointcloud_lod::Metadata& m) {
  Decoded d;
  d.scale[0] = m.scale.x; d.scale[1] = m.scale.y; d.scale[2] = m.scale.z;
  const double off[3] = {m.offset.x, m.offset.y, m.offset.z};
  size_t n = octree.size() / 18;
  d.xyz.resize(3 * n); d.rgb.resize(3 * n);
  for (size_t i = 0; i < n; i++) {
    int32_t X[3]; std::memcpy(X, octree.data() + 18 * i, 12);
    for (int a = 0; a < 3; a++) d.xyz[3 * i + size_t(a)] = X[a] * d.scale[a] + off[a];
    std::memcpy(&d.rgb[3 * i], octree.data() + 18 * i + 12, 6);
  }
  return d;
}

static bool positionsWithin(const Ply& in, const Decoded& out, double tolLsb, double* worst) {
  *worst = 0;
  size_t n = in.xyz.size() / 3;
  if (out.xyz.size() != in.xyz.size()) { *worst = INFINITY; return false; }
  for (int a = 0; a < 3; a++) {
    std::vector<double> A(n), B(n);
    for (size_t i = 0; i < n; i++) { A[i] = double(in.xyz[3 * i + size_t(a)]); B[i] = out.xyz[3 * i + size_t(a)]; }
    std::sort(A.begin(), A.end()); std::sort(B.begin(), B.end());
    for (size_t i = 0; i < n; i++) *worst = std::max(*worst, std::fabs(A[i] - B[i]) / out.scale[a]);
  }
  return *worst <= tolLsb;
}

static bool coloursIdentical(const Ply& in, const Decoded& out, std::string* detail) {
  if (in.rgb.size() != out.rgb.size()) { *detail = "count differs"; return false; }
  for (int c = 0; c < 3; c++) {
    std::array<int64_t, 256> hi{}, ho{};
    for (size_t i = 0; i < in.rgb.size() / 3; i++) {
      hi[in.rgb[3 * i + size_t(c)]]++;
      uint16_t v = out.rgb[3 * i + size_t(c)];
      if (v % 257) { *detail = "16-bit value not a v*257"; return false; }
      ho[v / 257]++;
    }
    if (hi != ho) { *detail = std::string("channel ") + "rgb"[c] + " histogram differs"; return false; }
  }
  *detail = "all 3 channels, 256 bins each, identical";
  return true;
}

// ---------------------------------------------------------------------------
static void writeFile(const std::string& p, const std::string& s) { std::ofstream(p, std::ios::binary) << s; }

int main(int argc, char** argv) {
  if (argc < 3) { std::fprintf(stderr, "usage: %s <fixture dir> <scratch dir>\n", argv[0]); return 2; }
  const std::string fx = argv[1];
  const std::string scratch = argv[2];
  std::error_code ec;
  fs::remove_all(scratch, ec);
  fs::create_directories(scratch, ec);

  Tree desktop;
  std::string why;
  if (!loadTree(fx, &desktop, &why)) { std::fprintf(stderr, "cannot load desktop fixture: %s\n", why.c_str()); return 1; }
  std::printf("desktop fixture: %zu nodes\n\n", desktop.size());

  // ---- E1 -----------------------------------------------------------------
  std::string err;
  auto vlas = pwlod_test::VirtualLasFromPly::open(fx + "/source.ply", &err);
  if (!vlas) { std::fprintf(stderr, "virtual LAS: %s\n", err.c_str()); return 1; }
  plb::BuildOptions o;
  o.outDir = scratch + "/vlas";
  o.chunkDir = scratch + "/vlas_chunks";
  o.name = "fixture";
  auto r1 = plb::build(*vlas, o);
  Tree port;
  std::string d;
  if (!r1.ok || !loadTree(o.outDir, &port, &why)) {
    report("E1 port == desktop, node by node", false, r1.ok ? why : r1.error);
  } else if (desktop.size() < 50) {
    skip("E1 port == desktop, node by node", "premise: fixture tree has < 50 nodes");
  } else {
    const bool e1 = sameTree(desktop, port, &d);  // evaluate before reading d (argument order is unspecified)
    report("E1 port == desktop, node by node", e1, d);
    report("E1 metadata.json identical except \"name\"", metadataWithoutName(fx) == metadataWithoutName(o.outDir),
           "compared line by line");
    // negative controls on the comparator itself
    Tree moved = port;
    std::vector<std::string> bySize;
    for (auto& [name, n] : moved) bySize.push_back(name);
    std::sort(bySize.begin(), bySize.end(), [&](const std::string& x, const std::string& y) {
      return moved[x].records.size() > moved[y].records.size();
    });
    auto& big = moved[bySize[0]].records;
    auto& second = moved[bySize[1]].records;
    second[0] = big[0];  // count-preserving: node 2 loses one of its points, gains one of node 1's
    std::sort(second.begin(), second.end());
    const bool n1 = !sameTree(desktop, moved, &d);
    report("E1-neg one record overwritten by another node's -> rejected", n1, d);
    Tree dropped = port;
    dropped.erase(std::prev(dropped.end()));
    const bool n2 = !sameTree(desktop, dropped, &d);
    report("E1-neg one node removed -> rejected", n2, d);
  }

  // ---- E2 -----------------------------------------------------------------
  // 1 thread (deterministic order) + a 4 KiB octree ring: nodes larger than the
  // ring take the write-through path (D4), smaller ones wrap around the ring.
  {
    plb::BuildOptions t = o;
    t.outDir = scratch + "/vlas_t1";
    t.chunkDir = scratch + "/vlas_t1_chunks";
    t.numThreads = 1;
    t.writerRingBytes = 4096;
    t.chunkBacklogMB = 1;
    size_t biggest = 0, total = 0;
    for (auto& [name, n] : desktop) {
      biggest = std::max(biggest, n.records.size() * 18);
      total += n.records.size() * 18;
    }
    if (biggest <= size_t(t.writerRingBytes) || total <= size_t(t.writerRingBytes)) {
      skip("E2 1 thread + 4 KiB ring == desktop", "premise: no node larger than the ring");
    } else {
      auto r2 = plb::build(*vlas, t);
      Tree p2;
      if (!r2.ok || !loadTree(t.outDir, &p2, &why)) {
        report("E2 1 thread + 4 KiB ring == desktop", false, r2.ok ? why : r2.error);
      } else {
        const bool e2 = sameTree(desktop, p2, &d);
        report("E2 1 thread + 4 KiB ring == desktop", e2,
               d + "; biggest node " + std::to_string(biggest) + " B > ring 4096 B");
      }
    }
    // The chunk-size cap (D4) cannot bind here: upstream's own N/20 = 1,250 is
    // already below the cap's 10,000 floor. Its neutrality is measured on the
    // 36M and 216M clouds instead (DEVIATIONS.md D4).
    t.maxPointsPerChunkCap = 100;
    t.outDir = scratch + "/vlas_cap";
    t.chunkDir = scratch + "/vlas_cap_chunks";
    auto r3 = plb::build(*vlas, t);
    if (r3.ok && r3.report.maxPointsPerChunk == r1.report.maxPointsPerChunk) {
      skip("E2 chunk-size cap is output-neutral", "premise: N/20 = " + std::to_string(r1.report.maxPointsPerChunk) +
                                                        " < 10,000 floor, the cap cannot bind on this fixture");
    } else {
      report("E2 chunk-size cap never goes below the 10,000 floor", false,
             r3.ok ? "cap 100 changed maxPointsPerChunk to " + std::to_string(r3.report.maxPointsPerChunk) : r3.error);
    }
  }

  // ---- L1-L3 --------------------------------------------------------------
  {
    plb::BuildOptions p = o;
    p.outDir = scratch + "/ply";
    p.chunkDir = scratch + "/ply_chunks";
    auto r3 = plb::buildFromPly(fx + "/source.ply", p);
    Ply in = readPly(fx + "/source.ply");
    const size_t nIn = in.xyz.size() / 3;
    auto oct = aether::pointcloud_lod::loadOctree(p.outDir);
    if (!r3.ok || !oct.error.empty()) {
      report("L1 octree.bin bytes / 18 == input count", false, r3.ok ? oct.error : r3.error);
    } else {
      auto bytes = readAll(p.outDir + "/octree.bin");
      bool l1 = bytes.size() % 18 == 0 && bytes.size() / 18 == nIn;
      report("L1 octree.bin bytes / 18 == input count", l1,
             std::to_string(bytes.size()) + " B / 18 = " + std::to_string(bytes.size() / 18) + ", input " + std::to_string(nIn));
      Decoded out = decode(bytes, oct.meta);
      double worst;
      bool l2 = positionsWithin(in, out, 2.0, &worst);
      char buf[128];
      std::snprintf(buf, sizeof buf, "worst %.3f LSB (tolerance 2)", worst);
      report("L2 per-axis sorted positions within 2 LSB", l2, buf);
      const bool l3 = coloursIdentical(in, out, &d);
      report("L3 colour histograms identical", l3, d);

      std::printf("\n  negative controls (each must be rejected):\n");
      Decoded c = out;  // drop one, duplicate another: count unchanged
      const size_t victim = 12345 % (c.xyz.size() / 3);
      for (int a = 0; a < 3; a++) c.xyz[3 * victim + size_t(a)] = c.xyz[size_t(a)];
      report("L2-neg drop one + duplicate one (count kept) -> rejected", !positionsWithin(in, c, 2.0, &worst), "");
      Decoded s = out;
      s.xyz[3 * 777] += 100 * s.scale[0];
      report("L2-neg one point moved 100 LSB -> rejected", !positionsWithin(in, s, 2.0, &worst), "");
      Decoded col = out;
      col.rgb[0] = uint16_t(col.rgb[0] == 0 ? 257 : col.rgb[0] - 257);
      const bool n5 = !coloursIdentical(in, col, &d);
      report("L3-neg one red value changed -> rejected", n5, d);
      std::printf("\n");
    }
  }

  // ---- B1 -----------------------------------------------------------------
  {
    const std::string hdr = "ply\nformat binary_little_endian 1.0\nelement vertex 2\nproperty float x\nproperty float y\n"
                            "property float z\nproperty uchar red\nproperty uchar green\nproperty uchar blue\nend_header\n";
    auto pt = [](float x, float y, float z) {
      std::string s(15, '\0');
      float v[3] = {x, y, z};
      std::memcpy(s.data(), v, 12);
      return s;
    };
    const std::string two = pt(0, 0, 0) + pt(1, 1, 1);
    auto withCount = [&](const std::string& n) {
      std::string h = hdr;
      h.replace(h.find("vertex 2"), 8, "vertex " + n);
      return h;
    };
    struct Case { const char* name; std::string bytes; };
    std::vector<Case> cases = {
        {"empty file", ""},
        {"not a ply", "hello\n"},
        {"header only, no end_header", "ply\nformat binary_little_endian 1.0\n"},
        {"ascii format", std::string(hdr).replace(hdr.find("binary_little_endian"), 20, "ascii") + two},
        {"big endian", std::string(hdr).replace(hdr.find("binary_little_endian"), 20, "binary_big_endian") + two},
        {"double coordinates", std::string(hdr).replace(hdr.find("float x"), 7, "double x") + two},
        {"colour before position", std::string(hdr).replace(hdr.find("property float x"), 16, "property uchar red") + two},
        {"face element first", "ply\nformat binary_little_endian 1.0\nelement face 0\n" + hdr.substr(hdr.find("element vertex")) + two},
        {"0 points", withCount("0")},
        {"count not a number", withCount("12a")},
        {"count overflows", withCount("99999999999999999999999")},
        {"truncated by one byte", hdr + two.substr(0, two.size() - 1)},
        {"truncated, header claims 1M points", withCount("1000000") + two},
        {"NaN coordinate", hdr + pt(0, 0, 0) + pt(NAN, 1, 1)},
        {"Inf coordinate", hdr + pt(0, 0, 0) + pt(1, INFINITY, 1)},
        {"all points identical (zero-size box)", hdr + pt(1, 2, 3) + pt(1, 2, 3)},
    };
    int ok = 0;
    std::string firstBad;
    for (auto& c : cases) {
      const std::string path = scratch + "/bad.ply";
      writeFile(path, c.bytes);
      plb::BuildOptions b;
      b.outDir = scratch + "/bad_out";
      auto r = plb::buildFromPly(path, b);
      if (!r.ok && !r.error.empty()) ok++;
      else if (firstBad.empty()) firstBad = c.name;
      std::printf("       %-40s -> %s\n", c.name, r.ok ? "ACCEPTED" : r.error.c_str());
    }
    report("B1 bad inputs return an error (no abort)", ok == int(cases.size()),
           std::to_string(ok) + "/" + std::to_string(cases.size()) + (firstBad.empty() ? "" : ", accepted: " + firstBad));
    {
      plb::BuildOptions b;
      b.outDir = scratch + "/missing_out";
      auto r = plb::buildFromPly(scratch + "/does_not_exist.ply", b);
      report("B1 missing file -> error", !r.ok, r.error);
      writeFile(scratch + "/a_file", "x");
      b.outDir = scratch + "/a_file/sub";  // a directory under a regular file
      r = plb::buildFromPly(fx + "/source.ply", b);
      report("B1 output directory cannot be created -> error", !r.ok, r.error);
    }
    {
      plb::BuildOptions b;
      b.outDir = scratch + "/good_out";
      writeFile(scratch + "/good.ply", hdr + two);
      auto r = plb::buildFromPly(scratch + "/good.ply", b);
      report("B1-pos a valid 2-point PLY builds (so B1 is not 'always error')", r.ok, r.ok ? "ok" : r.error);
    }
  }

  std::printf("\n==== %s ====\n", g_fail == 0 ? "ALL PASS" : "FAILED");
  return g_fail == 0 ? 0 : 1;
}
