// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_CORE_SPSC_QUEUE_H
#define AETHER_CORE_SPSC_QUEUE_H

#ifdef __cplusplus

#include <atomic>
#include <cstddef>
#include <new>
#include <type_traits>
#include <utility>

namespace aether {
namespace core {

// ═══════════════════════════════════════════════════════════════════════
// SPSCQueue: Lock-free single-producer single-consumer ring buffer
// ═══════════════════════════════════════════════════════════════════════
// Thread model:
//   - Exactly ONE producer thread calls try_push()
//   - Exactly ONE consumer thread calls try_pop()
//   - No mutex, no CAS loop, pure acquire/release ordering
//
// Capacity must be power-of-2 (enforced at construction).
// Overflow: try_push returns false (caller decides to drop or block).

template <typename T, std::size_t Capacity>
class SPSCQueue {
    static_assert((Capacity & (Capacity - 1)) == 0,
                  "SPSCQueue capacity must be a power of 2");
    static_assert(Capacity >= 2, "SPSCQueue capacity must be >= 2");

public:
    SPSCQueue() noexcept : head_(0), tail_(0) {}

    ~SPSCQueue() noexcept {
        // Drain remaining elements
        T tmp;
        while (try_pop(tmp)) {}
    }

    // Non-copyable, non-movable
    SPSCQueue(const SPSCQueue&) = delete;
    SPSCQueue& operator=(const SPSCQueue&) = delete;

    /// Producer: try to enqueue an element.
    /// Returns false if queue is full (caller should drop or retry).
    bool try_push(const T& item) noexcept {
        const std::size_t h = head_.load(std::memory_order_relaxed);
        const std::size_t next_h = (h + 1) & kMask;

        if (next_h == tail_.load(std::memory_order_acquire)) {
            return false;  // Full
        }

        new (&storage_[h]) T(item);
        head_.store(next_h, std::memory_order_release);
        return true;
    }

    /// Producer: try to enqueue an element (move).
    bool try_push(T&& item) noexcept {
        const std::size_t h = head_.load(std::memory_order_relaxed);
        const std::size_t next_h = (h + 1) & kMask;

        if (next_h == tail_.load(std::memory_order_acquire)) {
            return false;
        }

        new (&storage_[h]) T(std::move(item));
        head_.store(next_h, std::memory_order_release);
        return true;
    }

    /// Consumer: try to dequeue an element.
    /// Returns false if queue is empty.
    bool try_pop(T& out) noexcept {
        const std::size_t t = tail_.load(std::memory_order_relaxed);

        if (t == head_.load(std::memory_order_acquire)) {
            return false;  // Empty
        }

        T* ptr = reinterpret_cast<T*>(&storage_[t]);
        out = std::move(*ptr);
        ptr->~T();

        tail_.store((t + 1) & kMask, std::memory_order_release);
        return true;
    }

    /// Approximate size (may be stale).
    std::size_t size_approx() const noexcept {
        std::size_t h = head_.load(std::memory_order_relaxed);
        std::size_t t = tail_.load(std::memory_order_relaxed);
        return (h - t) & kMask;
    }

    bool empty() const noexcept {
        return head_.load(std::memory_order_relaxed) ==
               tail_.load(std::memory_order_relaxed);
    }

    static constexpr std::size_t capacity() noexcept { return Capacity; }

private:
    static constexpr std::size_t kMask = Capacity - 1;

    // Cache-line padding to prevent false sharing
    alignas(64) std::atomic<std::size_t> head_;
    alignas(64) std::atomic<std::size_t> tail_;
    alignas(64) typename std::aligned_storage<sizeof(T), alignof(T)>::type
        storage_[Capacity];
};

}  // namespace core
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_CORE_SPSC_QUEUE_H
