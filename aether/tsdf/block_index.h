// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// aether/tsdf/block_index.h
// Block coordinate + Nießner hash (Swift BlockIndex parity)

#ifndef AETHER_TSDF_BLOCK_INDEX_H
#define AETHER_TSDF_BLOCK_INDEX_H

#include <cstdlib>
#include <cstdint>
#include <cstddef>

namespace aether {
namespace tsdf {

struct BlockIndex {
    int32_t x{0};
    int32_t y{0};
    int32_t z{0};

    BlockIndex() = default;
    constexpr BlockIndex(int32_t x_, int32_t y_, int32_t z_) : x(x_), y(y_), z(z_) {}

    [[nodiscard]] int niessner_hash(int table_size) const noexcept {
        const uint64_t ux = static_cast<uint32_t>(x);
        const uint64_t uy = static_cast<uint32_t>(y);
        const uint64_t uz = static_cast<uint32_t>(z);
        const uint64_t h = (ux * 73856093ULL) ^ (uy * 19349669ULL) ^ (uz * 83492791ULL);
        return static_cast<int>(h % static_cast<uint64_t>(table_size));
    }

    constexpr BlockIndex operator+(const BlockIndex& rhs) const {
        return BlockIndex(x + rhs.x, y + rhs.y, z + rhs.z);
    }

    constexpr bool operator==(const BlockIndex& rhs) const {
        return x == rhs.x && y == rhs.y && z == rhs.z;
    }

    constexpr bool operator!=(const BlockIndex& rhs) const {
        return !(*this == rhs);
    }
};

constexpr BlockIndex kFaceNeighborOffsets[6] = {
    BlockIndex(1, 0, 0), BlockIndex(-1, 0, 0),
    BlockIndex(0, 1, 0), BlockIndex(0, -1, 0),
    BlockIndex(0, 0, 1), BlockIndex(0, 0, -1),
};

}  // namespace tsdf
}  // namespace aether

#endif  // AETHER_TSDF_BLOCK_INDEX_H
