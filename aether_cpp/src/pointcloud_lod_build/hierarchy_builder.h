// Port of PotreeConverter 2.0 @ 8bfad98 (BSD-2-Clause):
// Converter/include/HierarchyBuilder.h -- turns the 48-byte node records that
// HierarchyFlusher appended to <outdir>/.hierarchyChunks/<batch>.bin into
// hierarchy.bin (22 B per node: type u8, childMask u8, numPoints u32,
// byteOffset u64, byteSize u64; :269-273).
//
// Changes (DEVIATIONS.md): exit(123) and unchecked file I/O -> ErrorState (D2);
// fs calls use the std::error_code overloads (-fno-exceptions).
#pragma once

#include <algorithm>
#include <filesystem>
#include <fstream>
#include <memory>
#include <string>
#include <system_error>
#include <unordered_map>
#include <vector>

#include "upstream_base.h"

namespace aether::pointcloud_lod_build::pc {

// unsuck.hpp:382-394 with the missing fopen/fread checks added (D2).
inline shared_ptr<Buffer> readBinaryFile(const string& path, ErrorState* error) {
  std::error_code ec;
  auto size = std::filesystem::file_size(path, ec);
  if (ec) {
    error->fail("cannot stat " + path + ": " + ec.message());
    return nullptr;
  }
  auto buffer = make_shared<Buffer>(static_cast<int64_t>(size));
  if (!buffer->ok(static_cast<int64_t>(size))) {
    error->fail("out of memory reading " + path);
    return nullptr;
  }
  std::ifstream f(path, std::ios::binary);
  if (size > 0 && !f.read(buffer->data_char, static_cast<std::streamsize>(size))) {
    error->fail("cannot read " + path);
    return nullptr;
  }
  return buffer;
}

struct HierarchyBuilder {
  int hierarchyStepSize = 0;
  string path = "";
  ErrorState* error = nullptr;

  enum TYPE {
    NORMAL = 0,
    LEAF = 1,
    PROXY = 2,
  };

  struct HNode {
    string name = "";
    int numPoints = 0;
    uint8_t childMask = 0;
    uint64_t byteOffset = 0;
    uint64_t byteSize = 0;
    TYPE type = TYPE::LEAF;
    uint64_t proxyByteOffset = 0;
    uint64_t proxyByteSize = 0;
  };

  struct HChunk {
    string name;
    vector<shared_ptr<HNode>> nodes;
    int64_t byteOffset = 0;
  };

  struct HBatch {
    string name;
    string path;
    int numNodes = 0;
    int64_t byteSize = 0;
    vector<shared_ptr<HNode>> nodes;
    vector<shared_ptr<HChunk>> chunks;
    std::unordered_map<string, shared_ptr<HNode>> nodeMap;
    std::unordered_map<string, shared_ptr<HChunk>> chunkMap;
  };

  shared_ptr<HBatch> batch_root;

  HierarchyBuilder(const string& path_, int hierarchyStepSize_, ErrorState* error_)
      : hierarchyStepSize(hierarchyStepSize_), path(path_), error(error_) {}

  // :82-197
  shared_ptr<HBatch> loadBatch(const string& batchPath) {
    shared_ptr<Buffer> buffer = readBinaryFile(batchPath, error);
    if (!buffer) return nullptr;

    auto batch = make_shared<HBatch>();
    batch->path = batchPath;
    batch->name = std::filesystem::path(batchPath).stem().string();
    batch->numNodes = int(buffer->size / 48);

    // group this batch in chunks of <hierarchyStepSize>
    for (int i = 0; i < batch->numNodes; i++) {
      int recordOffset = 48 * i;

      string nodeName = string(buffer->data_char + recordOffset, 31);
      nodeName.erase(std::remove(nodeName.begin(), nodeName.end(), ' '), nodeName.end());

      auto node = make_shared<HNode>();
      node->name = nodeName;
      node->numPoints = int(buffer->get<uint32_t>(recordOffset + 31));
      node->byteOffset = uint64_t(buffer->get<int64_t>(recordOffset + 35));
      node->byteSize = uint64_t(buffer->get<int32_t>(recordOffset + 43));

      // r: 0, r0123: 1, r01230123: 2
      int chunkLevel = int(node->name.size() - 2) / 4;
      string key = node->name.substr(0, size_t(hierarchyStepSize * chunkLevel + 1));
      if (node->name == batch->name) key = node->name;

      if (batch->chunkMap.find(key) == batch->chunkMap.end()) {
        auto chunk = make_shared<HChunk>();
        chunk->name = key;
        batch->chunkMap[key] = chunk;
        batch->chunks.push_back(chunk);
      }

      batch->chunkMap[key]->nodes.push_back(node);
      batch->nodes.push_back(node);
      batch->nodeMap[node->name] = batch->nodes[batch->nodes.size() - 1];

      bool isChunkKey = ((int(node->name.size()) - 1) % hierarchyStepSize) == 0;
      bool isBatchSubChunk = int(node->name.size()) > hierarchyStepSize + 1;
      if (isChunkKey && isBatchSubChunk) {
        if (batch->chunkMap.find(node->name) == batch->chunkMap.end()) {
          auto chunk = make_shared<HChunk>();
          chunk->name = node->name;
          batch->chunkMap[node->name] = chunk;
          batch->chunks.push_back(chunk);
        }

        batch->chunkMap[node->name]->nodes.push_back(node);
      }
    }

    // breadth-first sorted list of chunks
    std::sort(batch->chunks.begin(), batch->chunks.end(), [](const shared_ptr<HChunk>& a, const shared_ptr<HChunk>& b) {
      if (a->name.size() != b->name.size()) return a->name.size() < b->name.size();
      return a->name < b->name;
    });

    // initialize all nodes as leaf nodes, turn into "normal" if child appears
    // also notify parent that it has a child!
    for (auto& node : batch->nodes) {
      node->type = TYPE::LEAF;

      string parentName = node->name.substr(0, node->name.size() - 1);

      auto ptrParent = batch->nodeMap.find(parentName);

      if (ptrParent != batch->nodeMap.end()) {
        int childIndex = node->name.back() - '0';
        ptrParent->second->type = TYPE::NORMAL;
        ptrParent->second->childMask = uint8_t(ptrParent->second->childMask | (1 << childIndex));
      }
    }

    // find and flag proxy nodes (pseudo-leaf in one chunk pointing to root of a child-chunk)
    for (auto& chunk : batch->chunks) {
      auto ptr = batch->nodeMap.find(chunk->name);

      if (ptr != batch->nodeMap.end()) {
        ptr->second->type = TYPE::PROXY;
      } else {
        // could not find a node with the chunk's name
        // should only happen if this chunk's root
        // is equal to the batch root
        if (chunk->name != batch->name) {  // :178-181, upstream exit(123)
          error->fail("hierarchy: could not find chunk " + chunk->name + " in batch " + batch->name);
          return nullptr;
        }
      }
    }

    // sort nodes in chunks in breadth-first order
    for (auto& chunk : batch->chunks) {
      std::sort(chunk->nodes.begin(), chunk->nodes.end(), [](const shared_ptr<HNode>& a, const shared_ptr<HNode>& b) {
        if (a->name.size() != b->name.size()) return a->name.size() < b->name.size();
        return a->name < b->name;
      });
    }

    return batch;
  }

  // :199-238
  bool processBatch(shared_ptr<HBatch> batch) {
    // compute byte offsets of chunks relative to batch
    int64_t byteOffset = 0;
    for (auto& chunk : batch->chunks) {
      chunk->byteOffset = byteOffset;

      if (chunk->name != batch->name) {
        // this chunk is not the root of the batch.
        // find parent chunk within batch.
        // there must be a leaf node in the parent chunk,
        // which is the proxy node / pointer to this chunk.
        string parentName = chunk->name.substr(0, chunk->name.size() - size_t(hierarchyStepSize));
        if (batch->chunkMap.find(parentName) != batch->chunkMap.end()) {
          auto proxyNode = batch->nodeMap[chunk->name];

          if (proxyNode == nullptr) {  // upstream exit(123)
            error->fail("hierarchy: didn't find proxy node " + chunk->name);
            return false;
          }

          proxyNode->type = TYPE::PROXY;
          proxyNode->proxyByteOffset = uint64_t(chunk->byteOffset);
          proxyNode->proxyByteSize = 22 * chunk->nodes.size();
        } else {  // upstream exit(123)
          error->fail("hierarchy: didn't find chunk " + chunk->name);
          return false;
        }
      }

      byteOffset += int64_t(22 * chunk->nodes.size());
    }

    batch->byteSize = byteOffset;
    return true;
  }

  // :240-282
  shared_ptr<Buffer> serializeBatch(shared_ptr<HBatch> batch, int64_t bytesWritten) {
    int64_t numRecords = 0;
    for (auto& chunk : batch->chunks) {
      numRecords += int64_t(chunk->nodes.size());  // all nodes in chunk except chunk root
    }

    auto buffer = make_shared<Buffer>(22 * numRecords);
    if (!buffer->ok(22 * numRecords)) {
      error->fail("out of memory (hierarchy)");
      return nullptr;
    }

    int64_t recordsProcessed = 0;
    for (auto& chunk : batch->chunks) {
      for (auto& node : chunk->nodes) {
        // proxy nodes exist twice - in the chunk and the parent-chunk that points to this chunk
        // only the node in the parent-chunk is a proxy (to its non-proxy counterpart)
        bool isProxyNode = (node->type == TYPE::PROXY) && node->name != chunk->name;

        TYPE type = node->type;
        if (node->type == TYPE::PROXY && !isProxyNode) type = TYPE::NORMAL;

        uint64_t byteSize = isProxyNode ? node->proxyByteSize : node->byteSize;
        uint64_t byteOffset = (isProxyNode ? uint64_t(bytesWritten) + node->proxyByteOffset : node->byteOffset);

        buffer->set<uint8_t>(uint8_t(type), 22 * recordsProcessed + 0);
        buffer->set<uint8_t>(node->childMask, 22 * recordsProcessed + 1);
        buffer->set<uint32_t>(uint32_t(node->numPoints), 22 * recordsProcessed + 2);
        buffer->set<uint64_t>(byteOffset, 22 * recordsProcessed + 6);
        buffer->set<uint64_t>(byteSize, 22 * recordsProcessed + 14);

        recordsProcessed++;
      }
    }

    batch->byteSize = buffer->size;

    return buffer;
  }

  // :284-352
  bool build() {
    string hierarchyFilePath = path + "/../hierarchy.bin";
    std::fstream fout(hierarchyFilePath, std::ios::binary | std::ios::out);
    if (!fout) {
      error->fail("cannot create " + hierarchyFilePath);
      return false;
    }
    int64_t bytesWritten = 0;

    auto root = loadBatch(path + "/r.bin");
    if (!root) return false;
    this->batch_root = root;

    {  // reserve the first <x> bytes in the file for the root chunk
      vector<char> tmp(22 * batch_root->nodes.size(), 0);
      fout.write(tmp.data(), std::streamsize(tmp.size()));
      bytesWritten = int64_t(tmp.size());
    }

    // now write all hierarchy batches, except root
    // update proxy nodes in root with byteOffsets of written batches.
    std::error_code ec;
    for (std::filesystem::directory_iterator it(path, ec), end; !ec && it != end; it.increment(ec)) {
      auto filepath = it->path();

      // skip root. it get's special treatment
      if (filepath.filename().string() == "r.bin") continue;
      // skip non *.bin files
      if (filepath.extension().string() != ".bin") continue;

      auto batch = loadBatch(filepath.string());
      if (!batch) return false;

      if (!processBatch(batch)) return false;
      auto buffer = serializeBatch(batch, bytesWritten);
      if (!buffer) return false;

      auto proxyIt = batch_root->nodeMap.find(batch->name);
      if (proxyIt == batch_root->nodeMap.end() || proxyIt->second == nullptr) {
        // upstream dereferences a null shared_ptr here (:317/:325)
        error->fail("hierarchy: batch " + batch->name + " has no node in the root batch");
        return false;
      }

      if (batch->nodes.size() > 1) {
        auto proxyNode = proxyIt->second;
        proxyNode->type = TYPE::PROXY;
        proxyNode->proxyByteOffset = uint64_t(bytesWritten);
        proxyNode->proxyByteSize = 22 * batch->chunkMap[batch->name]->nodes.size();
      } else {
        // if there is only one node in that batch,
        // then we flag that node as leaf in the root-batch
        auto root_batch_node = proxyIt->second;
        root_batch_node->type = TYPE::LEAF;
      }

      fout.write(buffer->data_char, buffer->size);
      bytesWritten += buffer->size;
    }
    if (ec) {
      error->fail("cannot list " + path + ": " + ec.message());
      return false;
    }

    // close/flush file so that we can reopen it to modify beginning
    fout.close();
    if (!fout) {
      error->fail("write to hierarchy.bin failed (disk full?)");
      return false;
    }

    {  // update beginning of file with root chunk
      std::fstream f(hierarchyFilePath, std::ios::ate | std::ios::binary | std::ios::out | std::ios::in);
      f.seekg(0);

      auto buffer = serializeBatch(batch_root, 0);
      if (!buffer) return false;

      f.write(buffer->data_char, buffer->size);
      f.close();
      if (!f) {
        error->fail("write to hierarchy.bin failed (disk full?)");
        return false;
      }
    }

    // redundant security check
    if (path.size() >= 16 && path.compare(path.size() - 16, 16, ".hierarchyChunks") == 0) {
      std::filesystem::remove_all(this->path, ec);
    }

    return true;
  }
};

}  // namespace aether::pointcloud_lod_build::pc
