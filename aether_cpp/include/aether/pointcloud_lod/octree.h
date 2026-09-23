// PocketWorld point-cloud LOD core.
//
// Pure C++ (C++17 or later). No graphics API, no vendor API, no #if __APPLE__ / __ANDROID__.
// Desktop and every mobile GPU family run the identical code path.
//
// Replicated, not invented. Every constant and formula is pinned to a line of
// permissively-licensed upstream source; deviations are listed in DEVIATIONS.md.
//
//   Format  : Potree 2.0 octree   (PotreeConverter, BSD-2-Clause)
//             - writer  Converter/include/HierarchyBuilder.h:270-274
//             - reader  potree/src/modules/loader/2.0/OctreeLoader.js:151-232
//   Select  : Potree updateVisibility  (potree, BSD-2-Clause)
//             - potree/src/Potree_update_visibility.js:352-392  (node weight)
//             - potree/src/Potree_update_visibility.js:282-283  (budget break)
//             - potree/src/Potree_update_visibility.js:182      (level<=2 pinned)
//   JSON    : nlohmann/json v3.11.3 (MIT)
#pragma once

#include <array>
#include <cstdint>
#include <string>
#include <vector>

namespace aether::pointcloud_lod {

struct Vec3 {
  double x = 0, y = 0, z = 0;
  Vec3 operator-(const Vec3& o) const { return {x - o.x, y - o.y, z - o.z}; }
  Vec3 operator+(const Vec3& o) const { return {x + o.x, y + o.y, z + o.z}; }
  Vec3 operator*(double s) const { return {x * s, y * s, z * s}; }
  double length() const;
};

struct Box3 {
  Vec3 min, max;
  Vec3 size() const { return max - min; }
  Vec3 center() const { return (min + max) * 0.5; }
  // Bounding sphere of the box, as Potree's getBoundingSphere() returns.
  double boundingSphereRadius() const { return size().length() * 0.5; }
};

struct Attribute {
  std::string name;
  int size = 0;          // bytes
  int numElements = 0;
  int elementSize = 0;
  std::string type;
};

struct Metadata {
  std::string version;
  int64_t points = 0;
  double spacing = 0;
  Vec3 scale, offset;
  Box3 boundingBox;
  std::string encoding;
  std::vector<Attribute> attributes;
  int64_t hierarchyFirstChunkSize = 0;
  int hierarchyStepSize = 0;
  int hierarchyDepth = 0;

  int bytesPerPoint() const;
  // Byte offset of an attribute inside one point record, or -1.
  int attributeOffset(const std::string& name) const;
};

// OctreeLoader.js:168 -- node type tag in the 22-byte hierarchy record.
enum class NodeType : uint8_t { Normal = 0, Leaf = 1, Proxy = 2 };

struct Node {
  std::string name;          // "r", "r0", "r37", ... ; each char is an octant
  Box3 box;
  double spacing = 0;
  int level = 0;
  NodeType type = NodeType::Normal;
  uint32_t numPoints = 0;
  int64_t byteOffset = 0;    // into octree.bin
  int64_t byteSize = 0;
  // Proxy nodes point into hierarchy.bin instead; resolved during load.
  int64_t hierarchyByteOffset = 0;
  int64_t hierarchyByteSize = 0;
  std::array<int32_t, 8> children{};  // index into Octree::nodes, -1 = absent
  int32_t parent = -1;
};

// OctreeLoader.js:293-316 -- octant bit order is (bit0=z, bit1=y, bit2=x).
Box3 createChildAABB(const Box3& box, int index);

struct Octree {
  Metadata meta;
  std::vector<Node> nodes;   // nodes[0] is the root
  // Parse failure leaves `error` non-empty and `nodes` empty.
  std::string error;

  int64_t totalPointsInNodes() const;
};

// Loads metadata.json + the whole of hierarchy.bin (proxies resolved eagerly).
// `dir` holds metadata.json / hierarchy.bin / octree.bin.
Octree loadOctree(const std::string& dir);

}  // namespace aether::pointcloud_lod
