// A corrupt octree must produce an error, never a crash.
//
// This library is built with -fno-exceptions, under which nlohmann/json turns
// every would-be throw into std::abort(). A user's phone can end up with a
// half-written or damaged file (interrupted download, full disk, bit rot), and
// that must show an error, not kill the app.
//
// Each case copies the good fixture into a scratch directory, damages exactly
// one thing, and requires loadOctree() to RETURN with a non-empty error. If any
// case aborts, the whole test process dies -- which is itself the failure signal.
//
// Positive control first: the undamaged copy must load with NO error, otherwise
// every "rejected" below could just be the loader rejecting everything.
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <functional>
#include <string>
#include <vector>

#include "aether/pointcloud_lod/octree.h"

using namespace aether::pointcloud_lod;
namespace fs = std::filesystem;

static int g_fail = 0;
static void report(const char* n, bool ok, const std::string& d) {
  std::printf("  %-4s %-50s %s\n", ok ? "PASS" : "FAIL", n, d.c_str());
  if (!ok) g_fail++;
}

static std::string slurp(const fs::path& p) {
  std::ifstream f(p, std::ios::binary);
  return std::string(std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>());
}
static void spit(const fs::path& p, const std::string& s) {
  std::ofstream f(p, std::ios::binary | std::ios::trunc);
  f.write(s.data(), static_cast<std::streamsize>(s.size()));
}
static std::string replaceFirst(std::string s, const std::string& a, const std::string& b) {
  const auto pos = s.find(a);
  if (pos != std::string::npos) s.replace(pos, a.size(), b);
  return s;
}

int main(int argc, char** argv) {
  if (argc < 2) { std::fprintf(stderr, "usage: test_corrupt <good octree dir>\n"); return 2; }
  const fs::path good = argv[1];
  const fs::path work = fs::temp_directory_path() / "aether_pointcloud_lod_corrupt_test";

  auto fresh = [&]() {
    fs::remove_all(work);
    fs::create_directories(work);
    for (const char* f : {"metadata.json", "hierarchy.bin", "octree.bin"})
      fs::copy_file(good / f, work / f);
  };

  // ---- positive control ----
  fresh();
  {
    Octree o = loadOctree(work.string());
    report("P0 undamaged copy loads with no error", o.error.empty() && !o.nodes.empty(),
           o.error.empty() ? std::to_string(o.nodes.size()) + " nodes" : o.error);
  }

  const std::string meta = slurp(good / "metadata.json");
  const std::string hier = slurp(good / "hierarchy.bin");

  struct Case { const char* name; std::function<void()> damage; };
  const std::vector<Case> cases = {
    {"D1 bare `inf` (PotreeConverter's real failure, D9)",
     [&]{ spit(work/"metadata.json", replaceFirst(meta, "\"min\": [0, 0, 0]", "\"min\": [inf, inf, inf]")); }},
    {"D2 metadata truncated mid-file",
     [&]{ spit(work/"metadata.json", meta.substr(0, meta.size() / 2)); }},
    {"D3 metadata empty",
     [&]{ spit(work/"metadata.json", ""); }},
    {"D4 metadata is not an object",
     [&]{ spit(work/"metadata.json", "[1, 2, 3]"); }},
    {"D5 required field missing (spacing)",
     [&]{ spit(work/"metadata.json", replaceFirst(meta, "\"spacing\"", "\"spacinX\"")); }},
    {"D6 field has the wrong type (points as string)",
     [&]{ spit(work/"metadata.json", replaceFirst(meta, "\"points\": ", "\"points\": \"x\", \"_\": ")); }},
    {"D7 scale has 2 components, not 3",
     [&]{ auto s = meta; auto p = s.find("\"scale\": ["); auto q = s.find(']', p);
          s.replace(p, q - p + 1, "\"scale\": [1, 1]"); spit(work/"metadata.json", s); }},
    {"D8 negative point count",
     [&]{ auto s = meta; auto p = s.find("\"points\": "); auto q = s.find(',', p);
          s.replace(p, q - p, "\"points\": -5"); spit(work/"metadata.json", s); }},
    {"D9 zero spacing",
     [&]{ auto s = meta; auto p = s.find("\"spacing\": "); auto q = s.find(',', p);
          s.replace(p, q - p, "\"spacing\": 0"); spit(work/"metadata.json", s); }},
    {"D10 unsupported version",
     [&]{ spit(work/"metadata.json", replaceFirst(meta, "\"2.0\"", "\"9.9\"")); }},
    {"D11 hierarchy.bin missing",
     [&]{ fs::remove(work/"hierarchy.bin"); }},
    {"D12 hierarchy.bin truncated to 5 bytes",
     [&]{ spit(work/"hierarchy.bin", hier.substr(0, 5)); }},
    {"D13 hierarchy.bin empty",
     [&]{ spit(work/"hierarchy.bin", ""); }},
    {"D14 firstChunkSize larger than the file",
     [&]{ auto s = meta; auto p = s.find("\"firstChunkSize\": "); auto q = s.find(',', p);
          s.replace(p, q - p, "\"firstChunkSize\": 999999999"); spit(work/"metadata.json", s); }},
    {"D15 firstChunkSize not a multiple of 22",
     [&]{ auto s = meta; auto p = s.find("\"firstChunkSize\": "); auto q = s.find(',', p);
          s.replace(p, q - p, "\"firstChunkSize\": 21"); spit(work/"metadata.json", s); }},
    {"D16 metadata.json missing",
     [&]{ fs::remove(work/"metadata.json"); }},
    {"D17 octree.bin truncated (would decode zeros as points)",
     [&]{ const std::string b = slurp(good/"octree.bin"); spit(work/"octree.bin", b.substr(0, b.size()/2)); }},
    {"D18 octree.bin missing",
     [&]{ fs::remove(work/"octree.bin"); }},
    {"D19 a node's byteSize is 2^40 (would abort on allocation)",
     [&]{ std::string h = hier; int64_t huge = int64_t(1) << 40;
          std::memcpy(&h[14], &huge, 8); spit(work/"hierarchy.bin", h); }},
    {"D20 a node's numPoints disagrees with its byteSize",
     [&]{ std::string h = hier; uint32_t np; std::memcpy(&np, &h[2], 4); np += 1;
          std::memcpy(&h[2], &np, 4); spit(work/"hierarchy.bin", h); }},
    {"D21 a node's byteOffset is negative",
     [&]{ std::string h = hier; int64_t neg = -18;
          std::memcpy(&h[6], &neg, 8); spit(work/"hierarchy.bin", h); }},
  };

  for (const auto& c : cases) {
    fresh();
    c.damage();
    Octree o = loadOctree(work.string());   // if this aborts, the test dies here
    report(c.name, !o.error.empty(), o.error.empty() ? "LOADED A CORRUPT FILE" : o.error);
  }

  fs::remove_all(work);
  std::printf("\n==== %s ====\n", g_fail == 0 ? "ALL PASS (no case aborted)" : "FAILED");
  return g_fail == 0 ? 0 : 1;
}
