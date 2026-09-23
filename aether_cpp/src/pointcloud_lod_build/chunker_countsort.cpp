// Port of PotreeConverter 2.0 @ 8bfad98 (BSD-2-Clause):
// Converter/src/chunker_countsort_laszip.cpp  ("counting sort" chunking).
//
// Pass 1 counts points per cell of a gridSize^3 grid, the grid is merged
// bottom-up like an image pyramid into chunks of at most maxPointsPerChunk points,
// pass 2 distributes the points into one file per chunk. Line references are to
// the upstream file. Changes are listed in DEVIATIONS.md; the ones visible here:
//   D2  exit()/error logs  -> ErrorState, the task returns
//   D3  LASzip reader      -> PointSource::read in fixed sub-batches (forEachPoint)
//   D7  namespace globals  -> a per-call Chunker object (library may run twice)
//   D10 the copy of outputAttributes is taken under mtx_attributes
#include "chunker_countsort.h"

#include <atomic>
#include <cmath>
#include <filesystem>
#include <mutex>
#include <string>
#include <system_error>
#include <vector>

#include "concurrent_writer.h"
#include "task_pool.h"

namespace aether::pointcloud_lod_build::pc {
namespace fs = std::filesystem;

namespace {

// Glue (D3): upstream reads one point at a time through laszip_read_point +
// laszip_get_coordinates. Here the task streams its range in sub-batches.
constexpr int64_t kReadSubBatch = 65'536;

template <class F>
bool forEachPoint(const PointSource& source, int64_t first, int64_t count, ErrorState* error, F&& f) {
  const int64_t cap = std::min(count, kReadSubBatch);
  vector<double> xyz(static_cast<size_t>(3 * cap));
  vector<uint16_t> rgb(static_cast<size_t>(3 * cap));
  for (int64_t s = 0; s < count; s += kReadSubBatch) {
    if (error->failed()) return false;
    const int64_t n = std::min(kReadSubBatch, count - s);
    string msg;
    if (!source.read(first + s, n, xyz.data(), rgb.data(), &msg)) {
      error->fail("point read failed: " + msg);
      return false;
    }
    for (int64_t k = 0; k < n; k++) {
      if (!f(s + k, &xyz[static_cast<size_t>(3 * k)], &rgb[static_cast<size_t>(3 * k)])) return false;
    }
  }
  return true;
}

struct ChunkNode {  // chunker_countsort_laszip.cpp:70-84
  string id = "";
  int64_t level = 0;
  int64_t x = 0;
  int64_t y = 0;
  int64_t z = 0;
  int64_t size = 0;
  int64_t numPoints = 0;

  ChunkNode(string id_, int64_t numPoints_) : id(id_), numPoints(numPoints_) {}
};

// chunker_countsort_laszip.cpp:88-121
string toNodeID(int level, int gridSize, int64_t x, int64_t y, int64_t z) {
  string id = "r";

  int currentGridSize = gridSize;
  int64_t lx = x;
  int64_t ly = y;
  int64_t lz = z;

  for (int i = 0; i < level; i++) {
    int index = 0;

    if (lx >= currentGridSize / 2) {
      index = index + 0b100;
      lx = lx - currentGridSize / 2;
    }
    if (ly >= currentGridSize / 2) {
      index = index + 0b010;
      ly = ly - currentGridSize / 2;
    }
    if (lz >= currentGridSize / 2) {
      index = index + 0b001;
      lz = lz - currentGridSize / 2;
    }

    id = id + std::to_string(index);
    currentGridSize = currentGridSize / 2;
  }

  return id;
}

// chunker_countsort_laszip.cpp:132-135
struct NodeLUT {
  int64_t gridSize = 0;
  vector<int> grid;
};

// The namespace-level state of chunker_countsort_laszip.cpp:50-86 (D7).
struct Chunker {
  const PointSource& source;
  const ChunkerConfig& config;
  ErrorState* error;

  int maxPointsPerChunk = 5'000'000;  // :56
  int gridSize = 128;                 // :57
  std::mutex mtx_attributes;          // :58
  ConcurrentWriter* writer = nullptr; // :68
  vector<ChunkNode> nodes;            // :86

  Chunker(const PointSource& s, const ChunkerConfig& c, ErrorState* e) : source(s), config(c), error(e) {}

  // :137-427
  vector<std::atomic_int32_t> countPointsInCells(Vector3 min, Vector3 max, int64_t gridSize_,
                                                  Attributes& outputAttributes) {
    vector<std::atomic_int32_t> grid(static_cast<size_t>(gridSize_ * gridSize_ * gridSize_));

    struct Task {
      int64_t firstPoint = 0;
      int64_t numPoints = 0;
      Vector3 min;
      Vector3 max;
    };

    auto processor = [this, gridSize_, &grid, &outputAttributes](shared_ptr<Task> task) {
      int64_t numToRead = task->numPoints;
      Vector3 min = task->min;
      Vector3 max = task->max;

      double cubeSize = (max - min).max();
      Vector3 size = {cubeSize, cubeSize, cubeSize};
      max = min + cubeSize;

      double dGridSize = double(gridSize_);

      auto posScale = outputAttributes.posScale;
      auto posOffset = outputAttributes.posOffset;

      forEachPoint(source, task->firstPoint, numToRead, error,
                   [&](int64_t, const double* coordinates, const uint16_t*) -> bool {
        // transfer las integer coordinates to new scale/offset/box values
        double x = coordinates[0];
        double y = coordinates[1];
        double z = coordinates[2];

        int32_t X = int32_t((x - posOffset.x) / posScale.x);
        int32_t Y = int32_t((y - posOffset.y) / posScale.y);
        int32_t Z = int32_t((z - posOffset.z) / posScale.z);

        double ux = (double(X) * posScale.x + posOffset.x - min.x) / size.x;
        double uy = (double(Y) * posScale.y + posOffset.y - min.y) / size.y;
        double uz = (double(Z) * posScale.z + posOffset.z - min.z) / size.z;

        // we compare bounds of scaled values,
        // but scaled values may move slightly out of bounds due to float errors
        // Try to fix by allowing points which are a tiny bit outside the box.
        double upperBound = std::nextafter(1.0, 2.0);

        bool inBox = ux >= 0.0 && uy >= 0.0 && uz >= 0.0;
        inBox = inBox && ux <= upperBound && uy <= upperBound && uz <= upperBound;

        if (!inBox) {  // :252-264, upstream exit(123)
          error->fail("encountered point outside bounding box");
          return false;
        }

        int64_t ix = int64_t(std::min(dGridSize * ux, dGridSize - 1.0));
        int64_t iy = int64_t(std::min(dGridSize * uy, dGridSize - 1.0));
        int64_t iz = int64_t(std::min(dGridSize * uz, dGridSize - 1.0));

        int64_t index = ix + iy * gridSize_ + iz * gridSize_ * gridSize_;

        grid[static_cast<size_t>(index)]++;
        return true;
      });
    };

    TaskPool<Task> pool(static_cast<size_t>(config.numChunkerThreads), processor);

    // :330-406, one source
    int64_t numPoints = source.numPoints();
    int64_t pointsLeft = numPoints;
    int64_t batchSize = 1'000'000;
    int64_t numRead = 0;

    while (pointsLeft > 0) {
      int64_t numToRead;
      if (pointsLeft < batchSize) {
        numToRead = pointsLeft;
        pointsLeft = 0;
      } else {
        numToRead = batchSize;
        pointsLeft = pointsLeft - batchSize;
      }

      auto task = make_shared<Task>();
      task->firstPoint = numRead;
      task->numPoints = numToRead;
      task->min = min;
      task->max = max;

      pool.addTask(task);

      numRead += batchSize;
    }

    pool.waitTillEmpty();
    pool.close();

    return grid;
  }

  // :429-516 (uncompressed branch; --compress-chunks is not ported)
  void addBuckets(const string& targetDir, vector<shared_ptr<Buffer>>& newBuckets) {
    for (size_t nodeIndex = 0; nodeIndex < nodes.size(); nodeIndex++) {
      if (newBuckets[nodeIndex]->size == 0) continue;

      auto& node = nodes[nodeIndex];
      auto buffer = newBuckets[nodeIndex];

      string path = targetDir + "/chunks/" + node.id + ".bin";
      writer->write(path, buffer);
    }
  }

  // :822-1175
  void distributePoints(Vector3 min, Vector3 max, const string& targetDir, NodeLUT& lut,
                        Attributes& outputAttributes) {
    ConcurrentWriter concurrentWriter(static_cast<size_t>(config.numFlushThreads), error);
    writer = &concurrentWriter;

    struct Task {
      int64_t maxBatchSize = 0;
      int64_t batchSize = 0;
      int64_t firstPoint = 0;
      NodeLUT* lut = nullptr;
      Vector3 scale;
      Vector3 offset;
      Vector3 min;
      Vector3 max;
    };

    auto processor = [this, targetDir, &outputAttributes](shared_ptr<Task> task) {
      if (error->failed()) return;

      auto batchSize = task->batchSize;
      auto* lut_ = task->lut;
      auto bpp = static_cast<int64_t>(outputAttributes.bytes);
      auto numBytes = bpp * batchSize;
      Vector3 scale = task->scale;
      Vector3 min_ = task->min;
      Vector3 max_ = task->max;

      auto gridSize_ = lut_->gridSize;
      auto& grid = lut_->grid;

      // :885-904 thread_local malloc'd scratch + memset -> zeroed per-task buffer (D6)
      Buffer scratch(numBytes);
      if (!scratch.ok(numBytes)) {
        error->fail("out of memory (chunk batch)");
        return;
      }
      uint8_t* data = scratch.data_u8;
      std::memset(data, 0, static_cast<size_t>(numBytes));

      writer->waitUntilMemoryBelow(config.backlogWatermarkMB);

      // per-thread copy of outputAttributes to compute min/max in a thread-safe way
      // will be merged to global outputAttributes instance at the end of this function
      Attributes outputAttributesCopy;
      {
        std::lock_guard<std::mutex> lock(mtx_attributes);  // D10
        outputAttributesCopy = outputAttributes;
      }
      for (auto& attribute : outputAttributesCopy.list) {
        if (attribute.name == "classification") {
          for (size_t i = 0; i < attribute.histogram.size(); i++) attribute.histogram[i] = 0;
        }
      }

      {
        // createAttributeHandlers (:518-820): reset min/max of the per-thread copy
        for (auto& attribute : outputAttributesCopy.list) {
          attribute.min = {Infinity, Infinity, Infinity};
          attribute.max = {-Infinity, -Infinity, -Infinity};
        }
        // Only the "rgb" handler (:531-548) applies: the output attributes are
        // position + rgb (D3).
        int offsetRGB = outputAttributesCopy.getOffset("rgb");
        Attribute* attributeRGB = outputAttributesCopy.get("rgb");
        auto aPosition = outputAttributesCopy.get("position");

        forEachPoint(source, task->firstPoint, batchSize, error,
                     [&](int64_t i, const double* coordinates, const uint16_t* pointRgb) -> bool {
          int64_t offset = i * outputAttributes.bytes;

          {  // copy position (:948-968)
            double x = coordinates[0];
            double y = coordinates[1];
            double z = coordinates[2];

            int32_t X = int32_t((x - outputAttributes.posOffset.x) / scale.x);
            int32_t Y = int32_t((y - outputAttributes.posOffset.y) / scale.y);
            int32_t Z = int32_t((z - outputAttributes.posOffset.z) / scale.z);

            std::memcpy(data + offset + 0, &X, 4);
            std::memcpy(data + offset + 4, &Y, 4);
            std::memcpy(data + offset + 8, &Z, 4);

            aPosition->min.x = std::min(aPosition->min.x, x);
            aPosition->min.y = std::min(aPosition->min.y, y);
            aPosition->min.z = std::min(aPosition->min.z, z);

            aPosition->max.x = std::max(aPosition->max.x, x);
            aPosition->max.y = std::max(aPosition->max.y, y);
            aPosition->max.z = std::max(aPosition->max.z, z);
          }

          if (offsetRGB >= 0) {  // rgb handler (:533-548)
            uint16_t rgb[] = {0, 0, 0};
            std::memcpy(rgb, pointRgb, 6);
            std::memcpy(data + offset + offsetRGB, rgb, 6);

            attributeRGB->min.x = std::min(attributeRGB->min.x, double(rgb[0]));
            attributeRGB->min.y = std::min(attributeRGB->min.y, double(rgb[1]));
            attributeRGB->min.z = std::min(attributeRGB->min.z, double(rgb[2]));

            attributeRGB->max.x = std::max(attributeRGB->max.x, double(rgb[0]));
            attributeRGB->max.y = std::max(attributeRGB->max.y, double(rgb[1]));
            attributeRGB->max.z = std::max(attributeRGB->max.z, double(rgb[2]));
          }
          return true;
        });
        if (error->failed()) return;
      }

      double cubeSize = (max_ - min_).max();
      Vector3 size = {cubeSize, cubeSize, cubeSize};
      max_ = min_ + cubeSize;

      double dGridSize = double(gridSize_);

      auto toIndex = [data, &outputAttributes, scale, gridSize_, dGridSize, size, min_](int64_t pointOffset) {
        int32_t xyz[3];
        std::memcpy(xyz, data + pointOffset, 12);

        int32_t X = xyz[0];
        int32_t Y = xyz[1];
        int32_t Z = xyz[2];

        double ux = (double(X) * scale.x + outputAttributes.posOffset.x - min_.x) / size.x;
        double uy = (double(Y) * scale.y + outputAttributes.posOffset.y - min_.y) / size.y;
        double uz = (double(Z) * scale.z + outputAttributes.posOffset.z - min_.z) / size.z;

        int64_t ix = int64_t(std::min(dGridSize * ux, dGridSize - 1.0));
        int64_t iy = int64_t(std::min(dGridSize * uy, dGridSize - 1.0));
        int64_t iz = int64_t(std::min(dGridSize * uz, dGridSize - 1.0));

        int64_t index = ix + iy * gridSize_ + iz * gridSize_ * gridSize_;

        return index;
      };

      // COUNT POINTS PER BUCKET (:1009-1048)
      vector<int64_t> counts(nodes.size(), 0);
      for (int64_t i = 0; i < batchSize; i++) {
        auto index = toIndex(i * bpp);
        auto nodeIndex = grid[static_cast<size_t>(index)];

        if (nodeIndex == -1) {  // :1017-1045, upstream exit(123)
          error->fail("point to node lookup failed, no node found");
          return;
        }

        counts[static_cast<size_t>(nodeIndex)]++;
      }

      // ALLOCATE BUCKETS (:1050-1056)
      vector<shared_ptr<Buffer>> buckets(nodes.size(), nullptr);
      for (size_t i = 0; i < nodes.size(); i++) {
        int64_t numPoints = counts[i];
        int64_t bytes = numPoints * bpp;
        buckets[i] = make_shared<Buffer>(bytes);
        if (!buckets[i]->ok(bytes)) {
          error->fail("out of memory (chunk bucket)");
          return;
        }
      }

      // ADD POINTS TO BUCKETS (:1058-1076)
      shared_ptr<Buffer> previousBucket = nullptr;
      int64_t previousNodeIndex = -1;
      for (int64_t i = 0; i < batchSize; i++) {
        int64_t pointOffset = i * bpp;

        auto index = toIndex(pointOffset);
        int64_t nodeIndex = grid[static_cast<size_t>(index)];

        if (nodeIndex == previousNodeIndex) {
          previousBucket->write(&data[0] + pointOffset, bpp);
        } else {
          previousBucket = buckets[static_cast<size_t>(nodeIndex)];
          previousNodeIndex = nodeIndex;
          previousBucket->write(&data[0] + pointOffset, bpp);
        }
      }

      addBuckets(targetDir, buckets);

      // merge attribute metadata of this batch into global attribute metadata (:1085-1104)
      for (size_t i = 0; i < outputAttributesCopy.list.size(); i++) {
        Attribute& sourceAttribute = outputAttributesCopy.list[i];
        Attribute& target = outputAttributes.list[i];

        std::lock_guard<std::mutex> lock(mtx_attributes);
        target.min.x = std::min(target.min.x, sourceAttribute.min.x);
        target.min.y = std::min(target.min.y, sourceAttribute.min.y);
        target.min.z = std::min(target.min.z, sourceAttribute.min.z);

        target.max.x = std::max(target.max.x, sourceAttribute.max.x);
        target.max.y = std::max(target.max.y, sourceAttribute.max.y);
        target.max.z = std::max(target.max.z, sourceAttribute.max.z);

        for (size_t j = 0; j < target.histogram.size(); j++) {
          target.histogram[j] = target.histogram[j] + sourceAttribute.histogram[j];
        }
      }
    };

    {
      TaskPool<Task> pool(static_cast<size_t>(config.numChunkerThreads), processor);

      // :1111-1165, one source
      int64_t numPoints = source.numPoints();
      int64_t pointsLeft = numPoints;
      int64_t maxBatchSize = 1'000'000;
      int64_t numRead = 0;

      while (pointsLeft > 0) {
        int64_t numToRead;
        if (pointsLeft < maxBatchSize) {
          numToRead = pointsLeft;
          pointsLeft = 0;
        } else {
          numToRead = maxBatchSize;
          pointsLeft = pointsLeft - maxBatchSize;
        }

        auto task = make_shared<Task>();
        task->maxBatchSize = maxBatchSize;
        task->batchSize = numToRead;
        task->lut = &lut;
        task->firstPoint = numRead;
        task->scale = outputAttributes.posScale;
        task->offset = outputAttributes.posOffset;
        task->min = min;
        task->max = max;

        pool.addTask(task);

        numRead += numToRead;
      }

      pool.close();
    }
    concurrentWriter.join();
    writer = nullptr;
  }

  // :1246-1376
  NodeLUT createLUT(vector<std::atomic_int32_t>& grid, int64_t gridSize_) {
    auto for_xyz = [](int64_t gs, const function<void(int64_t, int64_t, int64_t)>& callback) {
      for (int64_t x = 0; x < gs; x++) {
        for (int64_t y = 0; y < gs; y++) {
          for (int64_t z = 0; z < gs; z++) {
            callback(x, y, z);
          }
        }
      }
    };

    // atomic vectors are cumbersome, convert the highest level into a regular integer vector first.
    vector<int64_t> grid_high;
    grid_high.reserve(grid.size());
    for (auto& value : grid) grid_high.push_back(value);

    int64_t level_max = int64_t(std::log2(gridSize_));

    // - evaluate counting grid in "image pyramid" fashion
    // - merge smaller cells into larger ones
    // - unmergeable cells are resulting chunks; push them to "nodes" array.
    for (int64_t level_low = level_max - 1; level_low >= 0; level_low--) {
      int64_t level_high = level_low + 1;

      int64_t gridSize_high = int64_t(std::pow(2, level_high));
      int64_t gridSize_low = int64_t(std::pow(2, level_low));

      vector<int64_t> grid_low(static_cast<size_t>(gridSize_low * gridSize_low * gridSize_low), 0);

      for_xyz(gridSize_low, [this, &grid_low, &grid_high, gridSize_low, gridSize_high, level_high,
                             level_max](int64_t x, int64_t y, int64_t z) {
        int64_t index_low = x + y * gridSize_low + z * gridSize_low * gridSize_low;

        int64_t sum = 0;
        int64_t max = 0;
        bool unmergeable = false;

        // loop through the 8 enclosed cells of the higher detailed grid
        for (int64_t j = 0; j < 8; j++) {
          int64_t ox = (j & 0b100) >> 2;
          int64_t oy = (j & 0b010) >> 1;
          int64_t oz = (j & 0b001) >> 0;

          int64_t nx = 2 * x + ox;
          int64_t ny = 2 * y + oy;
          int64_t nz = 2 * z + oz;

          int64_t index_high = nx + ny * gridSize_high + nz * gridSize_high * gridSize_high;

          auto value = grid_high[static_cast<size_t>(index_high)];

          if (value == -1) {
            unmergeable = true;
          } else {
            sum += value;
          }

          max = std::max(max, value);
        }

        if (unmergeable || sum > maxPointsPerChunk) {
          // finished chunks
          for (int64_t j = 0; j < 8; j++) {
            int64_t ox = (j & 0b100) >> 2;
            int64_t oy = (j & 0b010) >> 1;
            int64_t oz = (j & 0b001) >> 0;

            int64_t nx = 2 * x + ox;
            int64_t ny = 2 * y + oy;
            int64_t nz = 2 * z + oz;

            int64_t index_high = nx + ny * gridSize_high + nz * gridSize_high * gridSize_high;

            auto value = grid_high[static_cast<size_t>(index_high)];

            if (value > 0) {
              string nodeID = toNodeID(int(level_high), int(gridSize_high), nx, ny, nz);

              ChunkNode node(nodeID, value);
              node.x = nx;
              node.y = ny;
              node.z = nz;
              node.size = int64_t(std::pow(2, (level_max - level_high)));

              nodes.push_back(node);
            }
          }

          // invalidate the field to show the parent that nothing can be merged with it
          grid_low[static_cast<size_t>(index_low)] = -1;
        } else {
          grid_low[static_cast<size_t>(index_low)] = sum;
        }
      });

      grid_high = grid_low;
    }

    // - create lookup table
    // - loop through nodes, add pointers to node/chunk for all enclosed cells in LUT.
    vector<int32_t> lut(static_cast<size_t>(gridSize_ * gridSize_ * gridSize_), -1);
    for (size_t i = 0; i < nodes.size(); i++) {
      auto node = nodes[i];

      for_xyz(node.size, [node, &lut, gridSize_, i](int64_t ox, int64_t oy, int64_t oz) {
        int64_t x = node.size * node.x + ox;
        int64_t y = node.size * node.y + oy;
        int64_t z = node.size * node.z + oz;
        int64_t index = x + y * gridSize_ + z * gridSize_ * gridSize_;

        lut[static_cast<size_t>(index)] = int32_t(i);
      });
    }

    return {gridSize_, lut};
  }
};

}  // namespace

// :1378-1441
bool doChunking(const PointSource& source, const string& targetDir, Vector3 min, Vector3 max,
                State& state, Attributes outputAttributes, const ChunkerConfig& config,
                ErrorState* error, ChunkedMetadata* out) {
  Chunker chunker(source, config, error);

  int64_t tmp = state.pointsTotal / 20;
  chunker.maxPointsPerChunk = int(std::min(tmp, int64_t(10'000'000)));

  if (state.pointsTotal < 100'000'000) {
    chunker.gridSize = 128;
  } else if (state.pointsTotal < 500'000'000) {
    chunker.gridSize = 256;
  } else {
    chunker.gridSize = 512;
  }

  {  // prepare/clean target directories (:1404-1411)
    string dir = targetDir + "/chunks";
    std::error_code ec;
    fs::create_directories(dir, ec);
    if (ec) {
      error->fail("cannot create chunk directory " + dir + ": " + ec.message());
      return false;
    }
    for (fs::directory_iterator it(dir, ec), end; !ec && it != end; it.increment(ec)) {
      std::error_code ec2;
      fs::remove(it->path(), ec2);
    }
    if (ec) {
      error->fail("cannot list chunk directory " + dir + ": " + ec.message());
      return false;
    }
  }

  // COUNT
  auto grid = chunker.countPointsInCells(min, max, chunker.gridSize, outputAttributes);
  if (error->failed()) return false;

  {  // DISTRIBUTE
    auto lut = chunker.createLUT(grid, chunker.gridSize);
    chunker.distributePoints(min, max, targetDir, lut, outputAttributes);
    if (error->failed()) return false;
  }

  // writeMetadata(targetDir + "/chunks/metadata.json", ...) (:1431-1436) -> in memory (D8)
  double cubeSize = (max - min).max();
  max = min + cubeSize;

  out->min = min;
  out->max = max;
  out->attributes = outputAttributes;
  out->numChunks = static_cast<int64_t>(chunker.nodes.size());
  out->maxPointsPerChunk = chunker.maxPointsPerChunk;
  out->gridSize = chunker.gridSize;
  return true;
}

}  // namespace aether::pointcloud_lod_build::pc
