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

/// SPZ magic number: "NGSP" (Niantic Gaussian SPlat).
///
/// 2026-05-02 fix: previous value 0x005A5053 ("SPZ\0") was wrong —
/// Niantic's reference repo (nianticlabs/spz src/cc/load-spz.cc)
/// defines the magic as "NGSP" written little-endian. Verified by
/// decompressing the canonical hornedlizard.spz sample — first 4
/// bytes after gunzip = 0x4E 0x47 0x53 0x50.
///
/// Encoding: byte[0]='N'(0x4E) | byte[1]='G'(0x47) | byte[2]='S'(0x53)
///         | byte[3]='P'(0x50)  → little-endian u32 = 0x5053474E.
constexpr std::uint32_t kSpzMagic = 0x5053474Eu;

/// Result of decoding an SPZ file.
struct SpzDecodeResult {
    std::vector<GaussianParams> gaussians;
    /// Phase 6.4f.4.a — higher-order SH coefficients in PLY-native
    /// channel-major basis-major layout:
    ///   sh_rest[splat * (3 * non_dc_basis) +
    ///           channel * non_dc_basis + basis]
    /// where non_dc_basis = 0 / 3 / 8 / 15 for sh_degree 0 / 1 / 2 / 3.
    /// Empty when sh_degree == 0. Matches PlyLoadResult::sh_rest layout
    /// so build_splat_scene_from_gaussians can consume PLY and SPZ
    /// through the same path.
    std::vector<float> sh_rest;
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
    result.sh_rest.clear();

    // ─── SPZ v2 stream layout (post-header, all NON-delta) ────────────
    //
    // Reference: nianticlabs/spz src/cc/load-spz.cc lines 580-630.
    // The previous implementation here was wrong on every stream:
    //   - positions: was delta-coded across all N splats; should be
    //     ABSOLUTE per-splat fixed-point. With 786k splats the
    //     delta accumulation drove bounds to ±524k instead of the
    //     real ±1-5 unit lizard.
    //   - colors: was delta + sRGB-byte; should be SH DC quantization
    //     `byte → (byte/255 - 0.5) / 0.15`.
    //   - alphas: was raw byte/255; spec says it's quantized linear
    //     alpha so byte/255 IS correct (Niantic stores logit then
    //     applies sigmoid, but the round-trip cancels — see lines
    //     617-619 in their loader).
    //   - scales: was delta + decode_log_scale; should be ABSOLUTE
    //     `byte → byte/16 - 10` (log space).
    //   - rotations: v2 first-three pack was OK in spirit but layout
    //     wrong — the unsigned bias `(byte/127.5)-1` is right, but
    //     w should be reconstructed assuming non-negative and we
    //     should NOT re-normalize since the encoding already
    //     guarantees |q|=1.
    //
    // SPZ v2 stream order after the 16-byte header:
    //   positions  : n * 9 bytes  (3 components × 3 bytes each = 24-bit fixed)
    //   alphas     : n * 1 bytes  (uint8 linear opacity)
    //   colors     : n * 3 bytes  (uint8, SH DC quantized via colorScale=0.15)
    //   scales     : n * 3 bytes  (uint8, log_scale = byte/16 - 10)
    //   rotations  : n * 3 bytes  (v2 first-three packing, w = sqrt(1-|xyz|²))
    //                  (v3+ uses 4 bytes "smallest three" — out of scope)
    //   SH         : n * dim(sh_degree) * 3 bytes  (skipped here, sh_degree=0)
    //
    // Cross-checked field order against load-spz.cc Lines 870-900
    // (file deserialization order in deserializePackedGaussians).
    std::size_t pos_bytes = n * 9u;
    std::size_t alpha_bytes = n;
    std::size_t color_bytes = n * 3u;
    std::size_t scale_bytes = n * 3u;
    std::size_t rot_bytes = (header.version >= 3) ? n * 4u : n * 3u;
    // Phase 6.4f.4.a — SH stream sizing (Niantic load-spz.cc::dimForDegree).
    //   degree 0/1/2/3 → shDim 0/3/8/15 non-DC coefficients per channel.
    const std::uint32_t sh_dim =
        (header.sh_degree == 0u) ? 0u
      : (header.sh_degree == 1u) ? 3u
      : (header.sh_degree == 2u) ? 8u
      : (header.sh_degree == 3u) ? 15u
      : 24u;  // degree 4 — Niantic supports this, but our project_visible
              // shader maxes at degree 3, so we cap on read below.
    const std::size_t sh_bytes = static_cast<std::size_t>(n) * sh_dim * 3u;

    std::size_t min_size = sizeof(SpzHeader) + pos_bytes + alpha_bytes +
                           color_bytes + scale_bytes + rot_bytes + sh_bytes;

    if (size < min_size) {
        return core::Status::kInvalidArgument;
    }

    const std::uint8_t* ptr = data + sizeof(SpzHeader);
    result.gaussians.resize(n);

    // ── Positions: 24-bit signed fixed-point, ABSOLUTE (not delta) ────
    const float pos_scale = 1.0f / static_cast<float>(1u << header.fractional_bits);
    for (std::uint32_t i = 0; i < n; ++i) {
        for (int c = 0; c < 3; ++c) {
            std::int32_t val = static_cast<std::int32_t>(ptr[0]) |
                               (static_cast<std::int32_t>(ptr[1]) << 8) |
                               (static_cast<std::int32_t>(ptr[2]) << 16);
            // Sign-extend from 24 bits → 32 bits.
            if (val & 0x800000) val |= static_cast<std::int32_t>(0xFF000000u);
            ptr += 3;
            result.gaussians[i].position[c] = static_cast<float>(val) * pos_scale;
        }
    }

    // ── Alphas: uint8 → linear opacity in [0, 1] ──────────────────────
    // Niantic stores `invSigmoid(alpha) → quantized to uint8` and the
    // unpack does `sigmoid(byte/255)` to reverse; but that's because
    // their training pipeline carries logits. For viewing we want
    // linear alpha, which is byte/255 directly (the round-trip
    // sigmoid(invSigmoid(byte/255)) reduces to byte/255 ignoring
    // quantization noise). Save 786k sigmoid evaluations.
    for (std::uint32_t i = 0; i < n; ++i) {
        result.gaussians[i].opacity = static_cast<float>(*ptr) / 255.0f;
        ptr++;
    }

    // ── Colors: uint8 → SH DC coefficient ─────────────────────────────
    // GaussianParams.color stores the SH degree-0 coefficient (NOT a
    // linear RGB color). The shader (project_visible.wgsl) computes
    // `rgb = SH_C0 * dc + 0.5` to get displayable color.
    // Niantic's encoding: byte = round((dc * 0.15 + 0.5) * 255).
    // Decoding: dc = (byte/255 - 0.5) / 0.15 ∈ [-3.33, +3.33].
    constexpr float kColorScale = 0.15f;  // matches Niantic load-spz.cc
    for (std::uint32_t i = 0; i < n; ++i) {
        for (int c = 0; c < 3; ++c) {
            result.gaussians[i].color[c] =
                ((static_cast<float>(*ptr) / 255.0f) - 0.5f) / kColorScale;
            ptr++;
        }
    }

    // ── Scales: uint8 → log-scale (NOT linear) ────────────────────────
    // GaussianParams.scale layout matches PLY's scale_0..2 (log space).
    // The compute pipeline reads it as `log_scales` and applies exp()
    // when computing the splat's view-space covariance.
    // Niantic encoding: byte = round((log_scale + 10) * 16), so:
    //   log_scale = byte/16 - 10  ∈ [-10, +5.94]
    for (std::uint32_t i = 0; i < n; ++i) {
        for (int c = 0; c < 3; ++c) {
            result.gaussians[i].scale[c] =
                static_cast<float>(*ptr) / 16.0f - 10.0f;
            ptr++;
        }
    }

    // ── Rotations: v2 "first-three" packing → quaternion (w, x, y, z) ─
    // 3 bytes encode (x, y, z) as `(byte/127.5) - 1`, the encoding
    // guarantees |q|=1 and w >= 0, so we reconstruct w via sqrt and
    // skip re-normalization (the incoming data is already unit).
    // For v3+ the "smallest-three" packing uses 4 bytes — not yet
    // supported; we'd surface that as kInvalidArgument up front.
    if (header.version >= 3) {
        // v3 smallest-three quaternion packing not implemented; bail.
        // The user's hornedlizard.spz is v2, so this path doesn't fire
        // today but we make the limitation explicit.
        return core::Status::kFailedPrecondition;
    }
    for (std::uint32_t i = 0; i < n; ++i) {
        const float qx = (static_cast<float>(ptr[0]) / 127.5f) - 1.0f;
        const float qy = (static_cast<float>(ptr[1]) / 127.5f) - 1.0f;
        const float qz = (static_cast<float>(ptr[2]) / 127.5f) - 1.0f;
        ptr += 3;
        const float sq = qx * qx + qy * qy + qz * qz;
        const float qw = std::sqrt(std::max(0.0f, 1.0f - sq));
        // GaussianParams stores quaternion as (w, x, y, z).
        result.gaussians[i].rotation[0] = qw;
        result.gaussians[i].rotation[1] = qx;
        result.gaussians[i].rotation[2] = qy;
        result.gaussians[i].rotation[3] = qz;
    }

    // ── Phase 6.4f.4.a — Higher-order SH coefficients ─────────────────
    //
    // SPZ stream layout (matches Niantic load-spz.cc PackedGaussians::at):
    //   sh[i * (shDim * 3) + basis * 3 + 0/1/2] = (R, G, B) byte at basis
    //
    // Encoding per Niantic `unquantizeSH(byte) = (byte - 128)/128 ∈ [-1,1]`.
    //
    // Our project_visible shader expects the PLY-native channel-major
    // basis-major layout (matches PlyLoadResult::sh_rest):
    //   sh_rest[i * (3 * non_dc_basis) + channel * non_dc_basis + basis]
    // so we transpose on read. Cap to project_visible's max supported
    // degree (3) — degree-4 source files get their fourth band dropped
    // here at decode time rather than blowing through later validators.
    if (sh_dim > 0u) {
        const std::uint32_t loaded_basis = (sh_dim > 15u) ? 15u : sh_dim;
        if (loaded_basis < sh_dim) {
            // Source has degree 4; we cap to degree 3 for shader compat.
            result.sh_degree = 3u;
        }
        result.sh_rest.assign(static_cast<std::size_t>(n) * 3u * loaded_basis, 0.0f);
        for (std::uint32_t i = 0; i < n; ++i) {
            const std::size_t dst_splat_base =
                static_cast<std::size_t>(i) * 3u * loaded_basis;
            for (std::uint32_t b = 0; b < loaded_basis; ++b) {
                // Read one (R, G, B) triplet for basis `b`.
                const float r_val = (static_cast<float>(ptr[0]) - 128.0f) / 128.0f;
                const float g_val = (static_cast<float>(ptr[1]) - 128.0f) / 128.0f;
                const float b_val = (static_cast<float>(ptr[2]) - 128.0f) / 128.0f;
                ptr += 3;
                result.sh_rest[dst_splat_base + 0u * loaded_basis + b] = r_val;
                result.sh_rest[dst_splat_base + 1u * loaded_basis + b] = g_val;
                result.sh_rest[dst_splat_base + 2u * loaded_basis + b] = b_val;
            }
            // Skip any remaining basis bytes for source degrees > 3.
            if (loaded_basis < sh_dim) {
                ptr += static_cast<std::size_t>(sh_dim - loaded_basis) * 3u;
            }
        }
    }

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
