// Port of PotreeConverter 2.0 @ 8bfad98 (BSD-2-Clause):
// Converter/include/chunker_countsort_laszip.h + src/chunker_countsort_laszip.cpp.
#pragma once

#include <string>

#include "aether/pointcloud_lod_build/build.h"
#include "upstream_base.h"

namespace aether::pointcloud_lod_build::pc {

struct ChunkerConfig {
  int numChunkerThreads = 1;         // chunker_countsort_laszip.cpp:50
  int numFlushThreads = 1;           // chunker_countsort_laszip.cpp:51
  int64_t backlogWatermarkMB = 2000; // chunker_countsort_laszip.cpp:906
  int64_t maxPointsPerChunkCap = 0;  // D4; 0 = upstream formula only
};

// What upstream writes to <chunkdir>/chunks/metadata.json (writeMetadata,
// chunker_countsort_laszip.cpp:1177-1240) and indexer::getChunks reads back.
// Handed over in memory instead (D8).
struct ChunkedMetadata {
  Vector3 min;
  Vector3 max;
  Attributes attributes;
  int64_t numChunks = 0;
  int64_t maxPointsPerChunk = 0;
  int64_t gridSize = 0;
};

// chunker_countsort_laszip.cpp:1378-1441
bool doChunking(const PointSource& source, const string& targetDir, Vector3 min, Vector3 max,
                State& state, Attributes outputAttributes, const ChunkerConfig& config,
                ErrorState* error, ChunkedMetadata* out);

}  // namespace aether::pointcloud_lod_build::pc
