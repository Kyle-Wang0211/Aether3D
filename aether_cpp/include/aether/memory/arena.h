// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_CPP_MEMORY_ARENA_H
#define AETHER_CPP_MEMORY_ARENA_H

#ifdef __cplusplus

#include <cstddef>
#include <cstdint>

namespace aether {
namespace memory {

// Simple bump allocator for frame-scoped temporary storage.
struct Arena {
    std::uint8_t* data{nullptr};
    std::size_t capacity{0};
    std::size_t used{0};

    Arena() = default;
    ~Arena();

    void init(std::size_t cap);
    void reset() { used = 0; }
    void* allocate(std::size_t size, std::size_t alignment);
};

}  // namespace memory
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_CPP_MEMORY_ARENA_H
