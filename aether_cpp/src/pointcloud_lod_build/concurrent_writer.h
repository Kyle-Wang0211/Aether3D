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
// Converter/include/ConcurrentWriter.h. Appends chunk batches to per-chunk files
// from a pool of flush threads.
//
// Changes (DEVIATIONS.md): the status thread (:59-83, only sets state.name for the
// console monitor) is dropped (D9); a failed open/write is reported through the
// ErrorState instead of being ignored (D2); the backlog watermark that the caller
// passes to waitUntilMemoryBelow() is configurable (D4, upstream passes 2'000 MB).
#pragma once

#include <chrono>
#include <fstream>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

#include "upstream_base.h"

namespace aether::pointcloud_lod_build::pc {

struct ConcurrentWriter {
  std::unordered_map<string, vector<shared_ptr<Buffer>>> todo;
  std::unordered_map<string, int> locks;
  std::atomic<int64_t> todoBytes = 0;
  std::atomic<int64_t> writtenBytes = 0;

  vector<std::thread> threads;

  std::mutex mtx_todo;
  size_t numThreads = 1;

  bool joinRequested = false;
  std::mutex mtx_join;

  ErrorState* error = nullptr;

  ConcurrentWriter(size_t numThreads_, ErrorState* error_) : numThreads(numThreads_), error(error_) {
    for (size_t i = 0; i < numThreads; i++) {
      threads.emplace_back([this]() { flushThread(); });
    }
  }
  ConcurrentWriter(const ConcurrentWriter&) = delete;
  ConcurrentWriter& operator=(const ConcurrentWriter&) = delete;

  ~ConcurrentWriter() { this->join(); }

  // ConcurrentWriter.h:91-99
  void waitUntilMemoryBelow(int64_t maxMegabytesOutstanding) {
    using namespace std::chrono_literals;
    while (todoBytes / (1024 * 1024) > maxMegabytesOutstanding) {
      std::this_thread::sleep_for(10ms);
    }
  }

  // ConcurrentWriter.h:101-181
  void flushThread() {
    using namespace std::chrono_literals;

    while (true) {
      string path = "";
      vector<shared_ptr<Buffer>> work;

      {
        std::lock_guard<std::mutex> lockT(mtx_todo);
        std::lock_guard<std::mutex> lockJ(mtx_join);

        bool nothingTodo = todo.size() == 0;

        if (nothingTodo && joinRequested) {
          return;
        } else {
          auto it = todo.begin();
          while (it != todo.end()) {
            if (locks.find(it->first) == locks.end()) break;
            it++;
          }
          if (it != todo.end()) {
            path = it->first;
            work = it->second;
            todo.erase(it);
            locks[path] = 1;
          }
        }
      }

      if (work.size() == 0) {
        std::this_thread::sleep_for(10ms);
        continue;
      }

      std::fstream fout;
      fout.open(path, std::ios::out | std::ios::app | std::ios::binary);
      if (!fout) error->fail("cannot open chunk file for append: " + path);

      for (auto& batch : work) {
        if (fout) fout.write(batch->data_char, batch->size);
        todoBytes -= batch->size;
        writtenBytes += batch->size;
      }

      fout.close();
      if (!fout) error->fail("write failed (disk full?): " + path);

      {
        std::lock_guard<std::mutex> lockT(mtx_todo);
        std::lock_guard<std::mutex> lockJ(mtx_join);
        auto itLocks = locks.find(path);
        locks.erase(itLocks);
      }
    }
  }

  // ConcurrentWriter.h:183-192
  void write(const string& path, shared_ptr<Buffer> data) {
    std::lock_guard<std::mutex> lock(mtx_todo);
    todoBytes += data->size;
    todo[path].push_back(data);
  }

  // ConcurrentWriter.h:194-211
  void join() {
    {
      std::lock_guard<std::mutex> lock(mtx_join);
      joinRequested = true;
    }
    for (auto& t : threads) {
      if (t.joinable()) t.join();
    }
    threads.clear();
  }
};

}  // namespace aether::pointcloud_lod_build::pc
