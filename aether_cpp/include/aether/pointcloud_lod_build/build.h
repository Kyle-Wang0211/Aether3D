// Portions of this file are derived from PotreeConverter 2.0
// (https://github.com/potree/PotreeConverter), used under this licence,
// reproduced verbatim as its clause 1 requires:
//
// Copyright 2020 Markus Schütz
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//
// 1. Redistributions of source code must retain the above copyright notice,
// this list of conditions and the following disclaimer.
//
// 2. Redistributions in binary form must reproduce the above copyright notice,
// this list of conditions and the following disclaimer in the documentation
// and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
// ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
// LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.
//
// PocketWorld on-device octree builder.
//
// A port of PotreeConverter 2.0 @ 8bfad98d2a6b2111cdcb3840cb508b59408d0721
// (BSD-2-Clause) that runs inside an app: counting-sort chunking
// (chunker_countsort_laszip.cpp), per-chunk bottom-up Poisson-disk indexing
// (indexer.cpp + sampler_poisson.h) and the hierarchy writer (HierarchyBuilder.h).
// The algorithm is upstream's; every change is a portability change and is listed,
// with the upstream file:line it replaces, in src/pointcloud_lod_build/DEVIATIONS.md.
//
// Output: Potree 2.0 (metadata.json + hierarchy.bin + octree.bin), attributes
// position (int32 x3) + rgb (uint16 x3) = 18 B/point, encoding DEFAULT, readable by
// aether::pointcloud_lod::loadOctree.
//
// Pure C++20, no exceptions, no RTTI, no per-OS code. Errors (bad input, I/O
// failure, disk full, allocation failure) are returned, never abort().
#pragma once

#include <cstdint>
#include <memory>
#include <string>

namespace aether::pointcloud_lod_build {

// A random-access source of points; read() is called concurrently from several
// threads and must be thread-safe. This is the seam where upstream reads LAS via
// LASzip; the product reads our PLY (openPly), tests may plug in other readers.
class PointSource {
 public:
  virtual ~PointSource() = default;
  virtual int64_t numPoints() const = 0;
  // Bounds of all points; upstream takes these from the LAS header (min/max).
  virtual void bounds(double min[3], double max[3]) const = 0;
  // Per-axis storage precision; upstream takes this from the LAS header scale and
  // hands it to computeScaleOffset() as targetScale.
  virtual void targetScale(double scale[3]) const = 0;
  // Fills xyz[3*count] (world coordinates, double) and rgb[3*count] (16-bit).
  virtual bool read(int64_t first, int64_t count, double* xyz, uint16_t* rgb,
                    std::string* error) const = 0;
};

struct BuildOptions {
  std::string outDir;       // receives metadata.json, hierarchy.bin, octree.bin
  std::string chunkDir;     // scratch for the chunking pass; empty => outDir (upstream default)
  std::string name;         // metadata.json "name"
  int numThreads = 0;       // replaces upstream's getCpuData().numProcessors; 0 => hardware_concurrency
  // Memory knobs. Defaults are upstream's desktop constants.
  int64_t chunkBacklogMB = 2000;  // chunker_countsort_laszip.cpp:906 waitUntilMemoryBelow(2'000)
  int64_t writerRingBytes = int64_t(1) << 30;  // Writer.h:26 capacity = 1 GiB
  // Upper bound on points per chunk; 0 keeps upstream's min(N / 20, 10'000'000)
  // (chunker_countsort_laszip.cpp:1390-1391). Indexing memory scales with it.
  // Values below 10'000 are raised to 10'000: from there down the tree would
  // differ from upstream's (see DEVIATIONS.md D4).
  int64_t maxPointsPerChunkCap = 0;
  bool keepChunks = false;        // upstream --keep-chunks
};

// Options for a phone: 64 MiB ring, 128 MB chunk backlog, 1M-point chunks, and as
// many threads (default min(4, cores)) as fit the budget by a conservative fit of
// measured peak RSS (350 MB + 85 MB per extra thread). See DEVIATIONS.md
// "Memory knobs" for the measurements. The tree is upstream's for every setting.
BuildOptions optionsForBudget(const std::string& outDir, const std::string& chunkDir,
                              int64_t memoryBudgetMB, int numThreads);

struct BuildReport {
  int64_t inputPoints = 0;
  int64_t octreeBytes = 0;   // size of octree.bin as written
  int64_t chunks = 0;
  int64_t maxPointsPerChunk = 0;
  int gridSize = 0;
  int threadsChunking = 0;
  int threadsIndexing = 0;
  double secondsChunking = 0;
  double secondsIndexing = 0;
  double secondsTotal = 0;
};

struct BuildResult {
  bool ok = false;
  std::string error;
  BuildReport report;
};

BuildResult build(const PointSource& source, const BuildOptions& options);

// PLY glue (the only new code besides error plumbing): binary_little_endian,
// exactly `float x,y,z` + `uchar red,green,blue` (15 B/point). Opening scans the
// file once for bounds and rejects truncated files, malformed headers, zero
// points and non-finite coordinates.
bool openPly(const std::string& path, std::unique_ptr<PointSource>* out, std::string* error);

BuildResult buildFromPly(const std::string& plyPath, const BuildOptions& options);

}  // namespace aether::pointcloud_lod_build
