// Port of PotreeConverter 2.0 @ 8bfad98 (BSD-2-Clause): Converter/src/Writer.cpp.
#include "writer.h"

#include <algorithm>

namespace aether::pointcloud_lod_build::pc {

// Writer.cpp:372-396 (resume == false)
Writer::Writer(const string& targetDir, int64_t capacity_, ErrorState* error_) : capacity(capacity_), error(error_) {
  string octreePath = targetDir + "/octree.bin";

  fsOctree.open(octreePath, std::ios::out | std::ios::binary);
  if (!fsOctree) error->fail("cannot create " + octreePath);

  ringBuffer = VBuffer::create(capacity);
  if (!ringBuffer->commit(capacity)) error->fail("out of memory (octree ring buffer)");

  launchWriterThread();
}

// Writer.cpp:398-423 (encoding != "BROTLI")
void Writer::writeAndUnload(Node* node) {
  if (node->numPoints == 0) return;

  const void* sourceBuffer = node->points->ptr;
  int64_t sourceBufferSize = node->points->size;

  node->byteSize = sourceBufferSize;
  node->byteOffset = write(sourceBuffer, sourceBufferSize);
  VBufferPool::release(node->points);
  node->points = nullptr;
}

// Writer.cpp:425-462
int64_t Writer::write(const void* buffer, int64_t size) {
  if (size <= 0) return writePos;

  const u8* source = static_cast<const u8*>(buffer);

  std::unique_lock<std::mutex> lock(mtx);

  // D2: after a failure (e.g. the ring could not be allocated) nothing is written.
  if (error->failed() || ringBuffer->ptr == nullptr) return writePos;

  if (size > capacity) {
    // D4: upstream exit(4320). Wait until everything accepted so far is on disk,
    // then write this node straight through at the offset the ring would have
    // given it. The writer thread only touches the file while flushPos < writePos,
    // so holding mtx with flushPos == writePos excludes it.
    cvSpace.wait(lock, [&] { return flushPos == writePos; });
    int64_t byteOffset = writePos;
    fsOctree.write(reinterpret_cast<const char*>(source), size);
    if (!fsOctree) error->fail("write to octree.bin failed (disk full?)");
    writePos += size;
    flushPos += size;
    bytesWritten += size;
    return byteOffset;
  }

  // Wait until enough space is free. Free space is the capacity minus the bytes
  // that have been accepted but not yet written to file. This guarantees we never
  // overwrite a region that is still pending a flush.
  cvSpace.wait(lock, [&] { return (capacity - (writePos - flushPos)) >= size; });

  // Place the data contiguously, wrapping around to the start of the ring when it
  // would run past the end.
  int64_t offset = writePos % capacity;
  int64_t firstPart = std::min(size, capacity - offset);
  int64_t secondPart = size - firstPart;

  std::memcpy(ringBuffer->ptr + offset, source, static_cast<size_t>(firstPart));
  if (secondPart > 0) {
    std::memcpy(ringBuffer->ptr, source + firstPart, static_cast<size_t>(secondPart));
  }

  int64_t byteOffset = writePos;

  writePos += size;

  lock.unlock();
  cvData.notify_one();

  return byteOffset;
}

// Writer.cpp:464-517
void Writer::launchWriterThread() {
  writerThread = std::thread([this] {
    int64_t bytesToFlush = 1'000'000'000;

    while (true) {
      int64_t offset = 0;
      int64_t length = 0;

      {
        std::unique_lock<std::mutex> lock(mtx);

        cvData.wait(lock, [&] { return (writePos > flushPos) || closeRequested; });

        int64_t available = writePos - flushPos;
        if (available == 0 && closeRequested) break;

        offset = flushPos % capacity;
        length = std::min(available, capacity - offset);
      }

      fsOctree.write(reinterpret_cast<const char*>(ringBuffer->ptr + offset), length);
      if (!fsOctree) error->fail("write to octree.bin failed (disk full?)");

      bytesToFlush -= length;
      if (bytesToFlush <= 0) {
        fsOctree.flush();
        bytesToFlush = 1'000'000'000;
      }

      bytesWritten += length;

      {
        std::lock_guard<std::mutex> lock(mtx);
        flushPos += length;
      }
      cvSpace.notify_all();
    }
  });
}

// Writer.cpp:519-536
void Writer::closeAndWait() {
  {
    std::lock_guard<std::mutex> lock(mtx);
    if (closed) return;
    closeRequested = true;
  }
  cvData.notify_all();

  if (writerThread.joinable()) writerThread.join();

  fsOctree.flush();
  fsOctree.close();
  if (!fsOctree) error->fail("closing octree.bin failed (disk full?)");

  closed = true;
}

// Writer.cpp:538-543
int64_t Writer::backlogSizeMB() {
  std::lock_guard<std::mutex> lock(mtx);
  int64_t backlogBytes = writePos - flushPos;
  return backlogBytes / (1024 * 1024);
}

}  // namespace aether::pointcloud_lod_build::pc
