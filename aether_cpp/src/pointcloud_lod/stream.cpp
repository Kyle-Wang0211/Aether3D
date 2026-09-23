#include "aether/pointcloud_lod/stream.h"

#include <algorithm>
#include <cstring>
#include <fstream>

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

  for (int64_t i = 0; i < n; i++) {
    int32_t q[3];
    std::memcpy(q, data + i * bpp + posOff, 12);
    p.xyz[(size_t)i * 3 + 0] = (float)(q[0] * oct.meta.scale.x + oct.meta.offset.x - p.origin.x);
    p.xyz[(size_t)i * 3 + 1] = (float)(q[1] * oct.meta.scale.y + oct.meta.offset.y - p.origin.y);
    p.xyz[(size_t)i * 3 + 2] = (float)(q[2] * oct.meta.scale.z + oct.meta.offset.z - p.origin.z);
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
  }
}

NodeLoader::NodeLoader(const Octree& oct, std::string octreeBinPath, size_t cacheBytes)
    : oct_(oct), path_(std::move(octreeBinPath)), cache_(cacheBytes) {}

std::vector<const NodePoints*> NodeLoader::load(const Selection& sel, Stats* stats) {
  Stats local;
  Stats& st = stats ? *stats : local;

  std::vector<int32_t> missing;
  for (int32_t n : sel.nodes) if (!cache_.get(n)) missing.push_back(n);

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
  for (int32_t n : sel.nodes) if (const NodePoints* p = cache_.get(n)) out.push_back(p);
  return out;
}

}  // namespace aether::pointcloud_lod
