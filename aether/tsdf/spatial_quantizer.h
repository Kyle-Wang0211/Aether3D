// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_TSDF_SPATIAL_QUANTIZER_H
#define AETHER_TSDF_SPATIAL_QUANTIZER_H

#ifdef __cplusplus

#include "aether/core/status.h"

#include <cstdint>

namespace aether {
namespace tsdf {

struct QuantizedPosition {
    std::int32_t x{0};
    std::int32_t y{0};
    std::int32_t z{0};
};

core::Status quantize_world_position(
    double world_x,
    double world_y,
    double world_z,
    double origin_x,
    double origin_y,
    double origin_z,
    double cell_size_meters,
    QuantizedPosition* out_position);

core::Status morton_encode_21bit(
    std::int32_t x,
    std::int32_t y,
    std::int32_t z,
    std::uint64_t* out_code);

core::Status morton_decode_21bit(
    std::uint64_t code,
    QuantizedPosition* out_position);

core::Status dequantize_world_position(
    const QuantizedPosition& position,
    double origin_x,
    double origin_y,
    double origin_z,
    double cell_size_meters,
    double* out_world_x,
    double* out_world_y,
    double* out_world_z);

// ---------------------------------------------------------------------------
// SpatialQuantizer: struct-based API with efficient Morton code support.
// Supports 3 x 21-bit coordinates for up to 2^21 grid cells per axis.
// Morton code = Z-order curve interleaving of (x, y, z) into 64 bits.
// ---------------------------------------------------------------------------
struct SpatialQuantizer {
    float origin_x{0.0f};
    float origin_y{0.0f};
    float origin_z{0.0f};
    float cell_size{1.0f};

    // Quantize world position to integer grid coordinates.
    void quantize(float wx, float wy, float wz,
                  std::int32_t& gx, std::int32_t& gy, std::int32_t& gz) const noexcept;

    // Convert grid coords back to world position (center of cell).
    void world_position(std::int32_t gx, std::int32_t gy, std::int32_t gz,
                        float& wx, float& wy, float& wz) const noexcept;

    // Compute Morton code (Z-order curve) from grid coordinates.
    // Uses efficient magic-number bit-spread for 3 x 21 bits.
    static std::uint64_t morton_encode(std::int32_t x, std::int32_t y, std::int32_t z) noexcept;

    // Decode Morton code back to grid coordinates.
    static void morton_decode(std::uint64_t code,
                              std::int32_t& x, std::int32_t& y, std::int32_t& z) noexcept;

    // Convenience: world position -> Morton code.
    std::uint64_t morton_code(float wx, float wy, float wz) const noexcept;
};

}  // namespace tsdf
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_TSDF_SPATIAL_QUANTIZER_H
