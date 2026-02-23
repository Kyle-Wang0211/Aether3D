// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_MEMORY_SPAN_H
#define AETHER_MEMORY_SPAN_H

#include <cstddef>

namespace aether {
namespace memory {

template <typename T>
struct Span {
    T* data{nullptr};
    size_t size{0};

    Span() = default;
    Span(T* d, size_t s) : data(d), size(s) {}

    T* begin() { return data; }
    T* end() { return data + size; }
    const T* begin() const { return data; }
    const T* end() const { return data + size; }
    T& operator[](size_t i) { return data[i]; }
    const T& operator[](size_t i) const { return data[i]; }
    bool empty() const { return size == 0; }
};

}  // namespace memory
}  // namespace aether

#endif  // AETHER_MEMORY_SPAN_H
