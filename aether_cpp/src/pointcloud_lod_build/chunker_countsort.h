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
