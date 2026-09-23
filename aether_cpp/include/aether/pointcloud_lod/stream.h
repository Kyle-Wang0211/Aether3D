// On-demand node loading for the Potree 2.0 octree.
//
// Pure C++ (C++17 or later). No graphics API, no vendor API, no platform #ifdef.
//
// Why this shape: entry-level phone flash reads randomly 10-14x slower than
// sequentially, so a frame must not turn into hundreds of scattered small
// reads. Each node is ONE contiguous byte range in octree.bin (proven by
// test_octree's C2: the ranges tile the file with no gap and no overlap), and
// nodes that happen to be adjacent are coalesced into a single read.
#pragma once

#include <cstdint>
#include <list>
#include <string>
#include <unordered_map>
#include <vector>

#include "aether/pointcloud_lod/select.h"

namespace aether::pointcloud_lod {

// One node's points, ready to hand to a renderer.
//
// Positions are float32 RELATIVE TO `origin`, because absolute float32 loses
// the stored grid by an amount that depends on WHERE the point is: the rounding
// error is half a float32 ULP of the absolute coordinate, which grows with
// distance from the world origin. Measured on our 36M cloud (test_stream N4):
// at the deepest nodes, which happen to sit near the origin, absolute float32 is
// 1.3x the grid LSB; at the far corner of the same scene it is ~27x. Relative
// float32 has no such dependence -- its error is bounded by the node's own size,
// wherever the node is.
//
// What relative float32 actually buys, stated exactly rather than hand-waved:
// for a node of edge length S the float32 representation error is about
// S * 2^-24 ~= S * 6e-8, so the STORED int32 grid (LSB `meta.scale`) survives
// intact only while S * 6e-8 <= LSB. With a 18.7-unit scene and a 1.2e-8 LSB
// that means S <= ~0.2 units, i.e. roughly level 7 and deeper.
//
// Shallower nodes therefore lose a fraction of an LSB. That is harmless and it
// is worth saying why: a node is only drawn while its bounding sphere covers at
// least `minimumNodePixelSize` pixels, so a node of edge S is on screen at a
// distance where S maps to a few hundred pixels at most. An error of S * 6e-8
// is then ~1e-10 of a pixel. The precision that matters -- the precision you
// see when you zoom in on one point -- is the deep-node precision, and there
// the stored grid is preserved exactly.
struct NodePoints {
  int32_t node = -1;
  Vec3 origin;                    // world position that (0,0,0) corresponds to
  std::vector<float> xyz;         // 3 per point
  std::vector<uint8_t> rgb;       // 3 per point
  size_t count() const { return rgb.size() / 3; }
  size_t bytes() const { return xyz.size() * 4 + rgb.size(); }
};

// A contiguous read request, possibly covering several adjacent nodes.
struct ReadRange {
  int64_t offset = 0;
  int64_t size = 0;
  std::vector<int32_t> nodes;     // nodes covered, in file order
};

// Nodes are sorted by byteOffset and merged when the gap between them is at
// most `maxGapBytes`. A small gap is cheaper to read and throw away than a
// second seek on slow flash.
std::vector<ReadRange> planReads(const Octree& oct,
                                 const std::vector<int32_t>& nodes,
                                 int64_t maxGapBytes = 64 * 1024);

// Least-recently-used cache of decoded nodes, bounded by total bytes.
class NodeCache {
 public:
  explicit NodeCache(size_t budgetBytes) : budget_(budgetBytes) {}

  const NodePoints* get(int32_t node);          // nullptr on miss; marks as used
  void put(NodePoints p);                       // evicts LRU until within budget

  size_t bytes() const { return bytes_; }
  size_t size() const { return order_.size(); }
  int64_t hits() const { return hits_; }
  int64_t misses() const { return misses_; }
  void resetStats() { hits_ = misses_ = 0; }

 private:
  size_t budget_;
  size_t bytes_ = 0;
  int64_t hits_ = 0, misses_ = 0;
  std::list<int32_t> order_;                    // front = most recent
  std::unordered_map<int32_t, std::pair<NodePoints, std::list<int32_t>::iterator>> map_;
};

// Reads and decodes the nodes of a selection that are not already cached.
// `readBytes` lets a caller substitute its own I/O (a test, a network fetch, a
// memory-mapped file); the default reads octree.bin with ordinary file I/O.
class NodeLoader {
 public:
  NodeLoader(const Octree& oct, std::string octreeBinPath, size_t cacheBytes);

  struct Stats {
    int64_t reads = 0;          // number of contiguous reads issued
    int64_t bytesRead = 0;
    int64_t nodesDecoded = 0;
    int64_t wastedBytes = 0;    // read because of gap coalescing, then discarded
    int64_t shortReads = 0;     // reads that came back short and were dropped
  };

  // Loads every node of `sel` that is missing, then returns pointers to all of
  // them in selection order. Pointers are valid until the next call.
  std::vector<const NodePoints*> load(const Selection& sel, Stats* stats);

  NodeCache& cache() { return cache_; }

 private:
  const Octree& oct_;
  std::string path_;
  NodeCache cache_;
};

// Decodes one node's raw record bytes. Exposed so tests can drive it directly.
NodePoints decodeNode(const Octree& oct, int32_t node, const uint8_t* data, int64_t size);

}  // namespace aether::pointcloud_lod
