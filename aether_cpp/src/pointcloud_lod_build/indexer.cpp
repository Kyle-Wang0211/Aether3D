// Port of PotreeConverter 2.0 @ 8bfad98 (BSD-2-Clause): Converter/src/indexer.cpp.
//
// Per chunk: build the local octree with a 32^3 counting sort (buildHierarchy),
// then subsample it bottom-up (SamplerPoisson); the chunk roots are parked in
// tmpChunkRoots.bin and finally merged and sampled up to the root (doMerging).
// Line references are to upstream indexer.cpp unless noted. Changes are listed in
// DEVIATIONS.md; the ones visible here:
//   D2  exit()/__debugbreak() -> ErrorState; file I/O checked
//   D6  thread_local scratch (pyramid, tmp VBuffer, offsets[]) -> per call
//   D7  function-level statics -> Indexer members
//   D8  serialize_stage_chunkroots / load_stage_chunkroots -> in-memory handoff
//   D9  console output / State bookkeeping dropped
//   D15 number formatting in createMetadata without std::format
//   D16 HierarchyFlusher refuses names longer than its 31-byte field
#include "indexer.h"

#include <cmath>
#include <filesystem>
#include <sstream>
#include <system_error>
#include <thread>

#include "hierarchy_builder.h"
#include "nlohmann/json.hpp"
#include "sampler_poisson.h"
#include "task_pool.h"

namespace aether::pointcloud_lod_build::pc::indexer {
namespace fs = std::filesystem;

// ---------------------------------------------------------------------------
// HierarchyFlusher (indexer.h:89-218)

HierarchyFlusher::HierarchyFlusher(const string& path_, ErrorState* error_) : path(path_), error(error_) {
  this->clear();
}

void HierarchyFlusher::clear() {
  std::error_code ec;
  fs::remove_all(path, ec);
  fs::create_directories(path, ec);
  if (ec) error->fail("cannot create " + path + ": " + ec.message());
}

void HierarchyFlusher::write(Node* node, int stepSize) {
  std::lock_guard<std::mutex> lock(mtx);

  HNode hnode;
  hnode.name = node->name;
  hnode.byteOffset = node->byteOffset;
  hnode.byteSize = node->byteSize;
  hnode.numPoints = node->numPoints;

  buffer.push_back(hnode);

  if (buffer.size() > 10'000) {
    this->write(buffer, stepSize);
    buffer.clear();
  }
}

void HierarchyFlusher::flush(int stepSize) {
  std::lock_guard<std::mutex> lock(mtx);
  this->write(buffer, stepSize);
  buffer.clear();
}

void HierarchyFlusher::write(const vector<HNode>& nodes, int stepSize) {
  std::unordered_map<string, vector<HNode>> groups;

  for (const auto& node : nodes) {
    string key = node.name.substr(0, size_t(stepSize + 1));
    if (int(node.name.size()) <= stepSize + 1) key = "r";

    if (groups.find(key) == groups.end()) groups[key] = vector<HNode>();

    groups[key].push_back(node);

    // add batch roots to batches (in addition to root batch)
    if (int(node.name.size()) == stepSize + 1) groups[node.name].push_back(node);
  }

  std::error_code ec;
  fs::create_directories(path, ec);

  // this structure, but guaranteed to be packed
  // struct Record{                 size   offset
  // 	uint8_t name[31];               31        0
  // 	uint32_t numPoints;              4       31
  // 	int64_t byteOffset;              8       35
  // 	int32_t byteSize;                4       43
  // 	uint8_t end = '\n';              1       47
  // };                              ===
  //                                  48
  for (auto& [key, groupedNodes] : groups) {
    Buffer record(int64_t(48 * groupedNodes.size()));
    if (!record.ok(int64_t(48 * groupedNodes.size()))) {
      error->fail("out of memory (hierarchy flush)");
      return;
    }

    for (size_t i = 0; i < groupedNodes.size(); i++) {
      const auto& node = groupedNodes[i];

      if (node.name.size() > 31) {  // D16: upstream memcpy would overrun into numPoints
        error->fail("octree deeper than the 31-character node name field: " + node.name);
        return;
      }

      std::memset(record.data_u8 + 48 * i, ' ', 31);
      std::memcpy(record.data_u8 + 48 * i, node.name.c_str(), node.name.size());
      record.set<uint32_t>(uint32_t(node.numPoints), int64_t(48 * i + 31));
      record.set<uint64_t>(uint64_t(node.byteOffset), int64_t(48 * i + 35));
      record.set<uint32_t>(uint32_t(node.byteSize), int64_t(48 * i + 43));
      record.set<char>('\n', int64_t(48 * i + 47));
    }

    string filepath = path + "/" + key + ".bin";
    std::fstream fout(filepath, std::ios::app | std::ios::out | std::ios::binary);
    fout.write(record.data_char, record.size);
    fout.close();
    if (!fout) {
      error->fail("write failed (disk full?): " + filepath);
      return;
    }

    if (chunks.find(key) == chunks.end()) chunks[key] = 0;
    chunks[key] += int(groupedNodes.size());
  }
}

// ---------------------------------------------------------------------------
// Indexer (indexer.h:309-322)

Indexer::Indexer(const string& targetDir_, int64_t writerCapacity, ErrorState* error_)
    : targetDir(targetDir_), error(error_) {
  writer = make_shared<Writer>(targetDir, writerCapacity, error);
  hierarchyFlusher = make_shared<HierarchyFlusher>(targetDir + "/.hierarchyChunks", error);

  string chunkRootFile = targetDir + "/tmpChunkRoots.bin";
  fChunkRoots.open(chunkRootFile, std::ios::out | std::ios::binary);
  if (!fChunkRoots) error->fail("cannot create " + chunkRootFile);
}

// indexer.cpp:201-220
void Indexer::flushChunkRoot(shared_ptr<Node> chunkRoot) {
  std::lock_guard<std::mutex> lock(mtx_chunkRoot);

  int64_t size = chunkRoot->points->size;

  fChunkRoots.write(reinterpret_cast<const char*>(chunkRoot->points->ptr), size);
  if (!fChunkRoots) error->fail("write to tmpChunkRoots.bin failed (disk full?)");

  FlushedChunkRoot fcr;
  fcr.node = chunkRoot;
  fcr.offset = chunkRootsOffset;
  fcr.size = size;

  chunkRoot->points = nullptr;

  flushedChunkRoots.push_back(fcr);

  chunkRootsOffset += size;
}

// indexer.cpp:222-301
vector<CRNode> Indexer::processChunkRoots() {
  std::unordered_map<string, shared_ptr<CRNode>> nodesMap;
  vector<shared_ptr<CRNode>> nodesList;

  // create/copy nodes
  this->root->traverse([&nodesMap, &nodesList](Node* node) {
    auto crnode = make_shared<CRNode>();
    crnode->name = node->name;
    crnode->node = node;
    crnode->children.resize(node->children.size());

    nodesList.push_back(crnode);
    nodesMap[crnode->name] = crnode;
  });

  // establish hierarchy
  for (auto& crnode : nodesList) {
    string parentName = crnode->name.substr(0, crnode->name.size() - 1);

    if (parentName != "") {
      auto parent = nodesMap[parentName];
      int index = crnode->name.at(crnode->name.size() - 1) - '0';

      parent->children[size_t(index)] = crnode;
    }
  }

  // mark/flag/insert flushed chunk roots
  for (auto& fcr : flushedChunkRoots) {
    shared_ptr<CRNode> node = nodesMap[fcr.node->name];

    node->fcrs.push_back(fcr);
    node->numPoints += fcr.node->numPoints;
  }

  // recursively merge leaves if sum(points) < threshold
  auto cr_root = nodesMap["r"];
  constexpr int64_t threshold = 5'000'000;

  cr_root->traversePost([](CRNode* node) {
    if (node->isLeaf()) {
    } else {
      i64 numPoints = 0;
      for (auto& child : node->children) {
        if (!child) continue;
        numPoints += child->numPoints;
      }
      node->numPoints = numPoints;

      if (node->numPoints < threshold) {
        // merge children into this node
        for (auto& child : node->children) {
          if (!child) continue;
          node->fcrs.insert(node->fcrs.end(), child->fcrs.begin(), child->fcrs.end());
        }

        node->children.clear();
      }
    }
  });

  vector<CRNode> tasks;
  cr_root->traverse([&tasks](CRNode* node) {
    if (node->fcrs.size() > 0) {
      CRNode crnode = *node;
      tasks.push_back(crnode);
    }
  });

  return tasks;
}

// indexer.cpp:347-359
void Indexer::waitUntilWriterBacklogBelow(int maxMegabytes) {
  using namespace std::chrono_literals;
  while (true) {
    auto backlog = writer->backlogSizeMB();
    if (backlog > maxMegabytes) {
      std::this_thread::sleep_for(10ms);
    } else {
      break;
    }
  }
}

// ---------------------------------------------------------------------------
// createMetadata (indexer.cpp:376-550)

namespace {

// D15: upstream formats doubles with std::format("{}"), i.e. std::to_chars'
// shortest round-trip form. Floating-point to_chars is not available on every
// mobile standard library we target, so the digits come from the vendored
// nlohmann/json Grisu2 (locale-independent, round-trip exact) and are laid out
// with to_chars' rule: fixed or scientific, whichever is shorter, fixed on a tie.
string formatDouble(double value) {
  if (!std::isfinite(value)) return "null";  // upstream would print "inf" (invalid JSON)
  if (value == 0.0) return std::signbit(value) ? "-0" : "0";

  char digits[32];
  int len = 0;
  int decimalExponent = 0;
  nlohmann::detail::dtoa_impl::grisu2(digits, len, decimalExponent, std::fabs(value));
  // value = 0.<digits> * 10^(decimalExponent + len)  ==  d.ddd * 10^E
  const int E = decimalExponent + len - 1;
  const string D(digits, size_t(len));
  const string sign = value < 0 ? "-" : "";

  string fixed;
  if (E >= 0) {
    if (len <= E + 1) {
      fixed = D + string(size_t(E + 1 - len), '0');
    } else {
      fixed = D.substr(0, size_t(E + 1)) + "." + D.substr(size_t(E + 1));
    }
  } else {
    fixed = "0." + string(size_t(-E - 1), '0') + D;
  }

  string sci = D.substr(0, 1);
  if (len > 1) sci += "." + D.substr(1);
  const int absE = E < 0 ? -E : E;
  sci += (E < 0 ? "e-" : "e+");
  if (absE < 10) sci += "0";
  sci += std::to_string(absE);

  return sign + (fixed.size() <= sci.size() ? fixed : sci);
}

string jsonString(const string& str) { return nlohmann::json(str).dump(); }

}  // namespace

string Indexer::createMetadata(int64_t pointsTotal, Hierarchy hierarchy) {
  auto min = root->min;
  auto max = root->max;

  auto d = [](double value) { return formatDouble(value); };
  auto s = [](const string& str) { return jsonString(str); };
  auto t = [](int numTabs) { return string(size_t(numTabs), '\t'); };
  auto toJson = [d](Vector3 value) { return "[" + d(value.x) + ", " + d(value.y) + ", " + d(value.z) + "]"; };
  auto vecToJson = [d](const vector<double>& values) {
    std::stringstream ss;
    ss << "[";
    for (size_t i = 0; i < values.size(); i++) {
      ss << d(values[i]);
      if (i < values.size() - 1) ss << ", ";
    }
    ss << "]";
    return ss.str();
  };
  auto vecI64ToJson = [](const vector<int64_t>& values) {
    std::stringstream ss;
    ss.imbue(std::locale::classic());
    ss << "[";
    for (size_t i = 0; i < values.size(); i++) {
      ss << values[i];
      if (i < values.size() - 1) ss << ", ";
    }
    ss << "]";
    return ss.str();
  };

  auto depth = this->octreeDepth;
  auto getHierarchyJsonString = [hierarchy, depth, t, s]() {
    std::stringstream ss;
    ss.imbue(std::locale::classic());
    ss << "{" << "\n";
    ss << t(2) << s("firstChunkSize") << ": " << hierarchy.firstChunkSize << ", " << "\n";
    ss << t(2) << s("stepSize") << ": " << hierarchy.stepSize << ", " << "\n";
    ss << t(2) << s("depth") << ": " << depth << "\n";
    ss << t(1) << "}";
    return ss.str();
  };

  auto getBoundingBoxJsonString = [min, max, t, s, toJson]() {
    std::stringstream ss;
    ss << "{" << "\n";
    ss << t(2) << s("min") << ": " << toJson(min) << ", " << "\n";
    ss << t(2) << s("max") << ": " << toJson(max) << "\n";
    ss << t(1) << "}";
    return ss.str();
  };

  Attributes& attrs = this->attributes;
  auto getAttributesJsonString = [&attrs, t, s, vecToJson, vecI64ToJson]() {
    std::stringstream ss;
    ss.imbue(std::locale::classic());
    ss << "[" << "\n";

    for (size_t i = 0; i < attrs.list.size(); i++) {
      auto& attribute = attrs.list[i];

      if (i == 0) ss << t(2) << "{" << "\n";

      ss << t(3) << s("name") << ": " << s(attribute.name) << "," << "\n";
      ss << t(3) << s("description") << ": " << s(attribute.description) << "," << "\n";
      ss << t(3) << s("size") << ": " << attribute.size << "," << "\n";
      ss << t(3) << s("numElements") << ": " << attribute.numElements << "," << "\n";
      ss << t(3) << s("elementSize") << ": " << attribute.elementSize << "," << "\n";
      ss << t(3) << s("type") << ": " << s(getAttributeTypename(attribute.type)) << "," << "\n";

      bool emptyHistogram = true;
      for (size_t k = 0; k < attribute.histogram.size(); k++) {
        if (attribute.histogram[k] != 0) emptyHistogram = false;
      }

      if (attribute.size == 1 && !emptyHistogram) {
        ss << t(3) << s("histogram") << ": " << vecI64ToJson(attribute.histogram) << ", " << "\n";
      }

      if (attribute.numElements == 1) {
        ss << t(3) << s("min") << ": " << vecToJson(vector<double>{attribute.min.x}) << "," << "\n";
        ss << t(3) << s("max") << ": " << vecToJson(vector<double>{attribute.max.x}) << "," << "\n";
        ss << t(3) << s("scale") << ": " << vecToJson(vector<double>{attribute.scale.x}) << "," << "\n";
        ss << t(3) << s("offset") << ": " << vecToJson(vector<double>{attribute.offset.x}) << "\n";
      } else if (attribute.numElements == 2) {
        ss << t(3) << s("min") << ": " << vecToJson(vector<double>{attribute.min.x, attribute.min.y}) << "," << "\n";
        ss << t(3) << s("max") << ": " << vecToJson(vector<double>{attribute.max.x, attribute.max.y}) << "," << "\n";
        ss << t(3) << s("scale") << ": " << vecToJson(vector<double>{attribute.scale.x, attribute.scale.y}) << "," << "\n";
        ss << t(3) << s("offset") << ": " << vecToJson(vector<double>{attribute.offset.x, attribute.offset.y}) << "\n";
      } else if (attribute.numElements == 3) {
        ss << t(3) << s("min") << ": " << vecToJson(vector<double>{attribute.min.x, attribute.min.y, attribute.min.z}) << "," << "\n";
        ss << t(3) << s("max") << ": " << vecToJson(vector<double>{attribute.max.x, attribute.max.y, attribute.max.z}) << "," << "\n";
        ss << t(3) << s("scale") << ": " << vecToJson(vector<double>{attribute.scale.x, attribute.scale.y, attribute.scale.z}) << "," << "\n";
        ss << t(3) << s("offset") << ": " << vecToJson(vector<double>{attribute.offset.x, attribute.offset.y, attribute.offset.z}) << "\n";
      }

      if (i < attrs.list.size() - 1) {
        ss << t(2) << "},{" << "\n";
      } else {
        ss << t(2) << "}" << "\n";
      }
    }

    ss << t(1) << "]";
    return ss.str();
  };

  std::stringstream ss;
  ss.imbue(std::locale::classic());

  ss << t(0) << "{" << "\n";
  ss << t(1) << s("version") << ": " << s("2.0") << "," << "\n";
  ss << t(1) << s("name") << ": " << s(name) << "," << "\n";
  ss << t(1) << s("description") << ": " << s("") << "," << "\n";
  ss << t(1) << s("points") << ": " << pointsTotal << "," << "\n";
  ss << t(1) << s("projection") << ": " << s("") << "," << "\n";
  ss << t(1) << s("hierarchy") << ": " << getHierarchyJsonString() << "," << "\n";
  ss << t(1) << s("offset") << ": " << toJson(attributes.posOffset) << "," << "\n";
  ss << t(1) << s("scale") << ": " << toJson(attributes.posScale) << "," << "\n";
  ss << t(1) << s("spacing") << ": " << d(spacing) << "," << "\n";
  ss << t(1) << s("boundingBox") << ": " << getBoundingBoxJsonString() << "," << "\n";
  ss << t(1) << s("encoding") << ": " << s("DEFAULT") << "," << "\n";
  ss << t(1) << s("attributes") << ": " << getAttributesJsonString() << "\n";
  ss << t(0) << "}" << "\n";

  return ss.str();
}

// ---------------------------------------------------------------------------
// Local octree construction (indexer.cpp:707-1132)

namespace {

struct NodeCandidate {  // :707-715
  string name = "";
  int64_t indexStart = 0;
  int64_t numPoints = 0;
  int64_t level = 0;
  int64_t x = 0;
  int64_t y = 0;
  int64_t z = 0;
};

struct Pyramid {  // :717-721
  i64 maxLevel = 0;
  vector<vector<i64>> counters;
  vector<vector<i64>> prefixSum;
};

// :723-763
void computeSumPyramid(Pyramid* pyramid) {
  // Compute counters in lower LODs
  for (i64 level = pyramid->maxLevel - 1; level >= 0; level--) {
    i64 currentGridSize = i64(std::pow(2, level));

    for (i64 x = 0; x < currentGridSize; x++) {
      for (i64 y = 0; y < currentGridSize; y++) {
        for (i64 z = 0; z < currentGridSize; z++) {
          auto index = mortonEncode_magicbits(unsigned(z), unsigned(y), unsigned(x));
          auto index_p1 = mortonEncode_magicbits(unsigned(2 * z), unsigned(2 * y), unsigned(2 * x));

          int64_t sum = 0;
          for (uint64_t i = 0; i < 8; i++) {
            sum += pyramid->counters[size_t(level + 1)][index_p1 + i];
          }

          pyramid->counters[size_t(level)][index] = sum;
        }
      }
    }
  }

  // Compute prefix sum
  for (i64 level = 0; level <= pyramid->maxLevel; level++) {
    i64 gridsize = i64(std::pow(2, level));
    i64 numCells = gridsize * gridsize * gridsize;

    auto& counters = pyramid->counters[size_t(level)];
    auto& prefixSum = pyramid->prefixSum[size_t(level)];
    prefixSum[0] = 0;

    for (i64 i = 1; i < numCells; i++) {
      prefixSum[size_t(i)] = prefixSum[size_t(i - 1)] + counters[size_t(i - 1)];
    }
  }
}

// :765-827
vector<NodeCandidate> createNodes(Pyramid* pyramid) {
  vector<NodeCandidate> nodes;

  NodeCandidate root;
  root.name = "";
  root.level = 0;
  root.x = 0;
  root.y = 0;
  root.z = 0;

  vector<NodeCandidate> stack = {root};

  while (!stack.empty()) {
    NodeCandidate candidate = stack.back();
    stack.pop_back();

    auto level = candidate.level;
    auto x = candidate.x;
    auto y = candidate.y;
    auto z = candidate.z;

    auto index = mortonEncode_magicbits(unsigned(z), unsigned(y), unsigned(x));
    i64 numPoints = pyramid->counters[size_t(level)][index];

    if (level == pyramid->maxLevel) {
      // don't split further at this time. May be split further in another pass
      if (numPoints > 0) nodes.push_back(candidate);
    } else if (numPoints > maxPointsPerChunk) {
      // split (too many points in node)
      for (int i = 0; i < 8; i++) {
        auto index_p1 = mortonEncode_magicbits(unsigned(2 * z), unsigned(2 * y), unsigned(2 * x)) + uint64_t(i);
        auto count = pyramid->counters[size_t(level + 1)][index_p1];

        if (count > 0) {
          NodeCandidate child;
          child.level = level + 1;
          child.name = candidate.name + std::to_string(i);
          child.indexStart = pyramid->prefixSum[size_t(level + 1)][index_p1];
          child.numPoints = count;
          child.x = 2 * x + ((i & 0b100) >> 2);
          child.y = 2 * y + ((i & 0b010) >> 1);
          child.z = 2 * z + ((i & 0b001) >> 0);

          stack.push_back(child);
        }
      }
    } else if (numPoints > 0) {
      // accept (small enough)
      nodes.push_back(candidate);
    }
  }

  return nodes;
}

// :829-858
inline i64 gridIndexOf(i64 pointIndex, const uint8_t* points, i64 bpp, Vector3 scale, Vector3 offset,
                       Vector3 min, Vector3 size, i64 counterGridSize) {
  i64 pointOffset = pointIndex * bpp;
  int32_t xyz[3];
  std::memcpy(xyz, points + pointOffset, 12);

  double x = (xyz[0] * scale.x) + offset.x;
  double y = (xyz[1] * scale.y) + offset.y;
  double z = (xyz[2] * scale.z) + offset.z;

  i64 ix = i64(double(counterGridSize) * (x - min.x) / size.x);
  i64 iy = i64(double(counterGridSize) * (y - min.y) / size.y);
  i64 iz = i64(double(counterGridSize) * (z - min.z) / size.z);

  ix = std::max(i64(0), std::min(ix, counterGridSize - 1));
  iy = std::max(i64(0), std::min(iy, counterGridSize - 1));
  iz = std::max(i64(0), std::min(iz, counterGridSize - 1));

  i64 index = i64(mortonEncode_magicbits(unsigned(iz), unsigned(iy), unsigned(ix)));

  return index;
}

// :860-892
Node* expandTo(Node* node, NodeCandidate& candidate) {
  string startName = node->name;
  string fullName = startName + candidate.name;

  // e.g. startName: r, fullName: r031
  // start iteration with char at index 1: "0"

  Node* currentNode = node;
  for (size_t i = startName.size(); i < fullName.size(); i++) {
    int64_t index = fullName.at(i) - '0';

    if (currentNode->children[size_t(index)] == nullptr) {
      auto childBox = childBoundingBoxOf(currentNode->min, currentNode->max, int(index));
      string childName = currentNode->name + std::to_string(index);

      shared_ptr<Node> child = make_shared<Node>();
      child->min = childBox.min;
      child->max = childBox.max;
      child->name = childName;
      child->children.resize(8);

      currentNode->children[size_t(index)] = child;
      currentNode = child.get();
    } else {
      currentNode = currentNode->children[size_t(index)].get();
    }
  }

  return currentNode;
}

// :898-1132
// 1. Counter grid
// 2. Hierarchy from counter grid
// 3. identify nodes that need further refinment
// 4. Recursively repeat at 1. for identified nodes
void buildHierarchy(Indexer* indexer, Node* node, shared_ptr<Buffer> points, int64_t numPoints, int64_t depth = 0) {
  ErrorState* error = indexer->error;
  if (error->failed()) return;

  if (numPoints < maxPointsPerChunk) {
    Node* realization = node;
    realization->indexStart = 0;
    realization->numPoints = numPoints;
    realization->points = VBufferPool::acquire();
    if (!realization->points->commit(points->size)) {
      error->fail("out of memory (buildHierarchy leaf)");
      return;
    }
    if (points->size > 0) std::memcpy(realization->points->ptr, points->data, size_t(points->size));

    return;
  }

  constexpr i64 levels = 5;            // = gridSize 32
  constexpr i64 counterGridSize = 32;  // pow(2, levels);
  constexpr i64 counterGridNumElements = counterGridSize * counterGridSize * counterGridSize;

  // init counter pyramid data (D6: was a leaked thread_local Pyramid*)
  Pyramid pyramidStorage;
  Pyramid* pyramid = &pyramidStorage;
  pyramid->maxLevel = levels;
  pyramid->counters.resize(size_t(pyramid->maxLevel + 1));
  pyramid->prefixSum.resize(size_t(pyramid->maxLevel + 1));
  for (i64 level = 0; level <= pyramid->maxLevel; level++) {
    i64 gridSize = i64(std::pow(2, level));
    i64 numCells = gridSize * gridSize * gridSize;
    pyramid->counters[size_t(level)].assign(size_t(numCells), 0);
    pyramid->prefixSum[size_t(level)].assign(size_t(numCells), 0);
  }

  Vector3 min = node->min;
  Vector3 max = node->max;
  Vector3 size = max - min;
  Attributes attributes = indexer->attributes;
  i64 bpp = attributes.bytes;
  Vector3 scale = attributes.posScale;
  Vector3 offset = attributes.posOffset;

  // COUNTING
  auto& finest = pyramid->counters[size_t(pyramid->maxLevel)];
  std::fill(finest.begin(), finest.end(), 0);
  for (int64_t i = 0; i < numPoints; i++) {
    auto index = gridIndexOf(i, points->data_u8, bpp, scale, offset, min, size, counterGridSize);
    finest[size_t(index)]++;
  }

  // Update counters in lower levels of pyramid, and compute prefix sum
  computeSumPyramid(pyramid);

  {  // DISTRIBUTING
    // D6: was `thread_local shared_ptr<VBuffer> tmp = VBuffer::create(2'000'000'000)`
    Buffer tmp(numPoints * bpp);
    if (!tmp.ok(numPoints * bpp)) {
      error->fail("out of memory (buildHierarchy distribute)");
      return;
    }

    vector<i64> offsets(pyramid->prefixSum[size_t(pyramid->maxLevel)].begin(),
                        pyramid->prefixSum[size_t(pyramid->maxLevel)].end());  // D6: was thread_local i64[32768]
    static_assert(counterGridNumElements == 32768);

    for (i64 i = 0; i < numPoints; i++) {
      i64 index = gridIndexOf(i, points->data_u8, bpp, scale, offset, min, size, counterGridSize);
      i64 targetIndex = offsets[size_t(index)]++;

      if (targetIndex * bpp >= tmp.size) {  // :965-967 upstream __debugbreak()
        error->fail("buildHierarchy: counting sort overflow");
        return;
      }

      std::memcpy(tmp.data_u8 + targetIndex * bpp, points->data_u8 + i * bpp, size_t(bpp));
    }

    std::memcpy(points->data, tmp.data, size_t(numPoints * bpp));
  }

  vector<NodeCandidate> nodes = createNodes(pyramid);
  vector<Node*> needRefinement;

  // Turn candidates into actual nodes
  int64_t octreeDepth = 0;
  for (NodeCandidate& candidate : nodes) {
    Node* realization = expandTo(node, candidate);
    realization->indexStart = candidate.indexStart;
    realization->numPoints = candidate.numPoints;
    int64_t bytes = candidate.numPoints * bpp;

    shared_ptr<VBuffer> buffer = VBufferPool::acquire();
    if (!buffer->commit(bytes)) {
      error->fail("out of memory (buildHierarchy node)");
      return;
    }
    std::memcpy(buffer->ptr, points->data_u8 + candidate.indexStart * bpp, size_t(candidate.numPoints * bpp));

    realization->points = buffer;

    if (realization->numPoints > maxPointsPerChunk) needRefinement.push_back(realization);

    octreeDepth = std::max(octreeDepth, realization->level());
  }

  {
    std::lock_guard<std::mutex> lock(indexer->mtx_depth);
    indexer->octreeDepth = std::max(indexer->octreeDepth, octreeDepth);
  }

  for (int64_t nodeIndex = 0; nodeIndex < int64_t(needRefinement.size()); nodeIndex++) {
    auto subject = needRefinement[size_t(nodeIndex)];
    if (subject->points == nullptr) {
      // Upstream dereferences null here when the duplicate-removal retry (:1119-1120,
      // nodeIndex--) revisits a subject whose recursion left it without points.
      error->fail("buildHierarchy: duplicate-point refinement left a node without points");
      return;
    }
    shared_ptr<Buffer> buffer = make_shared<Buffer>(subject->points->size);
    if (!buffer->ok(subject->points->size)) {
      error->fail("out of memory (buildHierarchy refine)");
      return;
    }
    std::memcpy(buffer->data, subject->points->ptr, size_t(subject->points->size));

    if (subject->numPoints == numPoints) {
      // the subsplit has the same number of points than the input -> ERROR
      std::unordered_map<string, int> counters;

      for (int64_t i = 0; i < numPoints; i++) {
        int64_t sourceOffset = i * bpp;

        int32_t X, Y, Z;
        std::memcpy(&X, buffer->data_u8 + sourceOffset + 0, 4);
        std::memcpy(&Y, buffer->data_u8 + sourceOffset + 4, 4);
        std::memcpy(&Z, buffer->data_u8 + sourceOffset + 8, 4);

        std::stringstream ss;
        ss << X << ", " << Y << ", " << Z;

        string key = ss.str();
        counters[key]++;
      }

      int64_t numPointsInBox = subject->numPoints;
      int64_t numUniquePoints = int64_t(counters.size());
      int64_t numDuplicates = numPointsInBox - numUniquePoints;

      if (numDuplicates < maxPointsPerChunk / 2) {
        // few uniques, just unfavouribly distributed points
        // (upstream: warning, conversion continues)
      } else {
        // remove the duplicates, then try again

        vector<int64_t> distinct;
        std::unordered_map<string, int> handled;

        auto contains = [](auto const& map, auto const& key) { return map.find(key) != map.end(); };

        for (int64_t i = 0; i < numPoints; i++) {
          int64_t sourceOffset = i * bpp;

          int32_t X, Y, Z;
          std::memcpy(&X, buffer->data_u8 + sourceOffset + 0, 4);
          std::memcpy(&Y, buffer->data_u8 + sourceOffset + 4, 4);
          std::memcpy(&Z, buffer->data_u8 + sourceOffset + 8, 4);

          std::stringstream ss;
          ss << X << ", " << Y << ", " << Z;

          string key = ss.str();

          if (contains(counters, key)) {
            if (!contains(handled, key)) {
              distinct.push_back(i);
              handled[key] = true;
            }
          } else {
            distinct.push_back(i);
          }
        }

        // (upstream: warning "Duplicates inside node will be dropped!")
        shared_ptr<VBuffer> distinctBuffer = VBufferPool::acquire();
        if (!distinctBuffer->commit(int64_t(distinct.size()) * bpp)) {
          error->fail("out of memory (buildHierarchy dedup)");
          return;
        }

        for (size_t i = 0; i < distinct.size(); i++) {
          std::memcpy(distinctBuffer->ptr + int64_t(i) * bpp, buffer->data_u8 + distinct[i] * bpp, size_t(bpp));
        }

        subject->points = distinctBuffer;
        subject->numPoints = int64_t(distinct.size());

        // try again
        nodeIndex--;
      }
    }

    int64_t nextNumPoins = subject->numPoints;

    subject->points = nullptr;
    subject->numPoints = 0;

    buildHierarchy(indexer, subject, buffer, nextNumPoins, depth + 1);
    if (error->failed()) return;
  }
}

}  // namespace

// ---------------------------------------------------------------------------
// doIndexing (indexer.cpp:1414-1665) + doMerging (:1667-1789)

bool doIndexingAndMerging(const string& targetDir, const string& chunkDir, const ChunkedMetadata& chunked,
                          int64_t pointsTotal, const IndexingConfig& config, ErrorState* error) {
  // getChunks (:60-199): chunk files from the directory listing, attributes and
  // bounds from the chunker in memory (D8)
  auto chunks = make_shared<Chunks>();
  chunks->min = chunked.min;
  chunks->max = chunked.max;
  chunks->attributes = chunked.attributes;
  {
    auto toID = [](string filename) -> string {
      auto strip = [](string str, const string& search) {
        auto index = str.find(search);
        if (index != string::npos) str.replace(index, search.length(), "");
        return str;
      };
      string strID = strip(filename, "chunk_");
      strID = strip(strID, ".bin");
      strID = strip(strID, ".br");
      return strID;
    };

    string chunkDirectory = chunkDir + "/chunks";
    std::error_code ec;
    for (fs::directory_iterator it(chunkDirectory, ec), end; !ec && it != end; it.increment(ec)) {
      string filename = it->path().filename().string();
      string chunkID = toID(filename);

      if (it->path().extension().string() != ".bin") continue;  // not a chunk format

      shared_ptr<Chunk> chunk = make_shared<Chunk>();
      chunk->file = it->path().string();
      chunk->id = chunkID;

      BoundingBox box = {chunks->min, chunks->max};
      for (size_t i = 1; i < chunkID.size(); i++) {
        int index = chunkID[i] - '0';  // this feels so wrong...
        box = childBoundingBoxOf(box.min, box.max, index);
      }

      chunk->min = box.min;
      chunk->max = box.max;

      chunks->list.push_back(chunk);
    }
    if (ec) {
      error->fail("cannot list " + chunkDirectory + ": " + ec.message());
      return false;
    }
  }

  Attributes attributes = chunks->attributes;

  Indexer indexer(targetDir, config.writerCapacity, error);
  indexer.name = config.name;
  indexer.attributes = attributes;
  indexer.root = make_shared<Node>("r", chunks->min, chunks->max);
  indexer.spacing = (chunks->max - chunks->min).x / 128.0;
  if (error->failed()) return false;

  auto onNodeCompleted = [&indexer](Node* node) {
    indexer.writer->writeAndUnload(node);
    indexer.hierarchyFlusher->write(node, hierarchyStepSize);
  };

  auto onNodeDiscarded = [](Node*) {};

  struct Task {
    shared_ptr<Chunk> chunk;
    explicit Task(shared_ptr<Chunk> c) : chunk(c) {}
  };

  std::mutex mtx_nodes;
  vector<shared_ptr<Node>> nodes;

  {
    TaskPool<Task> pool(size_t(config.numThreads), [&](shared_ptr<Task> task) {
      if (error->failed()) return;

      auto chunk = task->chunk;
      auto chunkRoot = make_shared<Node>(chunk->id, chunk->min, chunk->max);
      int64_t bpp = attributes.bytes;

      indexer.waitUntilWriterBacklogBelow(1'000);

      shared_ptr<Buffer> pointBuffer = readBinaryFile(chunk->file, error);
      if (!pointBuffer) return;

      if (!config.keepChunks) {
        std::error_code ec;
        fs::remove(chunk->file, ec);
      }

      int64_t numPoints = pointBuffer->size / bpp;

      buildHierarchy(&indexer, chunkRoot.get(), pointBuffer, numPoints);
      if (error->failed()) return;

      SamplerPoisson sampler(error);
      sampler.sample(chunkRoot.get(), attributes, indexer.spacing, onNodeCompleted, onNodeDiscarded);
      if (error->failed()) return;

      // detach anything below the chunk root. Will be reloaded from
      // temporarily flushed hierarchy during creation of the hierarchy file
      chunkRoot->children.clear();

      indexer.flushChunkRoot(chunkRoot);

      // add chunk root, provided it isn't the root.
      if (chunkRoot->name.size() > 1) indexer.root->addDescendant(chunkRoot);

      std::lock_guard<std::mutex> lock(mtx_nodes);
      nodes.push_back(chunkRoot);
    });

    for (auto& chunk : chunks->list) pool.addTask(make_shared<Task>(chunk));

    pool.waitTillEmpty();
    pool.close();
  }

  indexer.fChunkRoots.close();
  if (!indexer.fChunkRoots) error->fail("write to tmpChunkRoots.bin failed (disk full?)");
  if (error->failed()) return false;

  // ---- doMerging (:1667-1789); the checkpoint round trip is skipped (D8) ----
  {  // process chunk roots in batches
    string tmpChunkRootsPath = targetDir + "/tmpChunkRoots.bin";
    auto tasks = indexer.processChunkRoots();

    std::ifstream fin(tmpChunkRootsPath, std::ios::binary);
    if (!fin) {
      error->fail("cannot open " + tmpChunkRootsPath);
      return false;
    }

    for (auto& task : tasks) {
      for (auto& fcr : task.fcrs) {
        shared_ptr<VBuffer> buffer = VBufferPool::acquire();
        if (!buffer->commit(fcr.size)) {
          error->fail("out of memory (merging)");
          return false;
        }
        fin.seekg(fcr.offset);
        if (fcr.size > 0 && !fin.read(reinterpret_cast<char*>(buffer->ptr), fcr.size)) {
          error->fail("cannot read " + tmpChunkRootsPath);
          return false;
        }

        fcr.node->points = buffer;
      }

      SamplerPoisson sampler(error);
      sampler.sample(task.node, attributes, indexer.spacing, onNodeCompleted, onNodeDiscarded);
      if (error->failed()) return false;

      task.node->children.clear();
    }
  }

  // sample up to root node
  if (chunks->list.size() == 1) {
    auto node = nodes[0];
    indexer.root = node;
  } else if (!indexer.root->sampled) {
    SamplerPoisson sampler(error);
    sampler.enableTrace = true;
    sampler.sample(indexer.root.get(), attributes, indexer.spacing, onNodeCompleted, onNodeDiscarded);
    if (error->failed()) return false;
  }

  // root is automatically finished after subsampling all descendants
  onNodeCompleted(indexer.root.get());

  indexer.writer->closeAndWait();

  indexer.hierarchyFlusher->flush(hierarchyStepSize);
  if (error->failed()) return false;

  string hierarchyDir = indexer.targetDir + "/.hierarchyChunks";
  HierarchyBuilder builder(hierarchyDir, hierarchyStepSize, error);
  if (!builder.build()) return false;

  Hierarchy hierarchy;
  hierarchy.stepSize = hierarchyStepSize;
  hierarchy.firstChunkSize = builder.batch_root->byteSize;

  string metadataPath = targetDir + "/metadata.json";
  string metadata = indexer.createMetadata(pointsTotal, hierarchy);
  {
    std::ofstream out(metadataPath, std::ios::binary);
    out << metadata;
    out.close();
    if (!out) {
      error->fail("cannot write " + metadataPath);
      return false;
    }
  }

  {  // deleting temporary files (:1764-1785)
    std::error_code ec;
    if (!config.keepChunks) fs::remove_all(chunkDir + "/chunks", ec);
    fs::remove(targetDir + "/tmpChunkRoots.bin", ec);
  }

  return !error->failed();
}

}  // namespace aether::pointcloud_lod_build::pc::indexer
