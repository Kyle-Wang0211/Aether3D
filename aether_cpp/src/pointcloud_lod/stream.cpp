#include "aether/pointcloud_lod/stream.h"

#include <algorithm>
#include <chrono>
#include <cstring>
#include <fstream>
#include <unordered_set>

namespace aether::pointcloud_lod {

std::vector<ReadRange> planReads(const Octree& oct,
                                 const std::vector<int32_t>& nodes,
                                 int64_t maxGapBytes) {
  std::vector<int32_t> sorted;
  sorted.reserve(nodes.size());
  for (int32_t n : nodes) {
    if (n >= 0 && n < (int32_t)oct.nodes.size() && oct.nodes[(size_t)n].byteSize > 0)
      sorted.push_back(n);
  }
  std::sort(sorted.begin(), sorted.end(), [&](int32_t a, int32_t b) {
    return oct.nodes[(size_t)a].byteOffset < oct.nodes[(size_t)b].byteOffset;
  });

  std::vector<ReadRange> out;
  for (int32_t n : sorted) {
    const Node& nd = oct.nodes[(size_t)n];
    if (!out.empty()) {
      ReadRange& last = out.back();
      const int64_t end = last.offset + last.size;
      if (nd.byteOffset >= end && nd.byteOffset - end <= maxGapBytes) {
        last.size = nd.byteOffset + nd.byteSize - last.offset;
        last.nodes.push_back(n);
        continue;
      }
    }
    out.push_back({nd.byteOffset, nd.byteSize, {n}});
  }
  return out;
}

NodePoints decodeNode(const Octree& oct, int32_t node, const uint8_t* data, int64_t size) {
  NodePoints p;
  p.node = node;
  const Node& nd = oct.nodes[(size_t)node];
  const int bpp = oct.meta.bytesPerPoint();
  const int posOff = oct.meta.attributeOffset("position");
  const int rgbOff = oct.meta.attributeOffset("rgb");
  if (bpp <= 0 || posOff < 0 || size < 0) return p;

  const int64_t n = size / bpp;
  p.origin = nd.box.center();
  p.xyz.resize((size_t)n * 3);
  p.rgb.assign((size_t)n * 3, 255);

  // DecoderWorker.js:37-56 -- occupancy grid over the node box.
  constexpr int kGrid = 32;                                   // :37
  std::vector<uint32_t> grid(n > 0 ? (size_t)kGrid * kGrid * kGrid : 0, 0u);   // :38
  const Vec3 bmin = nd.box.min, bsize = nd.box.size();
  int64_t numOccupiedCells = 0;                               // :58
  auto cell = [&](double v, double extent) {
    // :45-51 `Math.min(parseInt(gridSize * v / size), gridSize - 1)`; D14:
    // clamped at 0 too (JS would index below 0 and silently drop the point).
    int c = extent > 0 ? (int)(kGrid * v / extent) : 0;
    return std::min(std::max(c, 0), kGrid - 1);
  };

  for (int64_t i = 0; i < n; i++) {
    int32_t q[3];
    std::memcpy(q, data + i * bpp + posOff, 12);
    const double wx = q[0] * oct.meta.scale.x + oct.meta.offset.x;
    const double wy = q[1] * oct.meta.scale.y + oct.meta.offset.y;
    const double wz = q[2] * oct.meta.scale.z + oct.meta.offset.z;
    p.xyz[(size_t)i * 3 + 0] = (float)(wx - p.origin.x);
    p.xyz[(size_t)i * 3 + 1] = (float)(wy - p.origin.y);
    p.xyz[(size_t)i * 3 + 2] = (float)(wz - p.origin.z);
    // :69-77 -- positions relative to the node's min corner, count first hits.
    const size_t idx = (size_t)cell(wx - bmin.x, bsize.x) +
                       (size_t)cell(wy - bmin.y, bsize.y) * kGrid +
                       (size_t)cell(wz - bmin.z, bsize.z) * kGrid * kGrid;   // :53
    if (grid[idx]++ == 0) numOccupiedCells++;                                 // :74-77
    if (rgbOff >= 0) {
      uint16_t c[3];
      std::memcpy(c, data + i * bpp + rgbOff, 6);
      // PotreeConverter widens 8-bit LAS colour to 16 bits; narrow it back for
      // upload. >> 8 rather than / 257 so 65535 -> 255 and 0 -> 0 exactly.
      p.rgb[(size_t)i * 3 + 0] = (uint8_t)(c[0] >> 8);
      p.rgb[(size_t)i * 3 + 1] = (uint8_t)(c[1] >> 8);
      p.rgb[(size_t)i * 3 + 2] = (uint8_t)(c[2] >> 8);
    }
  }
  // :154 `parseInt(numPoints / numOccupiedCells)` -- an integer, truncated.
  if (numOccupiedCells > 0) p.density = (double)(n / numOccupiedCells);
  return p;
}

const NodePoints* NodeCache::get(int32_t node) {
  auto it = map_.find(node);
  if (it == map_.end()) { misses_++; return nullptr; }
  hits_++;
  order_.erase(it->second.second);
  order_.push_front(node);
  it->second.second = order_.begin();
  return &it->second.first;
}

void NodeCache::put(NodePoints p) {
  const int32_t key = p.node;
  auto existing = map_.find(key);
  if (existing != map_.end()) {
    bytes_ -= existing->second.first.bytes();
    order_.erase(existing->second.second);
    map_.erase(existing);
  }
  const size_t sz = p.bytes();
  order_.push_front(key);
  map_.emplace(key, std::make_pair(std::move(p), order_.begin()));
  bytes_ += sz;

  while (bytes_ > budget_ && order_.size() > 1) {
    const int32_t victim = order_.back();
    order_.pop_back();
    auto vit = map_.find(victim);
    if (vit != map_.end()) {
      bytes_ -= vit->second.first.bytes();
      map_.erase(vit);
    }
    if (onEvict_) onEvict_(victim, onEvictCtx_);
  }
}

bool NodeCache::erase(int32_t node) {
  auto it = map_.find(node);
  if (it == map_.end()) return false;
  bytes_ -= it->second.first.bytes();
  order_.erase(it->second.second);
  map_.erase(it);
  return true;
}

NodeLoader::NodeLoader(const Octree& oct, std::string octreeBinPath, size_t cacheBytes)
    : oct_(oct), path_(std::move(octreeBinPath)), cache_(cacheBytes) {}

std::vector<const NodePoints*> NodeLoader::load(const Selection& sel, Stats* stats) {
  Stats local;
  Stats& st = stats ? *stats : local;

  std::vector<int32_t> missing;
  for (int32_t n : sel.nodes) if (!cache_.get(n)) missing.push_back(n);
  std::unordered_set<int32_t> lostToShortRead;

  if (!missing.empty()) {
    std::ifstream f(path_, std::ios::binary);
    if (f) {
      for (const ReadRange& r : planReads(oct_, missing)) {
        std::vector<uint8_t> buf((size_t)r.size);
        f.seekg(r.offset);
        f.read(reinterpret_cast<char*>(buf.data()), r.size);
        st.reads++;
        // loadOctree already checked every range against the file, so this only
        // fires if octree.bin changed underneath us. Decoding a short read would
        // turn the zeroed tail into fake points at the origin; drop it instead.
        if (f.gcount() != r.size) {
          st.shortReads++;
          for (int32_t n : r.nodes) lostToShortRead.insert(n);
          f.clear();
          continue;
        }
        st.bytesRead += r.size;
        int64_t used = 0;
        for (int32_t n : r.nodes) {
          const Node& nd = oct_.nodes[(size_t)n];
          const int64_t rel = nd.byteOffset - r.offset;
          cache_.put(decodeNode(oct_, n, buf.data() + rel, nd.byteSize));
          st.nodesDecoded++;
          used += nd.byteSize;
        }
        st.wastedBytes += r.size - used;
      }
    }
  }

  std::vector<const NodePoints*> out;
  out.reserve(sel.nodes.size());
  for (int32_t n : sel.nodes) {
    if (const NodePoints* p = cache_.get(n)) out.push_back(p);
    else if (!lostToShortRead.count(n)) st.droppedForCache++;
  }
  return out;
}

// ---------------------------------------------------------------------------
// AsyncNodeLoader

AsyncNodeLoader::AsyncNodeLoader(const Octree& oct, std::string octreeBinPath, const Config& cfg)
    : oct_(oct), path_(std::move(octreeBinPath)), cfg_(cfg), cache_(cfg.cacheBytes) {
  cache_.setEvictionCallback(&AsyncNodeLoader::onEvict, this);
  const int n = std::max(cfg_.workers, 1);
  threads_.reserve((size_t)n);
  for (int i = 0; i < n; i++) threads_.emplace_back([this] { workerMain(); });
}

AsyncNodeLoader::~AsyncNodeLoader() {
  {
    std::lock_guard<std::mutex> lk(mu_);
    stop_ = true;
  }
  cvWork_.notify_all();
  for (std::thread& t : threads_) t.join();
}

void AsyncNodeLoader::onEvict(int32_t node, void* self) {
  static_cast<AsyncNodeLoader*>(self)->evictedPending_.push_back(node);
}

// The worker: OctreeLoader.js:35-57 (one byte range per node) + the decode
// that DecoderWorker.js does off the main thread. Never touches the cache.
void AsyncNodeLoader::workerMain() {
  std::ifstream f(path_, std::ios::binary);
  std::vector<uint8_t> buf;
  for (;;) {
    int32_t node = -1;
    {
      std::unique_lock<std::mutex> lk(mu_);
      cvWork_.wait(lk, [this] { return stop_ || !queue_.empty(); });
      if (stop_) return;
      node = queue_.front();
      queue_.pop_front();
    }
    const Node& nd = oct_.nodes[(size_t)node];
    Done d{node, false, NodePoints{}, 0};
    if (nd.byteSize <= 0) {                       // OctreeLoader.js:45-47 -- empty node
      d.ok = true;
      d.points = decodeNode(oct_, node, nullptr, 0);
    } else if (f) {
      buf.resize((size_t)nd.byteSize);
      f.clear();
      f.seekg(nd.byteOffset);
      f.read(reinterpret_cast<char*>(buf.data()), nd.byteSize);
      if (f.gcount() == nd.byteSize) {            // a short read would decode zeros as points
        d.ok = true;
        d.bytes = nd.byteSize;
        d.points = decodeNode(oct_, node, buf.data(), nd.byteSize);
      }
    }
    {
      std::lock_guard<std::mutex> lk(mu_);
      done_.push_back(std::move(d));
    }
    cvDone_.notify_all();
  }
}

void AsyncNodeLoader::request(const std::vector<int32_t>& unloaded) {
  const size_t n = std::min((size_t)std::max(cfg_.maxNodesLoading, 0), unloaded.size());  // :406
  for (size_t i = 0; i < n; i++) {
    const int32_t node = unloaded[i];
    if (node < 0 || node >= (int32_t)oct_.nodes.size()) continue;
    if ((int)loading_.size() >= cfg_.maxNodesLoading) continue;   // OctreeGeometry.js:74-76
    if (cache_.contains(node) || loading_.count(node)) continue;   // OctreeLoader.js:16-18
    loading_.insert(node);                                         // OctreeLoader.js:20-21
    stats_.loadsStarted++;
    {
      std::lock_guard<std::mutex> lk(mu_);
      queue_.push_back(node);
    }
    cvWork_.notify_one();
  }
}

int AsyncNodeLoader::poll() {
  std::deque<Done> done;
  {
    std::lock_guard<std::mutex> lk(mu_);
    done.swap(done_);
  }
  int became = 0;
  for (Done& d : done) {
    loading_.erase(d.node);                     // OctreeLoader.js:112-113 / :142-143
    if (!d.ok) { stats_.loadsFailed++; continue; }   // :140-148 -- retried when requested again
    stats_.loadsCompleted++;
    stats_.bytesRead += d.bytes;
    cache_.put(std::move(d.points));            // :109-111 -- node.loaded = true
    became++;
    // LRU.js:150-169 disposeDescendants, for every node the cache just evicted.
    while (!evictedPending_.empty()) {
      const int32_t v = evictedPending_.back();
      evictedPending_.pop_back();
      evicted_.push_back(v);
      stats_.evicted++;
      std::vector<int32_t> stack;
      for (int32_t c : oct_.nodes[(size_t)v].children)
        if (c >= 0 && cache_.contains(c)) stack.push_back(c);      // :164 `if (child.loaded)`
      while (!stack.empty()) {
        const int32_t cur = stack.back();
        stack.pop_back();
        cache_.erase(cur);                                          // :158-159
        evicted_.push_back(cur);
        stats_.disposedDescendants++;
        for (int32_t c : oct_.nodes[(size_t)cur].children)
          if (c >= 0 && cache_.contains(c)) stack.push_back(c);
      }
    }
  }
  return became;
}

int AsyncNodeLoader::waitAndPoll(int timeoutMs) {
  {
    std::unique_lock<std::mutex> lk(mu_);
    cvDone_.wait_for(lk, std::chrono::milliseconds(timeoutMs), [this] { return !done_.empty(); });
  }
  return poll();
}

NodeState AsyncNodeLoader::state(int32_t node) const {
  return cache_.contains(node) ? NodeState::Loaded : NodeState::Unloaded;
}

std::vector<int32_t> AsyncNodeLoader::drainEvicted() {
  std::vector<int32_t> out;
  out.swap(evicted_);
  return out;
}

}  // namespace aether::pointcloud_lod
