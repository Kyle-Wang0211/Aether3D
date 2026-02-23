// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_MEMORY_POOL_H
#define AETHER_MEMORY_POOL_H

#include <cstddef>

namespace aether {
namespace memory {

/// Free-list pool for fixed-size objects
template <size_t N>
struct Pool {
    static constexpr size_t slot_size = N;
    void* free_list{nullptr};
    void* storage{nullptr};
    size_t capacity{0};

    void init(size_t) {}
    void* allocate() { return nullptr; }
    void deallocate(void*) {}
};

}  // namespace memory
}  // namespace aether

#endif  // AETHER_MEMORY_POOL_H
