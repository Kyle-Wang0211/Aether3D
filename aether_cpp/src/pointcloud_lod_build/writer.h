// Portions of this file are derived from PotreeConverter 2.0
// (https://github.com/potree/PotreeConverter), used under this licence,
// reproduced verbatim as its clause 1 requires:
//
// Copyright 2020 Markus Schütz
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//
// 1. Redistributions of source code must retain the above copyright notice,
// this list of conditions and the following disclaimer.
//
// 2. Redistributions in binary form must reproduce the above copyright notice,
// this list of conditions and the following disclaimer in the documentation
// and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
// ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
// LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.
//
// Port of PotreeConverter 2.0 @ 8bfad98 (BSD-2-Clause):
// Converter/include/Writer.h + Converter/src/Writer.cpp (octree.bin writer: a
// ring buffer drained by one writer thread). Encoding DEFAULT only (D17).
//
// Changes (DEVIATIONS.md):
//   D4 ring capacity is a parameter (upstream: 1 GiB, Writer.h:26); a node larger
//      than the ring (upstream: exit(4320), Writer.cpp:429-432) is written through
//      once the ring has drained, at the same byte offset it would have had.
//   D2 open/write failures are reported instead of ignored.
#pragma once

#include <condition_variable>
#include <fstream>
#include <mutex>
#include <thread>

#include "upstream_base.h"

namespace aether::pointcloud_lod_build::pc {

struct Writer {
  int64_t capacity = 1024 * 1024 * 1024;
  shared_ptr<VBuffer> ringBuffer;
  std::fstream fsOctree;

  int64_t writePos = 0;
  int64_t flushPos = 0;

  bool closeRequested = false;
  bool closed = false;

  std::mutex mtx;
  std::condition_variable cvData;
  std::condition_variable cvSpace;
  std::thread writerThread;

  ErrorState* error = nullptr;
  std::atomic<int64_t> bytesWritten = 0;

  Writer(const string& targetDir, int64_t capacity_, ErrorState* error_);
  Writer(const Writer&) = delete;
  Writer& operator=(const Writer&) = delete;
  ~Writer() { closeAndWait(); }

  void writeAndUnload(Node* node);
  int64_t write(const void* buffer, int64_t size);
  void launchWriterThread();
  void closeAndWait();
  int64_t backlogSizeMB();
};

}  // namespace aether::pointcloud_lod_build::pc
