// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_CORE_CANONICALIZE_H
#define AETHER_CORE_CANONICALIZE_H

#include <cstdint>

namespace aether {
namespace core {

/// Canonicalize block coordinate for deterministic ordering
void canonicalize_block(int32_t x, int32_t y, int32_t z,
                        int32_t& out_x, int32_t& out_y, int32_t& out_z);

/// Canonicalize a float to deterministic bit pattern.
/// Flushes denormals to +0, collapses -0 to +0, replaces NaN with 0.
inline float canonicalize_float(float v) {
    // NaN check (NaN != NaN)
    if (v != v) return 0.0f;
    // Flush denormals: fabsf < FLT_MIN but != 0
    union { float f; uint32_t u; } bits;
    bits.f = v;
    uint32_t exp = (bits.u >> 23) & 0xFF;
    if (exp == 0) return 0.0f;   // denormal or -0 -> +0
    return v;
}

}  // namespace core
}  // namespace aether

#endif  // AETHER_CORE_CANONICALIZE_H
