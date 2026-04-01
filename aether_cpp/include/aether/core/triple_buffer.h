// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_CORE_TRIPLE_BUFFER_H
#define AETHER_CORE_TRIPLE_BUFFER_H

#ifdef __cplusplus

#include <atomic>
#include <cstdint>

namespace aether {
namespace core {

// ═══════════════════════════════════════════════════════════════════════
// TripleBuffer: Lock-free producer→consumer snapshot exchange
// ═══════════════════════════════════════════════════════════════════════
// Thread model:
//   - ONE writer thread: write_buffer() → modify → publish()
//   - ONE reader thread: read_buffer() → read snapshot
//
// The writer always has a clean buffer to write to (never blocks).
// The reader always sees the most recently published snapshot.
// No mutex, no allocation, single atomic operation.
//
// Layout: 3 slots [0, 1, 2]
//   - Writer owns one slot (writes into it)
//   - Reader owns one slot (reads from it)
//   - Middle slot: most recently published (swapped atomically)

template <typename T>
class TripleBuffer {
public:
    TripleBuffer() noexcept : buffers_{}, middle_(1), dirty_(false) {
        writer_idx_ = 0;
        reader_idx_ = 2;
    }

    explicit TripleBuffer(const T& initial) noexcept
        : buffers_{initial, initial, initial},
          middle_(1), dirty_(false) {
        writer_idx_ = 0;
        reader_idx_ = 2;
    }

    // Non-copyable, non-movable
    TripleBuffer(const TripleBuffer&) = delete;
    TripleBuffer& operator=(const TripleBuffer&) = delete;

    /// Writer: get mutable reference to write buffer.
    /// Safe to modify the returned reference until publish().
    T& write_buffer() noexcept {
        return buffers_[writer_idx_];
    }

    /// Writer: publish the current write buffer.
    /// Atomically swaps write buffer with middle buffer.
    void publish() noexcept {
        // Swap writer_idx_ with middle_
        std::uint8_t old_middle = middle_.exchange(
            writer_idx_, std::memory_order_acq_rel);
        writer_idx_ = old_middle;
        dirty_.store(true, std::memory_order_release);
    }

    /// Reader: get const reference to most recently published snapshot.
    /// If new data is available, swaps reader with middle first.
    const T& read_buffer() noexcept {
        if (dirty_.load(std::memory_order_acquire)) {
            // Swap reader_idx_ with middle_
            std::uint8_t old_middle = middle_.exchange(
                reader_idx_, std::memory_order_acq_rel);
            reader_idx_ = old_middle;
            dirty_.store(false, std::memory_order_release);
        }
        return buffers_[reader_idx_];
    }

    /// Reader: check if new data has been published since last read.
    bool has_new_data() const noexcept {
        return dirty_.load(std::memory_order_acquire);
    }

private:
    T buffers_[3];
    std::atomic<std::uint8_t> middle_;
    std::atomic<bool> dirty_;
    std::uint8_t writer_idx_;   // Only accessed by writer thread
    std::uint8_t reader_idx_;   // Only accessed by reader thread
};

}  // namespace core
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_CORE_TRIPLE_BUFFER_H
