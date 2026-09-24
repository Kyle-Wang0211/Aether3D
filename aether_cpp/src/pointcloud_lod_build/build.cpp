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
// Port of PotreeConverter 2.0 @ 8bfad98 (BSD-2-Clause): the driver in
// Converter/src/main.cpp (curateSources, computeStats, chunking, indexing,
// merging) and computeScaleOffset / computeOutputAttributes from
// Converter/include/PotreeConverter.h.
#include "aether/pointcloud_lod_build/build.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <filesystem>
#include <system_error>
#include <thread>

#include "chunker_countsort.h"
#include "indexer.h"
#include "upstream_base.h"

namespace aether::pointcloud_lod_build {
namespace {

using pc::Attribute;
using pc::Attributes;
using pc::AttributeType;
using pc::Vector3;

double seconds(std::chrono::steady_clock::time_point a, std::chrono::steady_clock::time_point b) {
  return std::chrono::duration<double>(b - a).count();
}

struct ScaleOffset {  // PotreeConverter.h:23-26
  Vector3 scale;
  Vector3 offset;
};

// PotreeConverter.h:29-76
ScaleOffset computeScaleOffset(Vector3 min, Vector3 max, Vector3 targetScale) {
  Vector3 offset = min;
  Vector3 scale = targetScale;
  Vector3 size = max - min;

  // we can only use 31 bits because of the int/uint mistake in Potree 1.7
  // And we only use 30 bits to be on the safe sie.
  double min_scale_x = size.x / std::pow(2.0, 30.0);
  double min_scale_y = size.y / std::pow(2.0, 30.0);
  double min_scale_z = size.z / std::pow(2.0, 30.0);

  scale.x = std::max(scale.x, min_scale_x);
  scale.y = std::max(scale.y, min_scale_y);
  scale.z = std::max(scale.z, min_scale_z);

  ScaleOffset scaleOffset;
  scaleOffset.scale = scale;
  scaleOffset.offset = offset;
  return scaleOffset;
}

}  // namespace

BuildResult build(const PointSource& source, const BuildOptions& options) {
  BuildResult result;
  const auto tStart = std::chrono::steady_clock::now();
  pc::ErrorState error;

  auto fail = [&result](const std::string& msg) {
    result.ok = false;
    result.error = msg;
    return result;
  };

  if (options.outDir.empty()) return fail("outDir is empty");
  if (source.numPoints() <= 0) return fail("input has no points");
  if (options.writerRingBytes <= 0 || options.chunkBacklogMB <= 0) return fail("memory knobs must be positive");

  // getCpuData().numProcessors (unsuck_platform_specific.cpp) -> option (D14)
  int numProcessors = options.numThreads;
  if (numProcessors <= 0) numProcessors = int(std::max(1u, std::thread::hardware_concurrency()));

  // main.cpp:175-228 curateSources + PotreeConverter.h:200-320 computeOutputAttributes
  // with requestedAttributes = {"rgb"}: position is always prepended (:266), so the
  // list is exactly [position, rgb]. Never [position, position, rgb] (D18).
  Vector3 headerMin, headerMax, headerScale;
  {
    double mn[3], mx[3], sc[3];
    source.bounds(mn, mx);
    source.targetScale(sc);
    headerMin = {mn[0], mn[1], mn[2]};
    headerMax = {mx[0], mx[1], mx[2]};
    headerScale = {sc[0], sc[1], sc[2]};
  }
  for (double v : {headerMin.x, headerMin.y, headerMin.z, headerMax.x, headerMax.y, headerMax.z,
                   headerScale.x, headerScale.y, headerScale.z}) {
    if (!std::isfinite(v)) return fail("non-finite bounds or scale");
  }
  if (!(headerScale.x > 0 && headerScale.y > 0 && headerScale.z > 0)) return fail("scale must be positive");

  Attributes outputAttributes;
  {
    Attribute xyz("position", 12, 3, 4, AttributeType::INT32);
    Attribute rgb("rgb", 6, 3, 2, AttributeType::UINT16);
    outputAttributes = Attributes({xyz, rgb});
    auto scaleOffset = computeScaleOffset(headerMin, headerMax, headerScale);
    outputAttributes.posScale = scaleOffset.scale;
    outputAttributes.posOffset = scaleOffset.offset;
  }

  // main.cpp:239-308 computeStats
  Vector3 min = headerMin;
  Vector3 max = headerMax;
  double cubeSize = (max - min).max();
  Vector3 size = {cubeSize, cubeSize, cubeSize};
  max = min + cubeSize;
  {  // sanity check (:297-305), upstream exit(123)
    bool sizeError = (size.x == 0.0) || (size.y == 0.0) || (size.z == 0);
    if (sizeError) return fail("invalid bounding box. at least one axis has a size of zero.");
  }

  pc::State state;
  state.pointsTotal = source.numPoints();

  const std::string targetDir = options.outDir;
  const std::string chunkDir = options.chunkDir.empty() ? options.outDir : options.chunkDir;
  {
    std::error_code ec;
    std::filesystem::create_directories(targetDir, ec);
    if (ec) return fail("cannot create " + targetDir + ": " + ec.message());
    std::filesystem::create_directories(chunkDir, ec);
    if (ec) return fail("cannot create " + chunkDir + ": " + ec.message());
  }

  // main.cpp:603-612 chunking
  pc::ChunkerConfig chunkerConfig;
  chunkerConfig.numChunkerThreads = numProcessors;
  chunkerConfig.numFlushThreads = numProcessors;
  chunkerConfig.backlogWatermarkMB = options.chunkBacklogMB;
  chunkerConfig.maxPointsPerChunkCap = options.maxPointsPerChunkCap;
  pc::ChunkedMetadata chunked;
  if (!pc::doChunking(source, chunkDir, min, max, state, outputAttributes, chunkerConfig, &error, &chunked)) {
    return fail(error.failed() ? error.message : "chunking failed");
  }
  const auto tChunked = std::chrono::steady_clock::now();

  // main.cpp:614-624 indexing + merging
  pc::indexer::IndexingConfig indexingConfig;
  // indexer.cpp:1476 numSampleThreads() / 3 + 2, never more than asked for (D14)
  indexingConfig.numThreads = std::min(numProcessors / 3 + 2, numProcessors);
  indexingConfig.writerCapacity = options.writerRingBytes;
  indexingConfig.keepChunks = options.keepChunks;
  indexingConfig.name = options.name;
  if (!pc::indexer::doIndexingAndMerging(targetDir, chunkDir, chunked, state.pointsTotal, indexingConfig, &error)) {
    return fail(error.failed() ? error.message : "indexing failed");
  }
  const auto tEnd = std::chrono::steady_clock::now();

  std::error_code ec;
  auto octreeBytes = std::filesystem::file_size(targetDir + "/octree.bin", ec);

  result.ok = true;
  result.report.inputPoints = source.numPoints();
  result.report.octreeBytes = ec ? -1 : int64_t(octreeBytes);
  result.report.chunks = chunked.numChunks;
  result.report.maxPointsPerChunk = chunked.maxPointsPerChunk;
  result.report.gridSize = int(chunked.gridSize);
  result.report.threadsChunking = numProcessors;
  result.report.threadsIndexing = indexingConfig.numThreads;
  result.report.secondsChunking = seconds(tStart, tChunked);
  result.report.secondsIndexing = seconds(tChunked, tEnd);
  result.report.secondsTotal = seconds(tStart, tEnd);
  return result;
}

BuildOptions optionsForBudget(const std::string& outDir, const std::string& chunkDir,
                              int64_t memoryBudgetMB, int numThreads) {
  // Product defaults, chosen from measurements (DEVIATIONS.md "Memory knobs"):
  // with a 64 MiB ring, a 128 MB chunk backlog and 1M-point chunks, peak RSS was
  // 345 / 427 / 519 MB at 1 / 2 / 4 threads on the 36M cloud (macOS) and 333 / 385 MB
  // at 1 / 4 threads on the 216M cloud (Linux), every run producing upstream's tree.
  // Threads are then dropped until a conservative fit of those numbers,
  // 350 MB + 85 MB per extra thread, stays within the budget. Below ~350 MB the
  // build still runs with one thread but nothing was measured that low.
  BuildOptions o;
  o.outDir = outDir;
  o.chunkDir = chunkDir;
  o.writerRingBytes = int64_t(64) << 20;
  o.chunkBacklogMB = 128;
  o.maxPointsPerChunkCap = 1'000'000;
  int hw = int(std::max(1u, std::thread::hardware_concurrency()));
  int threads = numThreads > 0 ? numThreads : std::min(4, hw);
  while (threads > 1 && 350 + 85 * int64_t(threads - 1) > memoryBudgetMB) threads--;
  o.numThreads = threads;
  return o;
}

}  // namespace aether::pointcloud_lod_build
