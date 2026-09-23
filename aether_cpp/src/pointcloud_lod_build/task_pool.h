// Port of PotreeConverter 2.0 @ 8bfad98 (BSD-2-Clause):
// Converter/modules/unsuck/TaskPool.hpp. Unchanged apart from the unreachable
// "thread wasn't joinable -> exit(746345)" branch (D2) and integer types (D1).
#pragma once

#include <atomic>
#include <chrono>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

namespace aether::pointcloud_lod_build::pc {

template <class Task>
class TaskPool {
 public:
  size_t numThreads = 0;
  std::deque<std::shared_ptr<Task>> tasks;
  using TaskProcessorType = std::function<void(std::shared_ptr<Task>)>;
  TaskProcessorType processor;

  std::vector<std::thread> threads;

  std::atomic<bool> isClosed = false;
  std::atomic<int> busyThreads = 0;

  std::mutex mtx_task;

  TaskPool(size_t numThreads_, TaskProcessorType processor_) {
    this->numThreads = numThreads_;
    this->processor = processor_;

    for (size_t i = 0; i < numThreads; i++) {
      threads.emplace_back([this]() {
        while (true) {
          std::shared_ptr<Task> task = nullptr;

          {  // retrieve task or leave thread if done
            std::lock_guard<std::mutex> lock(mtx_task);

            bool allDone = tasks.size() == 0 && isClosed;
            bool workAvailable = tasks.size() > 0;

            if (allDone) {
              break;
            } else if (workAvailable) {
              task = tasks.front();
              tasks.pop_front();

              if (task != nullptr) busyThreads++;
            }
          }

          if (task != nullptr) {
            this->processor(task);
            busyThreads--;
          }

          std::this_thread::sleep_for(std::chrono::milliseconds(10));
        }
      });
    }
  }

  TaskPool(const TaskPool&) = delete;
  TaskPool& operator=(const TaskPool&) = delete;

  ~TaskPool() { this->close(); }

  void addTask(std::shared_ptr<Task> t) {
    std::lock_guard<std::mutex> lock(mtx_task);
    tasks.push_back(t);
  }

  void close() {
    if (isClosed) return;
    isClosed = true;
    for (std::thread& t : threads) {
      if (t.joinable()) t.join();
    }
  }

  void waitTillEmpty() {
    while (true) {
      size_t size = 0;
      {
        std::lock_guard<std::mutex> lock(mtx_task);
        size = tasks.size();
      }
      if (size == 0) return;
      std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
  }
};

}  // namespace aether::pointcloud_lod_build::pc
