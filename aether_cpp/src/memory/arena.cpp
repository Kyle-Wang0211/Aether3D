// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/memory/arena.h"
#include <cstdlib>
#include <cstring>

namespace aether {
namespace memory {

Arena::~Arena() {
    std::free(data);
    data = nullptr;
    capacity = used = 0;
}

void Arena::init(size_t cap) {
    if (data) std::free(data);
    data = static_cast<uint8_t*>(std::malloc(cap));
    capacity = data ? cap : 0;
    used = 0;
}

void* Arena::allocate(size_t size, size_t alignment) {
    if (!data || size == 0 || alignment == 0) return nullptr;
    // Round up used to next multiple of alignment.
    size_t aligned = (used + alignment - 1) & ~(alignment - 1);
    // Overflow-safe check: if aligned + size wraps around or exceeds capacity.
    if (size > capacity || aligned > capacity - size) return nullptr;
    void* ptr = data + aligned;
    used = aligned + size;
    return ptr;
}

}  // namespace memory
}  // namespace aether
