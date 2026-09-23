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

#include <condition_variable>
#include <cstdint>
#include <deque>
#include <list>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <unordered_set>
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
  // Potree's per-node `density` (points per occupied cell of a 32^3 grid over
  // the node box, truncated to an integer), which its adaptive point size
  // turns into a LOD offset. potree/src/modules/loader/2.0/DecoderWorker.js
  // @ 5636cd4 :37-56 (grid), :69-77 (occupancy count), :154 (parseInt ratio).
  // 0 for a node with no points.
  double density = 0;
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

  // Called once for every node the budget loop in put() removes, after it is
  // gone. Not called for erase() or for a put() that replaces the same node.
  using EvictFn = void (*)(int32_t node, void* ctx);
  void setEvictionCallback(EvictFn fn, void* ctx) { onEvict_ = fn; onEvictCtx_ = ctx; }

  const NodePoints* get(int32_t node);          // nullptr on miss; marks as used
  void put(NodePoints p);                       // evicts LRU until within budget
  // Presence test that does NOT touch the LRU order and does NOT count as a
  // hit or a miss -- for a renderer mirroring what is resident.
  bool contains(int32_t node) const { return map_.count(node) != 0; }
  // Removes one node without calling the eviction callback. False if absent.
  bool erase(int32_t node);

  size_t bytes() const { return bytes_; }
  size_t size() const { return order_.size(); }
  int64_t hits() const { return hits_; }
  int64_t misses() const { return misses_; }
  void resetStats() { hits_ = misses_ = 0; }

 private:
  size_t budget_;
  size_t bytes_ = 0;
  int64_t hits_ = 0, misses_ = 0;
  EvictFn onEvict_ = nullptr;
  void* onEvictCtx_ = nullptr;
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
    // Selected nodes that load() could NOT return because the cache is smaller
    // than the selection (the "silently draws fewer nodes" case: the floor is
    // 15 B x point budget). Nodes lost to a short read are not counted here.
    int64_t droppedForCache = 0;
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

// ---------------------------------------------------------------------------
// Asynchronous loading with Potree's limits. Replicated, not invented:
//
//   potree @ 5636cd471d9eb464969e758be45c44d7613d3859
//   src/Potree.js:103-104                 numNodesLoading = 0; maxNodesLoading = 4
//   src/Potree_update_visibility.js:406-408
//                                         for i < min(maxNodesLoading, unloadedGeometry.length):
//                                             unloadedGeometry[i].load()
//   src/modules/loader/2.0/OctreeGeometry.js:72-79
//                                         load(): return if numNodesLoading >= maxNodesLoading
//   src/modules/loader/2.0/OctreeLoader.js:14-21
//                                         return if loaded || loading; loading = true; numNodesLoading++
//   src/modules/loader/2.0/OctreeLoader.js:35-57
//                                         one byte-range read of octree.bin per node (0 bytes -> empty node)
//   src/modules/loader/2.0/OctreeLoader.js:66-114
//                                         decode off the main thread (a worker), then on the main
//                                         thread: loaded = true, loading = false, numNodesLoading--
//   src/modules/loader/2.0/OctreeLoader.js:140-148
//                                         on failure: loaded = loading = false, numNodesLoading-- ("trying again")
//   src/LRU.js:138-170                    freeMemory() disposes the least-recently-used node AND its
//                                         loaded descendants, so a loaded node always has a loaded parent
//   src/Potree_update_visibility.js:310   drawn nodes are LRU-touched every frame
//   src/viewer/viewer.js:1628             pointLoadLimit = pointBudget * 2
//
// Threads: `workers` std::threads read and decode (Potree's WorkerPool). Only
// the calling ("main") thread touches the cache, exactly as only Potree's main
// thread touches node.geometry. Deviations: D8 table, D12-D16 in DEVIATIONS.md.
class AsyncNodeLoader {
 public:
  struct Config {
    size_t cacheBytes = 0;     // viewer.js:1628 -> 2 x 15 B x point budget
    int maxNodesLoading = 4;   // Potree.js:104
    int workers = 4;           // decode threads; loads beyond this wait for a free worker
  };

  AsyncNodeLoader(const Octree& oct, std::string octreeBinPath, const Config& cfg);
  ~AsyncNodeLoader();          // stops and joins the workers
  AsyncNodeLoader(const AsyncNodeLoader&) = delete;
  AsyncNodeLoader& operator=(const AsyncNodeLoader&) = delete;

  // Potree_update_visibility.js:406-408 with OctreeGeometry.js:72-79 and
  // OctreeLoader.js:14-21. Pass Selection::unloaded as returned (priority order).
  void request(const std::vector<int32_t>& unloaded);

  // Main thread: hand finished loads to the cache (the promise resolution in
  // OctreeLoader.js:68-114), then apply LRU.js disposeDescendants to whatever
  // the cache evicted. Returns how many nodes became Loaded.
  int poll();

  // Blocks until at least one in-flight load finishes or `timeoutMs` passes,
  // then poll()s. For tests and for a renderer that has nothing else to do.
  int waitAndPoll(int timeoutMs);

  // Unloaded or Loaded (decoded, cached). Drawable is the renderer's to decide.
  NodeState state(int32_t node) const;
  bool isLoading(int32_t node) const { return loading_.count(node) != 0; }
  int numNodesLoading() const { return (int)loading_.size(); }

  // Potree_update_visibility.js:310 -- touch a drawn node; returns its points
  // (nullptr if it is not cached). Use it to upload a promoted node too.
  const NodePoints* touch(int32_t node) { return cache_.get(node); }

  // Nodes removed from the cache since the last call (LRU victims and their
  // disposed descendants). A renderer releases their GPU buffers.
  std::vector<int32_t> drainEvicted();

  NodeCache& cache() { return cache_; }

  struct Stats {
    int64_t loadsStarted = 0, loadsCompleted = 0, loadsFailed = 0;
    int64_t bytesRead = 0, evicted = 0, disposedDescendants = 0;
  };
  const Stats& stats() const { return stats_; }

 private:
  struct Done { int32_t node; bool ok; NodePoints points; int64_t bytes; };
  static void onEvict(int32_t node, void* self);
  void workerMain();

  const Octree& oct_;
  std::string path_;
  Config cfg_;
  NodeCache cache_;
  std::unordered_set<int32_t> loading_;        // main thread only
  std::vector<int32_t> evictedPending_;        // filled by the cache callback
  std::vector<int32_t> evicted_;               // drained by the renderer
  Stats stats_;

  std::mutex mu_;
  std::condition_variable cvWork_, cvDone_;
  std::deque<int32_t> queue_;                  // guarded by mu_
  std::deque<Done> done_;                      // guarded by mu_
  bool stop_ = false;                          // guarded by mu_
  std::vector<std::thread> threads_;
};

}  // namespace aether::pointcloud_lod
