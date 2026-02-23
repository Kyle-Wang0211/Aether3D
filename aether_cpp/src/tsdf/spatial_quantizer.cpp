// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/tsdf/spatial_quantizer.h"

#include <cmath>
#include <limits>

namespace aether {
namespace tsdf {

core::Status quantize_world_position(
    double world_x,
    double world_y,
    double world_z,
    double origin_x,
    double origin_y,
    double origin_z,
    double cell_size_meters,
    QuantizedPosition* out_position) {
    if (out_position == nullptr) {
        return core::Status::kInvalidArgument;
    }
    if (!std::isfinite(world_x) || !std::isfinite(world_y) || !std::isfinite(world_z) ||
        !std::isfinite(origin_x) || !std::isfinite(origin_y) || !std::isfinite(origin_z) ||
        !std::isfinite(cell_size_meters) || cell_size_meters <= 0.0) {
        return core::Status::kInvalidArgument;
    }

    const double sx = std::trunc((world_x - origin_x) / cell_size_meters);
    const double sy = std::trunc((world_y - origin_y) / cell_size_meters);
    const double sz = std::trunc((world_z - origin_z) / cell_size_meters);
    if (!std::isfinite(sx) || !std::isfinite(sy) || !std::isfinite(sz)) {
        return core::Status::kOutOfRange;
    }

    const double i32_min = static_cast<double>(std::numeric_limits<std::int32_t>::min());
    const double i32_max = static_cast<double>(std::numeric_limits<std::int32_t>::max());
    if (sx < i32_min || sx > i32_max ||
        sy < i32_min || sy > i32_max ||
        sz < i32_min || sz > i32_max) {
        return core::Status::kOutOfRange;
    }

    out_position->x = static_cast<std::int32_t>(sx);
    out_position->y = static_cast<std::int32_t>(sy);
    out_position->z = static_cast<std::int32_t>(sz);
    return core::Status::kOk;
}

core::Status morton_encode_21bit(
    std::int32_t x,
    std::int32_t y,
    std::int32_t z,
    std::uint64_t* out_code) {
    if (out_code == nullptr) {
        return core::Status::kInvalidArgument;
    }
    const std::uint32_t ux = static_cast<std::uint32_t>(x);
    const std::uint32_t uy = static_cast<std::uint32_t>(y);
    const std::uint32_t uz = static_cast<std::uint32_t>(z);

    std::uint64_t code = 0u;
    for (int i = 0; i < 21; ++i) {
        const std::uint32_t bit_x = (ux >> i) & 1u;
        const std::uint32_t bit_y = (uy >> i) & 1u;
        const std::uint32_t bit_z = (uz >> i) & 1u;
        code |= static_cast<std::uint64_t>(bit_x) << (i * 3);
        code |= static_cast<std::uint64_t>(bit_y) << (i * 3 + 1);
        code |= static_cast<std::uint64_t>(bit_z) << (i * 3 + 2);
    }

    *out_code = code;
    return core::Status::kOk;
}

core::Status morton_decode_21bit(
    std::uint64_t code,
    QuantizedPosition* out_position) {
    if (out_position == nullptr) {
        return core::Status::kInvalidArgument;
    }

    std::uint32_t x = 0u;
    std::uint32_t y = 0u;
    std::uint32_t z = 0u;
    for (int i = 0; i < 21; ++i) {
        const std::uint32_t bit_x = static_cast<std::uint32_t>((code >> (i * 3)) & 1u);
        const std::uint32_t bit_y = static_cast<std::uint32_t>((code >> (i * 3 + 1)) & 1u);
        const std::uint32_t bit_z = static_cast<std::uint32_t>((code >> (i * 3 + 2)) & 1u);
        x |= bit_x << i;
        y |= bit_y << i;
        z |= bit_z << i;
    }

    out_position->x = static_cast<std::int32_t>(x);
    out_position->y = static_cast<std::int32_t>(y);
    out_position->z = static_cast<std::int32_t>(z);
    return core::Status::kOk;
}

core::Status dequantize_world_position(
    const QuantizedPosition& position,
    double origin_x,
    double origin_y,
    double origin_z,
    double cell_size_meters,
    double* out_world_x,
    double* out_world_y,
    double* out_world_z) {
    if (out_world_x == nullptr || out_world_y == nullptr || out_world_z == nullptr) {
        return core::Status::kInvalidArgument;
    }
    if (!std::isfinite(origin_x) || !std::isfinite(origin_y) || !std::isfinite(origin_z) ||
        !std::isfinite(cell_size_meters) || cell_size_meters <= 0.0) {
        return core::Status::kInvalidArgument;
    }

    *out_world_x = origin_x + static_cast<double>(position.x) * cell_size_meters;
    *out_world_y = origin_y + static_cast<double>(position.y) * cell_size_meters;
    *out_world_z = origin_z + static_cast<double>(position.z) * cell_size_meters;
    return core::Status::kOk;
}

// ---------------------------------------------------------------------------
// Efficient magic-number bit-spread for 3 x 21-bit Morton encoding.
// ---------------------------------------------------------------------------
namespace {

// Spread 21 bits of x across 63 bit positions (every 3rd bit).
static std::uint64_t split_by_3(std::uint64_t x) noexcept {
    x &= 0x1fffffULL;  // 21 bits
    x = (x | (x << 32)) & 0x1f00000000ffffULL;
    x = (x | (x << 16)) & 0x1f0000ff0000ffULL;
    x = (x | (x << 8))  & 0x100f00f00f00f00fULL;
    x = (x | (x << 4))  & 0x10c30c30c30c30c3ULL;
    x = (x | (x << 2))  & 0x1249249249249249ULL;
    return x;
}

// Compact every 3rd bit back into contiguous 21 bits.
static std::uint64_t compact_by_3(std::uint64_t x) noexcept {
    x &= 0x1249249249249249ULL;
    x = (x | (x >> 2))  & 0x10c30c30c30c30c3ULL;
    x = (x | (x >> 4))  & 0x100f00f00f00f00fULL;
    x = (x | (x >> 8))  & 0x1f0000ff0000ffULL;
    x = (x | (x >> 16)) & 0x1f00000000ffffULL;
    x = (x | (x >> 32)) & 0x1fffffULL;
    return x;
}

}  // namespace

// ---------------------------------------------------------------------------
// SpatialQuantizer implementation
// ---------------------------------------------------------------------------

void SpatialQuantizer::quantize(float wx, float wy, float wz,
                                std::int32_t& gx, std::int32_t& gy, std::int32_t& gz) const noexcept {
    gx = static_cast<std::int32_t>(std::floor((wx - origin_x) / cell_size));
    gy = static_cast<std::int32_t>(std::floor((wy - origin_y) / cell_size));
    gz = static_cast<std::int32_t>(std::floor((wz - origin_z) / cell_size));
}

void SpatialQuantizer::world_position(std::int32_t gx, std::int32_t gy, std::int32_t gz,
                                      float& wx, float& wy, float& wz) const noexcept {
    wx = origin_x + (static_cast<float>(gx) + 0.5f) * cell_size;
    wy = origin_y + (static_cast<float>(gy) + 0.5f) * cell_size;
    wz = origin_z + (static_cast<float>(gz) + 0.5f) * cell_size;
}

std::uint64_t SpatialQuantizer::morton_encode(std::int32_t x, std::int32_t y, std::int32_t z) noexcept {
    const std::uint64_t ux = static_cast<std::uint64_t>(static_cast<std::uint32_t>(x));
    const std::uint64_t uy = static_cast<std::uint64_t>(static_cast<std::uint32_t>(y));
    const std::uint64_t uz = static_cast<std::uint64_t>(static_cast<std::uint32_t>(z));
    return split_by_3(ux) | (split_by_3(uy) << 1) | (split_by_3(uz) << 2);
}

void SpatialQuantizer::morton_decode(std::uint64_t code,
                                     std::int32_t& x, std::int32_t& y, std::int32_t& z) noexcept {
    x = static_cast<std::int32_t>(static_cast<std::uint32_t>(compact_by_3(code)));
    y = static_cast<std::int32_t>(static_cast<std::uint32_t>(compact_by_3(code >> 1)));
    z = static_cast<std::int32_t>(static_cast<std::uint32_t>(compact_by_3(code >> 2)));
}

std::uint64_t SpatialQuantizer::morton_code(float wx, float wy, float wz) const noexcept {
    std::int32_t gx = 0;
    std::int32_t gy = 0;
    std::int32_t gz = 0;
    quantize(wx, wy, wz, gx, gy, gz);
    return morton_encode(gx, gy, gz);
}

// ---------------------------------------------------------------------------
// 3D Hilbert curve encoding/decoding using state-transition lookup tables.
//
// For 3 dimensions, the Hilbert curve has 12 orientation states.  Each level
// of recursion processes one bit from each axis (an "octant"), mapping it to
// a sub-index (0–7) along the curve, then transitioning to a child state.
//
// The table was generated from Hamilton & Rau-Chaplin's Gray-code-based
// method ("Compact Hilbert Indices for Multi-Dimensional Data").
//
// Encode: O(B) where B = bits per axis = 21.  Decode uses a precomputed
// reverse table, also O(B).  No recursion, no dynamic allocation.
// ---------------------------------------------------------------------------
namespace {

static constexpr int kHilbertBits = 21;  // bits per axis
static constexpr std::uint32_t kHilbertMask = (1u << kHilbertBits) - 1u;

struct HilbertEntry { std::uint8_t sub_index; std::uint8_t next_state; };

// 12 orientation states × 8 octants.
// Generated by enumerating reachable (entry_point, direction) pairs starting
// from state 0 = (entry=0, dir=0).
static constexpr HilbertEntry kHilbertTable[12][8] = {
    // State 0: entry=0, dir=0
    {{0,1}, {7,2}, {1,3}, {6,4}, {3,5}, {4,5}, {2,3}, {5,4}},
    // State 1: entry=0, dir=1
    {{0,3}, {3,6}, {7,7}, {4,6}, {1,0}, {2,0}, {6,8}, {5,8}},
    // State 2: entry=3, dir=1
    {{4,9}, {7,4}, {3,9}, {0,10}, {5,0}, {6,0}, {2,8}, {1,8}},
    // State 3: entry=0, dir=2
    {{0,0}, {1,1}, {3,10}, {2,1}, {7,11}, {6,9}, {4,10}, {5,9}},
    // State 4: entry=5, dir=2
    {{6,2}, {7,0}, {5,2}, {4,7}, {1,6}, {0,11}, {2,6}, {3,7}},
    // State 5: entry=6, dir=0
    {{2,7}, {5,10}, {3,0}, {4,0}, {1,7}, {6,10}, {0,9}, {7,6}},
    // State 6: entry=5, dir=1
    {{2,11}, {1,11}, {5,5}, {6,5}, {3,1}, {0,4}, {4,1}, {7,10}},
    // State 7: entry=6, dir=2
    {{4,4}, {5,1}, {7,8}, {6,1}, {3,4}, {2,9}, {0,5}, {1,9}},
    // State 8: entry=3, dir=0
    {{6,7}, {1,10}, {7,1}, {0,2}, {5,7}, {2,10}, {4,11}, {3,11}},
    // State 9: entry=6, dir=1
    {{6,11}, {5,11}, {1,5}, {2,5}, {7,3}, {4,2}, {0,7}, {3,2}},
    // State 10: entry=3, dir=2
    {{2,2}, {3,3}, {1,2}, {0,8}, {5,6}, {4,3}, {6,6}, {7,5}},
    // State 11: entry=5, dir=0
    {{4,8}, {3,8}, {5,3}, {2,4}, {7,9}, {0,6}, {6,3}, {1,4}},
};

// Reverse lookup: kHilbertReverse[state][sub_index] = octant.
// Built at compile time from kHilbertTable.
struct HilbertReverse {
    std::uint8_t rev[12][8];
    constexpr HilbertReverse() : rev{} {
        for (int s = 0; s < 12; ++s)
            for (std::uint8_t o = 0; o < 8; ++o)
                rev[s][kHilbertTable[s][o].sub_index] = o;
    }
};

static constexpr HilbertReverse kHilbertReverse{};

}  // namespace

std::uint64_t SpatialQuantizer::hilbert_encode(std::int32_t x, std::int32_t y, std::int32_t z) noexcept {
    const std::uint32_t ux = static_cast<std::uint32_t>(x) & kHilbertMask;
    const std::uint32_t uy = static_cast<std::uint32_t>(y) & kHilbertMask;
    const std::uint32_t uz = static_cast<std::uint32_t>(z) & kHilbertMask;

    std::uint64_t h = 0u;
    std::uint8_t state = 0u;
    for (int i = kHilbertBits - 1; i >= 0; --i) {
        const std::uint8_t octant = static_cast<std::uint8_t>(
            ((ux >> i) & 1u) | (((uy >> i) & 1u) << 1) | (((uz >> i) & 1u) << 2));
        const auto& e = kHilbertTable[state][octant];
        h = (h << 3) | e.sub_index;
        state = e.next_state;
    }
    return h;
}

void SpatialQuantizer::hilbert_decode(std::uint64_t code,
                                       std::int32_t& x, std::int32_t& y, std::int32_t& z) noexcept {
    std::uint32_t ux = 0u;
    std::uint32_t uy = 0u;
    std::uint32_t uz = 0u;
    std::uint8_t state = 0u;
    for (int i = kHilbertBits - 1; i >= 0; --i) {
        const std::uint8_t sub_idx = static_cast<std::uint8_t>((code >> (i * 3)) & 7u);
        const std::uint8_t octant = kHilbertReverse.rev[state][sub_idx];
        ux |= (octant & 1u) << i;
        uy |= ((octant >> 1) & 1u) << i;
        uz |= ((octant >> 2) & 1u) << i;
        state = kHilbertTable[state][octant].next_state;
    }
    x = static_cast<std::int32_t>(ux);
    y = static_cast<std::int32_t>(uy);
    z = static_cast<std::int32_t>(uz);
}

std::uint64_t SpatialQuantizer::hilbert_code(float wx, float wy, float wz) const noexcept {
    std::int32_t gx = 0;
    std::int32_t gy = 0;
    std::int32_t gz = 0;
    quantize(wx, wy, wz, gx, gy, gz);
    return hilbert_encode(gx, gy, gz);
}

}  // namespace tsdf
}  // namespace aether
