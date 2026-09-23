#include "aether/pointcloud_lod/octree.h"

#include <cmath>
#include <cstring>
#include <fstream>

#include "nlohmann/json.hpp"

namespace aether::pointcloud_lod {
namespace {

std::vector<uint8_t> readFile(const std::string& path, bool* ok) {
  std::ifstream f(path, std::ios::binary | std::ios::ate);
  if (!f) { *ok = false; return {}; }
  const auto n = static_cast<std::streamsize>(f.tellg());
  f.seekg(0);
  std::vector<uint8_t> buf(static_cast<size_t>(n));
  if (n > 0 && !f.read(reinterpret_cast<char*>(buf.data()), n)) { *ok = false; return {}; }
  *ok = true;
  return buf;
}

template <typename T>
T readLE(const uint8_t* p) {
  T v;
  std::memcpy(&v, p, sizeof(T));
  return v;  // hosts we target are little-endian; the format is LE by spec.
}

// ---------------------------------------------------------------------------
// Exception-free JSON access.
//
// This library is built with -fno-exceptions. nlohmann/json then turns every
// would-be throw into std::abort(), so a single malformed or truncated
// metadata.json would kill the app. Every accessor below therefore checks
// presence and type BEFORE touching a value, and never calls .at() or a
// .get<T>() whose type has not just been verified.
using Json = nlohmann::json;

const Json* field(const Json& j, const char* key) {
  if (!j.is_object()) return nullptr;
  const auto it = j.find(key);
  return it == j.end() ? nullptr : &*it;
}

bool getNumber(const Json& j, const char* key, double* out) {
  const Json* f = field(j, key);
  if (!f || !f->is_number()) return false;
  *out = f->get<double>();
  return true;
}

bool getInt(const Json& j, const char* key, int64_t* out) {
  const Json* f = field(j, key);
  if (!f || !f->is_number_integer()) return false;
  *out = f->get<int64_t>();
  return true;
}

bool getString(const Json& j, const char* key, std::string* out) {
  const Json* f = field(j, key);
  if (!f || !f->is_string()) return false;
  *out = f->get<std::string>();
  return true;
}

bool getVec3(const Json& j, const char* key, Vec3* out) {
  const Json* f = field(j, key);
  if (!f || !f->is_array() || f->size() != 3) return false;
  for (size_t i = 0; i < 3; i++) if (!(*f)[i].is_number()) return false;
  *out = {(*f)[0].get<double>(), (*f)[1].get<double>(), (*f)[2].get<double>()};
  return true;
}

}  // namespace

double Vec3::length() const { return std::sqrt(x * x + y * y + z * z); }

int Metadata::bytesPerPoint() const {
  int n = 0;
  for (const auto& a : attributes) n += a.size;
  return n;
}

int Metadata::attributeOffset(const std::string& name) const {
  int off = 0;
  for (const auto& a : attributes) {
    if (a.name == name) return off;
    off += a.size;
  }
  return -1;
}

// OctreeLoader.js:293-316, verbatim octant mapping.
Box3 createChildAABB(const Box3& box, int index) {
  Vec3 min = box.min, max = box.max;
  const Vec3 size = box.size();
  if (index & 0b0001) min.z += size.z / 2; else max.z -= size.z / 2;
  if (index & 0b0010) min.y += size.y / 2; else max.y -= size.y / 2;
  if (index & 0b0100) min.x += size.x / 2; else max.x -= size.x / 2;
  return {min, max};
}

int64_t Octree::totalPointsInNodes() const {
  int64_t n = 0;
  for (const auto& node : nodes) n += node.numPoints;
  return n;
}

Octree loadOctree(const std::string& dir) {
  Octree oct;

  bool ok = false;
  const auto metaBytes = readFile(dir + "/metadata.json", &ok);
  if (!ok) { oct.error = "cannot read metadata.json"; return oct; }

  // allow_exceptions=false: a parse error yields a "discarded" value instead of
  // a throw (which, with exceptions off, would be std::abort()).
  const Json js = Json::parse(metaBytes.begin(), metaBytes.end(), nullptr, false);
  if (js.is_discarded() || !js.is_object()) {
    // PotreeConverter writes bare `inf` for an attribute that received no data
    // (DEVIATIONS.md D9). That is not valid JSON and lands here.
    oct.error = "metadata.json is not valid JSON";
    return oct;
  }

  Metadata& m = oct.meta;
  auto missing = [&](const char* what) {
    oct.error = std::string("metadata.json: missing or mistyped field '") + what + "'";
    return oct;
  };
  if (!getString(js, "version", &m.version))   return missing("version");
  if (!getInt(js, "points", &m.points))        return missing("points");
  if (!getNumber(js, "spacing", &m.spacing))   return missing("spacing");
  if (!getVec3(js, "scale", &m.scale))         return missing("scale");
  if (!getVec3(js, "offset", &m.offset))       return missing("offset");
  if (!getString(js, "encoding", &m.encoding)) return missing("encoding");

  const Json* bb = field(js, "boundingBox");
  if (!bb || !getVec3(*bb, "min", &m.boundingBox.min) ||
             !getVec3(*bb, "max", &m.boundingBox.max))
    return missing("boundingBox");

  const Json* hj = field(js, "hierarchy");
  int64_t step = 0, depth = 0;
  if (!hj || !getInt(*hj, "firstChunkSize", &m.hierarchyFirstChunkSize) ||
             !getInt(*hj, "stepSize", &step) || !getInt(*hj, "depth", &depth))
    return missing("hierarchy");
  m.hierarchyStepSize = static_cast<int>(step);
  m.hierarchyDepth = static_cast<int>(depth);

  const Json* attrs = field(js, "attributes");
  if (!attrs || !attrs->is_array()) return missing("attributes");
  for (const Json& ja : *attrs) {
    Attribute a;
    int64_t size = 0, numElements = 0, elementSize = 0;
    if (!getString(ja, "name", &a.name) || !getInt(ja, "size", &size) ||
        !getInt(ja, "numElements", &numElements) ||
        !getInt(ja, "elementSize", &elementSize) || !getString(ja, "type", &a.type))
      return missing("attributes[]");
    a.size = static_cast<int>(size);
    a.numElements = static_cast<int>(numElements);
    a.elementSize = static_cast<int>(elementSize);
    m.attributes.push_back(a);
  }

  // Sanity bounds that turn a corrupt file into an error instead of a crash or
  // a multi-gigabyte allocation further down.
  if (m.points < 0) return missing("points (negative)");
  if (m.spacing <= 0 || !std::isfinite(m.spacing)) return missing("spacing (not positive)");
  if (m.hierarchyFirstChunkSize < 0) return missing("hierarchy.firstChunkSize (negative)");
  if (m.bytesPerPoint() <= 0) return missing("attributes (zero bytes per point)");

  if (m.version != "2.0") { oct.error = "unsupported octree version " + m.version; return oct; }
  if (m.encoding != "DEFAULT") { oct.error = "unsupported encoding " + m.encoding; return oct; }

  const auto hier = readFile(dir + "/hierarchy.bin", &ok);
  if (!ok) { oct.error = "cannot read hierarchy.bin"; return oct; }

  // ---- OctreeLoader.js:151-232, transliterated. ----
  constexpr int kBytesPerNode = 22;  // HierarchyBuilder.h:247 and OctreeLoader.js:156

  Node root;
  root.name    = "r";
  root.box     = m.boundingBox;
  root.spacing = m.spacing;
  root.level   = 0;
  root.children.fill(-1);
  oct.nodes.push_back(root);

  // Parses one contiguous hierarchy chunk. `first` is the index in oct.nodes of
  // the node the chunk describes; the chunk's records are in the same
  // breadth-first order in which the loader creates children.
  struct Chunk { int32_t nodeIndex; int64_t byteOffset; int64_t byteSize; };
  std::vector<Chunk> pending{{0, 0, m.hierarchyFirstChunkSize}};

  while (!pending.empty()) {
    const Chunk chunk = pending.back();
    pending.pop_back();

    if (chunk.byteOffset < 0 || chunk.byteSize < 0 ||
        chunk.byteOffset + chunk.byteSize > static_cast<int64_t>(hier.size())) {
      oct.error = "hierarchy chunk out of range";
      return oct;
    }
    if (chunk.byteSize % kBytesPerNode != 0) {
      oct.error = "hierarchy chunk size is not a multiple of 22";
      return oct;
    }
    const int64_t numNodes = chunk.byteSize / kBytesPerNode;
    const uint8_t* base = hier.data() + chunk.byteOffset;

    // OctreeLoader.js:159-162 -- nodes[0] is the chunk's own node; children are
    // appended in the same order the records appear.
    std::vector<int32_t> order;
    order.reserve(static_cast<size_t>(numNodes));
    order.push_back(chunk.nodeIndex);

    for (int64_t i = 0; i < numNodes; i++) {
      if (i >= static_cast<int64_t>(order.size())) {
        oct.error = "hierarchy chunk declares more records than the tree reaches";
        return oct;
      }
      const int32_t curIdx = order[static_cast<size_t>(i)];
      const uint8_t* rec = base + i * kBytesPerNode;

      const auto type       = static_cast<NodeType>(readLE<uint8_t>(rec + 0));
      const uint8_t childMask = readLE<uint8_t>(rec + 1);
      const uint32_t numPoints = readLE<uint32_t>(rec + 2);
      const int64_t byteOffset = readLE<int64_t>(rec + 6);
      const int64_t byteSize   = readLE<int64_t>(rec + 14);

      {
        Node& cur = oct.nodes[static_cast<size_t>(curIdx)];
        if (cur.type == NodeType::Proxy) {
          // OctreeLoader.js:179-182 -- replace proxy with the real node.
          cur.byteOffset = byteOffset;
          cur.byteSize   = byteSize;
          cur.numPoints  = numPoints;
        } else if (type == NodeType::Proxy) {
          // OctreeLoader.js:184-187 -- this record points at another chunk.
          cur.hierarchyByteOffset = byteOffset;
          cur.hierarchyByteSize   = byteSize;
          cur.numPoints           = numPoints;
        } else {
          cur.byteOffset = byteOffset;
          cur.byteSize   = byteSize;
          cur.numPoints  = numPoints;
        }
        // OctreeLoader.js:194-199 -- workaround for potree issue #1125: an inner
        // node may report points while having byteSize 0; it has none.
        if (cur.byteSize == 0) cur.numPoints = 0;
        cur.type = type;
      }

      if (type == NodeType::Proxy) {
        // OctreeLoader.js:203-205 -- do not descend here; queue the chunk.
        const Node& cur = oct.nodes[static_cast<size_t>(curIdx)];
        pending.push_back({curIdx, cur.hierarchyByteOffset, cur.hierarchyByteSize});
        continue;
      }

      for (int childIndex = 0; childIndex < 8; childIndex++) {
        if (((1 << childIndex) & childMask) == 0) continue;  // OctreeLoader.js:210
        const Node& parent = oct.nodes[static_cast<size_t>(curIdx)];
        Node child;
        child.name    = parent.name + static_cast<char>('0' + childIndex);
        child.box     = createChildAABB(parent.box, childIndex);
        child.spacing = parent.spacing / 2;      // OctreeLoader.js:222
        child.level   = parent.level + 1;        // OctreeLoader.js:223
        child.parent  = curIdx;
        child.children.fill(-1);
        const auto childIdx = static_cast<int32_t>(oct.nodes.size());
        oct.nodes.push_back(child);
        oct.nodes[static_cast<size_t>(curIdx)].children[childIndex] = childIdx;
        order.push_back(childIdx);
      }
    }
  }

  // ---- Validate every node against the real octree.bin. ----
  //
  // Nothing above has looked at octree.bin, so a damaged hierarchy could still
  // point outside it. Two things go wrong if that reaches the loader:
  //   - a short read leaves the tail of the buffer zeroed, and those zeros decode
  //     as real-looking points at the origin: silent wrong data;
  //   - a corrupt byteSize (say 2^40) makes the loader allocate that much, and
  //     with -fno-exceptions std::bad_alloc is std::abort(): a crash.
  // So reject the octree here, once, instead of trusting it per frame.
  {
    std::ifstream bin(dir + "/octree.bin", std::ios::binary | std::ios::ate);
    if (!bin) { oct.nodes.clear(); oct.error = "cannot read octree.bin"; return oct; }
    const int64_t binSize = static_cast<int64_t>(bin.tellg());
    const int bpp = m.bytesPerPoint();
    for (const Node& n : oct.nodes) {
      if (n.type == NodeType::Proxy && n.byteSize == 0) continue;  // unresolved proxy
      const bool bad =
          n.byteOffset < 0 || n.byteSize < 0 ||
          n.byteOffset > binSize || n.byteSize > binSize - n.byteOffset ||
          n.byteSize % bpp != 0 ||
          static_cast<int64_t>(n.numPoints) != n.byteSize / bpp;
      if (bad) {
        oct.error = "node " + n.name + " does not fit octree.bin (offset " +
                    std::to_string(n.byteOffset) + ", size " + std::to_string(n.byteSize) +
                    ", points " + std::to_string(n.numPoints) + ", file " +
                    std::to_string(binSize) + " B)";
        oct.nodes.clear();
        return oct;
      }
    }
  }

  return oct;
}

}  // namespace aether::pointcloud_lod
