// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_MEMORY_FIXED_VEC_H
#define AETHER_MEMORY_FIXED_VEC_H

#include <cstddef>

namespace aether {
namespace memory {

template <typename T, size_t N>
struct FixedVec {
    T data[N];
    size_t len{0};

    void push_back(const T& v) {
        if (len < N) data[len++] = v;
    }
    size_t size() const { return len; }
    bool empty() const { return len == 0; }
    void clear() { len = 0; }
    T& operator[](size_t i) { return data[i]; }
    const T& operator[](size_t i) const { return data[i]; }
};

}  // namespace memory
}  // namespace aether

#endif  // AETHER_MEMORY_FIXED_VEC_H
