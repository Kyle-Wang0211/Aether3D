// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_CPP_SPLAT_SPZ_DECODER_H
#define AETHER_CPP_SPLAT_SPZ_DECODER_H

#ifdef __cplusplus

#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <vector>

#include "aether/core/status.h"
#include "aether/splat/packed_splats.h"

namespace aether {
namespace splat {

// ═══════════════════════════════════════════════════════════════════════
// SPZ Decoder: Niantic compressed splat format
// ═══════════════════════════════════════════════════════════════════════
// Reference: Spark rust/spz.rs (World Labs, MIT) + Niantic SPZ spec.
//
// SPZ is a compressed 3DGS format (~10x smaller than PLY):
//   1. gzip-compressed outer container
//   2. Fixed header: magic, version, feature flags, splat count
//   3. Quantized attribute streams (position, color, scale, rotation, opacity)
//
// Versions supported: v2, v3

/// SPZ file header (little-endian, after gzip decompression).
struct SpzHeader {
    std::uint32_t magic;           // "SPZ\0" = 0x005A5053
    std::uint32_t version;         // 2 or 3
    std::uint32_t num_points;      // number of Gaussians
    std::uint8_t  sh_degree;       // 0=DC only, 1=L1, 2=L2, 3=L3
    std::uint8_t  fractional_bits; // position quantization fractional bits
    std::uint8_t  flags;           // bitfield: antialiased, etc.
    std::uint8_t  reserved;
};

static_assert(sizeof(SpzHeader) == 16, "SpzHeader must be 16 bytes");

/// SPZ magic number: "SPZ\0"
constexpr std::uint32_t kSpzMagic = 0x005A5053u;

/// Result of decoding an SPZ file.
struct SpzDecodeResult {
    std::vector<GaussianParams> gaussians;
    std::uint32_t num_points{0};
    std::uint8_t sh_degree{0};
};

// ─── gzip decompression ─────────────────────────────────────────────
// SPZ files are gzip-compressed. We use a minimal inflate implementation
// or delegate to platform zlib. For portability, we define the interface
// and provide a zlib-backed implementation.

/// Decompress gzip data.
/// Returns decompressed bytes, or empty vector on failure.
/// Platform must provide zlib (available on iOS/Android/HarmonyOS).
inline std::vector<std::uint8_t> gzip_decompress(
    const std::uint8_t* data, std::size_t size) noexcept
{
    // Minimal gzip header check
    if (size < 10 || data[0] != 0x1F || data[1] != 0x8B) {
        return {};
    }

    // Use zlib for decompression (linked on all target platforms)
    // For now, return empty — actual implementation requires zlib linkage.
    // The implementation will be in spz_decoder.cpp.
    (void)data;
    (void)size;
    return {};
}

/// Decode raw (already decompressed) SPZ data into GaussianParams.
///
/// Parameters:
///   data     — decompressed SPZ byte stream
///   size     — byte count
///   result   — output decoded Gaussians
///
/// Returns core::Status::kOk on success.
inline core::Status decode_spz_raw(const std::uint8_t* data,
                                    std::size_t size,
                                    SpzDecodeResult& result) noexcept {
    result.gaussians.clear();
    result.num_points = 0;
    result.sh_degree = 0;

    if (size < sizeof(SpzHeader)) {
        return core::Status::kInvalidArgument;
    }

    // Parse header
    SpzHeader header;
    std::memcpy(&header, data, sizeof(header));

    if (header.magic != kSpzMagic) {
        return core::Status::kInvalidArgument;
    }

    if (header.version < 2 || header.version > 3) {
        return core::Status::kInvalidArgument;
    }

    std::uint32_t n = header.num_points;
    if (n == 0) {
        return core::Status::kOk;  // Empty but valid
    }

    result.sh_degree = header.sh_degree;
    result.num_points = n;

    // ─── Compute expected stream sizes ──────────────────────────────
    // SPZ v2/v3 layout after header:
    //   positions:  n * 3 * 3 bytes (24-bit quantized xyz, delta-coded)
    //   colors:     n * 3 bytes (quantized RGB)
    //   alphas:     n bytes (quantized opacity)
    //   scales:     n * 3 bytes (quantized log-scale)
    //   rotations:  n * 3 bytes (quantized rotation, axis-angle or quat xyz)
    //   SH:         (if sh_degree > 0) n * sh_coeff_count * 3 bytes

    std::size_t pos_bytes = n * 9u;  // 3 components * 3 bytes each
    std::size_t color_bytes = n * 3u;
    std::size_t alpha_bytes = n;
    std::size_t scale_bytes = n * 3u;
    std::size_t rot_bytes = n * 3u;

    std::size_t min_size = sizeof(SpzHeader) + pos_bytes + color_bytes +
                           alpha_bytes + scale_bytes + rot_bytes;

    if (size < min_size) {
        return core::Status::kInvalidArgument;
    }

    // ─── Decode streams ─────────────────────────────────────────────
    const std::uint8_t* ptr = data + sizeof(SpzHeader);

    result.gaussians.resize(n);

    // Positions: 24-bit signed integers, delta-coded, scaled by 2^-fractional_bits
    float pos_scale = 1.0f / static_cast<float>(1u << header.fractional_bits);
    {
        std::int32_t prev[3] = {0, 0, 0};
        for (std::uint32_t i = 0; i < n; ++i) {
            for (int c = 0; c < 3; ++c) {
                // Read 3-byte signed integer (little-endian)
                std::int32_t val = static_cast<std::int32_t>(ptr[0]) |
                                   (static_cast<std::int32_t>(ptr[1]) << 8) |
                                   (static_cast<std::int32_t>(ptr[2]) << 16);
                // Sign-extend from 24-bit
                if (val & 0x800000) val |= static_cast<std::int32_t>(0xFF000000u);
                ptr += 3;

                prev[c] += val;  // Delta decode
                result.gaussians[i].position[c] = static_cast<float>(prev[c]) * pos_scale;
            }
        }
    }

    // Colors: uint8 quantized, delta-coded
    {
        std::uint8_t prev[3] = {0, 0, 0};
        for (std::uint32_t i = 0; i < n; ++i) {
            for (int c = 0; c < 3; ++c) {
                prev[c] = static_cast<std::uint8_t>(prev[c] + ptr[0]);
                ptr++;
                // Convert to linear [0,1] via sRGB decode
                result.gaussians[i].color[c] = srgb_byte_to_linear(prev[c]);
            }
        }
    }

    // Alphas: uint8, logit-space quantized
    {
        for (std::uint32_t i = 0; i < n; ++i) {
            // SPZ stores opacity as uint8 linear alpha (0=transparent, 255=opaque)
            result.gaussians[i].opacity = static_cast<float>(*ptr) / 255.0f;
            ptr++;
        }
    }

    // Scales: uint8 log-encoded, delta-coded
    {
        std::uint8_t prev[3] = {0, 0, 0};
        for (std::uint32_t i = 0; i < n; ++i) {
            for (int c = 0; c < 3; ++c) {
                prev[c] = static_cast<std::uint8_t>(prev[c] + ptr[0]);
                ptr++;
                result.gaussians[i].scale[c] = decode_log_scale(prev[c]);
            }
        }
    }

    // Rotations: 3 uint8 values representing quaternion xyz (w reconstructed)
    {
        for (std::uint32_t i = 0; i < n; ++i) {
            // Decode 3 bytes as signed rotation components in [-1,1]
            float qx = (static_cast<float>(ptr[0]) / 127.5f) - 1.0f;
            float qy = (static_cast<float>(ptr[1]) / 127.5f) - 1.0f;
            float qz = (static_cast<float>(ptr[2]) / 127.5f) - 1.0f;
            ptr += 3;

            // Reconstruct w = sqrt(1 - x^2 - y^2 - z^2)
            float sq = qx * qx + qy * qy + qz * qz;
            float qw = (sq < 1.0f) ? std::sqrt(1.0f - sq) : 0.0f;

            result.gaussians[i].rotation[0] = qw;
            result.gaussians[i].rotation[1] = qx;
            result.gaussians[i].rotation[2] = qy;
            result.gaussians[i].rotation[3] = qz;

            // Normalize
            float len = std::sqrt(qw * qw + qx * qx + qy * qy + qz * qz);
            if (len > 1e-8f) {
                float inv = 1.0f / len;
                result.gaussians[i].rotation[0] *= inv;
                result.gaussians[i].rotation[1] *= inv;
                result.gaussians[i].rotation[2] *= inv;
                result.gaussians[i].rotation[3] *= inv;
            } else {
                result.gaussians[i].rotation[0] = 1.0f;
                result.gaussians[i].rotation[1] = 0.0f;
                result.gaussians[i].rotation[2] = 0.0f;
                result.gaussians[i].rotation[3] = 0.0f;
            }
        }
    }

    // SH coefficients (higher order) — skip for now (DC-only rendering)

    return core::Status::kOk;
}

/// Decode a gzip-compressed SPZ file from memory.
/// Full pipeline: gzip decompress → parse header → decode streams.
core::Status decode_spz(const std::uint8_t* compressed_data,
                         std::size_t compressed_size,
                         SpzDecodeResult& result) noexcept;

/// Decode an SPZ file from disk.
core::Status load_spz(const char* path, SpzDecodeResult& result) noexcept;

}  // namespace splat
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_CPP_SPLAT_SPZ_DECODER_H
