// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_CPP_RENDER_GPU_HANDLE_H
#define AETHER_CPP_RENDER_GPU_HANDLE_H

#ifdef __cplusplus

#include <cstdint>
#include <cstring>

namespace aether {
namespace render {

// ═══════════════════════════════════════════════════════════════════════
// GPUHandle: Generation-counter based handle (Slotmap pattern)
// ═══════════════════════════════════════════════════════════════════════
//
// Bit layout:
//   High 16 bits: generation (wraps at 65535)
//   Low  16 bits: index     (max 65535 resources per type)
//
// This prevents use-after-free: when a resource is freed, its slot's
// generation is incremented. Any stale handle with the old generation
// will fail validation, even if the slot is reused.
//
// Compatible with -fno-exceptions -fno-rtti. No heap allocation.

struct GPUHandle {
    std::uint32_t packed{0};

    static constexpr std::uint32_t kInvalid = 0;
    static constexpr std::uint16_t kMaxIndex = 0xFFFF;
    static constexpr std::uint16_t kMaxGeneration = 0xFFFF;

    GPUHandle() = default;
    explicit GPUHandle(std::uint32_t raw) : packed(raw) {}

    static GPUHandle make(std::uint16_t index, std::uint16_t generation) noexcept {
        return GPUHandle{(static_cast<std::uint32_t>(generation) << 16) | index};
    }

    std::uint16_t index() const noexcept {
        return static_cast<std::uint16_t>(packed & 0xFFFF);
    }

    std::uint16_t generation() const noexcept {
        return static_cast<std::uint16_t>(packed >> 16);
    }

    bool is_valid() const noexcept { return packed != kInvalid; }

    bool operator==(GPUHandle other) const noexcept { return packed == other.packed; }
    bool operator!=(GPUHandle other) const noexcept { return packed != other.packed; }
};

// ═══════════════════════════════════════════════════════════════════════
// GPUSlotMap: O(1) allocation, deallocation, and lookup with
//             generation-based use-after-free protection.
// ═══════════════════════════════════════════════════════════════════════
//
// Thread-safe for single-writer scenarios (typical GPU command recording).
// No heap allocation — fixed capacity set at compile time.

template<typename T, std::uint16_t Capacity = 4096>
class GPUSlotMap {
public:
    GPUSlotMap() noexcept {
        // Initialize free list as a stack: [Capacity-1, ..., 1, 0]
        // so that the first pop yields index 0, then 1, etc.
        for (std::uint16_t i = 0; i < Capacity; ++i) {
            free_list_[i] = static_cast<std::uint16_t>(Capacity - 1 - i);
        }
    }

    // Allocate a slot with a moved value. Returns invalid handle if full.
    GPUHandle allocate(T&& value) noexcept {
        if (free_count_ == 0) {
            return GPUHandle{};
        }
        --free_count_;
        std::uint16_t idx = free_list_[free_count_];
        Slot& slot = slots_[idx];
        slot.value = static_cast<T&&>(value);
        slot.occupied = true;
        ++count_;
        return GPUHandle::make(idx, slot.generation);
    }

    // Allocate a slot with a copied value. Returns invalid handle if full.
    GPUHandle allocate(const T& value) noexcept {
        if (free_count_ == 0) {
            return GPUHandle{};
        }
        --free_count_;
        std::uint16_t idx = free_list_[free_count_];
        Slot& slot = slots_[idx];
        slot.value = value;
        slot.occupied = true;
        ++count_;
        return GPUHandle::make(idx, slot.generation);
    }

    // Free a slot. Returns false if handle is invalid/stale.
    bool free(GPUHandle handle) noexcept {
        if (!handle.is_valid()) {
            return false;
        }
        std::uint16_t idx = handle.index();
        if (idx >= Capacity) {
            return false;
        }
        Slot& slot = slots_[idx];
        if (!slot.occupied || slot.generation != handle.generation()) {
            return false;
        }
        slot.occupied = false;
        slot.value = T{};
        // Increment generation (wraps from 0xFFFF to 1, skipping 0).
        // Generation 0 is reserved as "never allocated" sentinel, so
        // wrapping to 0 would create handles equal to kInvalid when
        // combined with index 0. We skip 0 to avoid that.
        std::uint16_t next_gen = static_cast<std::uint16_t>(slot.generation + 1);
        if (next_gen == 0) {
            next_gen = 1;
        }
        slot.generation = next_gen;
        free_list_[free_count_] = idx;
        ++free_count_;
        --count_;
        return true;
    }

    // Lookup. Returns nullptr if handle is invalid/stale.
    T* get(GPUHandle handle) noexcept {
        if (!handle.is_valid()) {
            return nullptr;
        }
        std::uint16_t idx = handle.index();
        if (idx >= Capacity) {
            return nullptr;
        }
        Slot& slot = slots_[idx];
        if (!slot.occupied || slot.generation != handle.generation()) {
            return nullptr;
        }
        return &slot.value;
    }

    // Const lookup. Returns nullptr if handle is invalid/stale.
    const T* get(GPUHandle handle) const noexcept {
        if (!handle.is_valid()) {
            return nullptr;
        }
        std::uint16_t idx = handle.index();
        if (idx >= Capacity) {
            return nullptr;
        }
        const Slot& slot = slots_[idx];
        if (!slot.occupied || slot.generation != handle.generation()) {
            return nullptr;
        }
        return &slot.value;
    }

    // ─── Stats ───
    std::uint16_t count() const noexcept { return count_; }
    std::uint16_t capacity() const noexcept { return Capacity; }
    bool empty() const noexcept { return count_ == 0; }

    // Reset all slots. Generations are NOT reset, to catch stale handles.
    void clear() noexcept {
        free_count_ = Capacity;
        count_ = 0;
        for (std::uint16_t i = 0; i < Capacity; ++i) {
            slots_[i].occupied = false;
            slots_[i].value = T{};
            free_list_[i] = static_cast<std::uint16_t>(Capacity - 1 - i);
        }
    }

private:
    struct Slot {
        T value{};
        std::uint16_t generation{1};  // Start at 1 so generation 0 means "never allocated"
        bool occupied{false};
    };

    Slot slots_[Capacity];
    std::uint16_t free_list_[Capacity];  // Stack of free indices
    std::uint16_t free_count_{Capacity};
    std::uint16_t count_{0};
};

}  // namespace render
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_CPP_RENDER_GPU_HANDLE_H
