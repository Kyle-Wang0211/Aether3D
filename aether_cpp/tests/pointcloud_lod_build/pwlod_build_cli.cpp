// Command-line driver for measurements and cross-checks (not a pass/fail test).
//
//   pwlod_build_cli <input.ply|input.las> <outdir> [--chunkdir D] [--threads N]
//                   [--backlog-mb M] [--ring-mb M] [--budget-mb M] [--name S]
//                   [--virtual-las]      (PLY -> in-memory ply2las.py values)
//
// .las inputs go through the TEST-ONLY LasSource so the port sees exactly what
// the desktop PotreeConverter sees. Peak RSS is measured from outside
// (/usr/bin/time), so this file needs no per-OS code.
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

#include "aether/pointcloud_lod_build/build.h"
#include "las_source.h"

namespace plb = aether::pointcloud_lod_build;

int main(int argc, char** argv) {
  if (argc < 3) {
    std::fprintf(stderr, "usage: %s <input.ply|input.las> <outdir> [options]\n", argv[0]);
    return 2;
  }
  const std::string input = argv[1];
  plb::BuildOptions o;
  o.outDir = argv[2];
  bool virtualLas = false;
  int64_t budget = 0;
  for (int i = 3; i < argc; i++) {
    std::string a = argv[i];
    auto next = [&]() -> std::string { return i + 1 < argc ? argv[++i] : ""; };
    if (a == "--chunkdir") o.chunkDir = next();
    else if (a == "--threads") o.numThreads = std::atoi(next().c_str());
    else if (a == "--backlog-mb") o.chunkBacklogMB = std::atoll(next().c_str());
    else if (a == "--ring-mb") o.writerRingMB = std::atoll(next().c_str());
    else if (a == "--budget-mb") budget = std::atoll(next().c_str());
    else if (a == "--name") o.name = next();
    else if (a == "--virtual-las") virtualLas = true;
    else {
      std::fprintf(stderr, "unknown option %s\n", a.c_str());
      return 2;
    }
  }
  if (budget > 0) {
    plb::BuildOptions b = plb::optionsForBudget(o.outDir, o.chunkDir, budget, o.numThreads);
    b.name = o.name;
    o = b;
  }

  plb::BuildResult r;
  const bool isLas = input.size() > 4 && input.compare(input.size() - 4, 4, ".las") == 0;
  std::string err;
  if (isLas) {
    auto src = pwlod_test::LasSource::open(input, &err);
    if (!src) {
      std::fprintf(stderr, "FAIL %s\n", err.c_str());
      return 1;
    }
    r = plb::build(*src, o);
  } else if (virtualLas) {
    auto src = pwlod_test::VirtualLasFromPly::open(input, &err);
    if (!src) {
      std::fprintf(stderr, "FAIL %s\n", err.c_str());
      return 1;
    }
    r = plb::build(*src, o);
  } else {
    r = plb::buildFromPly(input, o);
  }

  if (!r.ok) {
    std::printf("FAIL %s\n", r.error.c_str());
    return 1;
  }
  const auto& p = r.report;
  std::printf("OK points=%lld octree.bin=%lld B (=%lld pts) chunks=%lld maxPointsPerChunk=%lld grid=%d "
              "threads=%d/%d chunking=%.3fs indexing=%.3fs total=%.3fs\n",
              (long long)p.inputPoints, (long long)p.octreeBytes, (long long)(p.octreeBytes / 18),
              (long long)p.chunks, (long long)p.maxPointsPerChunk, p.gridSize, p.threadsChunking,
              p.threadsIndexing, p.secondsChunking, p.secondsIndexing, p.secondsTotal);
  return 0;
}
