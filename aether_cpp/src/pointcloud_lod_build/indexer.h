// Port of PotreeConverter 2.0 @ 8bfad98 (BSD-2-Clause): Converter/include/indexer.h.
#pragma once

#include <fstream>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

#include "chunker_countsort.h"
#include "upstream_base.h"
#include "writer.h"

namespace aether::pointcloud_lod_build::pc::indexer {

constexpr int maxPointsPerChunk = 10'000;  // indexer.h:49
constexpr int hierarchyStepSize = 4;       // indexer.cpp:26

struct Hierarchy {  // indexer.h:55-59
  int64_t stepSize = 0;
  int64_t firstChunkSize = 0;
};

struct Chunk {  // indexer.h:61-67
  Vector3 min;
  Vector3 max;
  string file;
  string id;
};

struct Chunks {  // indexer.h:69-85
  vector<shared_ptr<Chunk>> list;
  Vector3 min;
  Vector3 max;
  Attributes attributes;
};

// indexer.h:89-218
struct HierarchyFlusher {
  struct HNode {
    string name;
    int64_t byteOffset = 0;
    int64_t byteSize = 0;
    int64_t numPoints = 0;
  };

  std::mutex mtx;
  string path;
  std::unordered_map<string, int> chunks;
  vector<HNode> buffer;
  ErrorState* error = nullptr;

  HierarchyFlusher(const string& path_, ErrorState* error_);
  void clear();
  void write(Node* node, int stepSize);
  void flush(int stepSize);
  void write(const vector<HNode>& nodes, int stepSize);
};

struct FlushedChunkRoot {  // indexer.h:225-229
  shared_ptr<Node> node;
  int64_t offset = 0;
  int64_t size = 0;
};

// indexer.h:231-274
struct CRNode {
  string name = "";
  Node* node = nullptr;
  vector<shared_ptr<CRNode>> children;
  vector<FlushedChunkRoot> fcrs;
  i64 numPoints = 0;

  CRNode() { children.resize(8, nullptr); }

  void traverse(const function<void(CRNode*)>& callback) {
    callback(this);
    for (auto& child : children) {
      if (child != nullptr) child->traverse(callback);
    }
  }

  void traversePost(const function<void(CRNode*)>& callback) {
    for (auto& child : children) {
      if (child != nullptr) child->traversePost(callback);
    }
    callback(this);
  }

  bool isLeaf() const {
    for (auto& child : children) {
      if (child != nullptr) return false;
    }
    return true;
  }
};

// indexer.h:276-347
struct Indexer {
  string targetDir = "";
  string name = "";

  Attributes attributes;
  shared_ptr<Node> root;

  shared_ptr<Writer> writer;
  shared_ptr<HierarchyFlusher> hierarchyFlusher;

  double spacing = 1.0;

  std::mutex mtx_depth;
  int64_t octreeDepth = 0;

  std::mutex mtx_chunkRoot;
  std::fstream fChunkRoots;
  vector<FlushedChunkRoot> flushedChunkRoots;
  int64_t chunkRootsOffset = 0;  // `static int64_t offset` in flushChunkRoot (D7)

  ErrorState* error = nullptr;

  Indexer(const string& targetDir_, int64_t writerCapacity, ErrorState* error_);
  ~Indexer() { fChunkRoots.close(); }

  void waitUntilWriterBacklogBelow(int maxMegabytes);
  string createMetadata(int64_t pointsTotal, Hierarchy hierarchy);
  void flushChunkRoot(shared_ptr<Node> chunkRoot);
  vector<CRNode> processChunkRoots();
};

struct IndexingConfig {
  int numThreads = 1;              // indexer.cpp:1476 numSampleThreads() / 3 + 2
  int64_t writerCapacity = 1024 * 1024 * 1024;
  bool keepChunks = false;
  string name;
};

// doIndexing (indexer.cpp:1414-1665) followed by doMerging (:1667-1789), with the
// stage_chunkroots checkpoint handed over in memory (D8).
bool doIndexingAndMerging(const string& targetDir, const string& chunkDir, const ChunkedMetadata& chunked,
                          int64_t pointsTotal, const IndexingConfig& config, ErrorState* error);

}  // namespace aether::pointcloud_lod_build::pc::indexer
