// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_CPP_SPLAT_PACKED_SPLATS_H
#define AETHER_CPP_SPLAT_PACKED_SPLATS_H

#ifdef __cplusplus

#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <new>

namespace aether {
namespace splat {

// ═══════════════════════════════════════════════════════════════════════
// PackedSplat: 16-byte compact Gaussian representation
// ═══════════════════════════════════════════════════════════════════════
// Encoding scheme derived from Spark (World Labs, MIT):
//   - RGBA:       4 bytes — sRGB color + linear opacity
//   - Center:     6 bytes — float16 xyz position
//   - Rotation:   3 bytes — octahedral-encoded quaternion (axis_uv + angle)
//   - Scale:      3 bytes — log-encoded xyz scale
//
// Total: 16 bytes per Gaussian (vs 56 bytes uncompressed)

struct PackedSplat {
    std::uint8_t rgba[4];         // sRGB color (rgb) + linear opacity (a)
    std::uint16_t center[3];      // float16-encoded xyz position
    std::uint8_t quat_uv[2];     // octahedral-encoded rotation axis
    std::uint8_t log_scale[3];   // log-encoded xyz scale
    std::uint8_t quat_angle;     // quantized rotation angle [0, pi]
};

static_assert(sizeof(PackedSplat) == 16, "PackedSplat must be exactly 16 bytes");

// ═══════════════════════════════════════════════════════════════════════
// GaussianParams: Uncompressed intermediate format (training output)
// ═══════════════════════════════════════════════════════════════════════
// Full-precision representation used during training and for CPU-side
// manipulation. Packed down to PackedSplat for GPU rendering.

struct GaussianParams {
    float position[3];    // world-space xyz
    float color[3];       // linear RGB [0,1] = SH band 0 (DC)
    float opacity;        // linear opacity [0,1]
    float scale[3];       // xyz scale (positive)
    float rotation[4];    // quaternion (w, x, y, z), normalized
    float sh1[9];         // SH degree-1 coefficients: 3 RGB channels × 3 basis (per-channel)
                          // Layout matches PLY f_rest_0..8 (standard 3DGS per-channel order):
                          //   [R_b0, R_b1, R_b2,  G_b0, G_b1, G_b2,  B_b0, B_b1, B_b2]
                          // where b0=Y_1^{-1}, b1=Y_1^{0}, b2=Y_1^{+1}
                          // Zeroed for DC-only data (PLY files without f_rest_*)
};

static_assert(sizeof(GaussianParams) == 92, "GaussianParams must be 92 bytes");

// ─── Float16 Encoding/Decoding ─────────────────────────────────────

/// Encode a 32-bit float to 16-bit half-float (IEEE 754-2008).
inline std::uint16_t float_to_half(float value) noexcept {
    std::uint32_t bits;
    std::memcpy(&bits, &value, sizeof(bits));

    std::uint32_t sign = (bits >> 16) & 0x8000;
    std::int32_t  exponent = static_cast<std::int32_t>((bits >> 23) & 0xFF) - 127 + 15;
    std::uint32_t mantissa = bits & 0x007FFFFF;

    if (exponent <= 0) {
        // Subnormal or zero
        if (exponent < -10) return static_cast<std::uint16_t>(sign);
        mantissa |= 0x00800000;
        std::uint32_t shift = static_cast<std::uint32_t>(1 - exponent);
        mantissa >>= shift;
        return static_cast<std::uint16_t>(sign | (mantissa >> 13));
    }
    if (exponent >= 31) {
        // Overflow → infinity
        return static_cast<std::uint16_t>(sign | 0x7C00);
    }
    return static_cast<std::uint16_t>(sign |
        (static_cast<std::uint32_t>(exponent) << 10) |
        (mantissa >> 13));
}

/// Decode a 16-bit half-float to 32-bit float.
inline float half_to_float(std::uint16_t h) noexcept {
    std::uint32_t sign = static_cast<std::uint32_t>(h & 0x8000) << 16;
    std::uint32_t exponent = (h >> 10) & 0x1F;
    std::uint32_t mantissa = h & 0x03FF;

    if (exponent == 0) {
        if (mantissa == 0) {
            // Zero
            float result;
            std::memcpy(&result, &sign, sizeof(result));
            return result;
        }
        // Subnormal
        while (!(mantissa & 0x0400)) {
            mantissa <<= 1;
            exponent--;
        }
        exponent++;
        mantissa &= ~0x0400u;
    } else if (exponent == 31) {
        // Inf/NaN
        std::uint32_t bits = sign | 0x7F800000 | (mantissa << 13);
        float result;
        std::memcpy(&result, &bits, sizeof(result));
        return result;
    }

    std::uint32_t bits = sign |
        ((exponent + 127 - 15) << 23) |
        (mantissa << 13);
    float result;
    std::memcpy(&result, &bits, sizeof(result));
    return result;
}

// ─── sRGB ↔ Linear Conversion ──────────────────────────────────────

/// Linear [0,1] → sRGB [0,255].
inline std::uint8_t linear_to_srgb_byte(float linear) noexcept {
    if (linear <= 0.0f) return 0;
    if (linear >= 1.0f) return 255;
    float srgb = (linear <= 0.0031308f)
        ? linear * 12.92f
        : 1.055f * std::pow(linear, 1.0f / 2.4f) - 0.055f;
    return static_cast<std::uint8_t>(srgb * 255.0f + 0.5f);
}

/// sRGB [0,255] → Linear [0,1].
inline float srgb_byte_to_linear(std::uint8_t srgb) noexcept {
    float s = static_cast<float>(srgb) / 255.0f;
    return (s <= 0.04045f)
        ? s / 12.92f
        : std::pow((s + 0.055f) / 1.055f, 2.4f);
}

// ─── Octahedral Quaternion Encoding ─────────────────────────────────
// Encode unit quaternion as (octahedral_uv[2], angle[1]) = 3 bytes.
// The rotation axis is stored in octahedral map, the half-angle in 1 byte.

/// Encode quaternion (w,x,y,z) → (quat_uv[2], quat_angle).
inline void encode_quaternion(const float q[4],
                               std::uint8_t uv[2],
                               std::uint8_t& angle) noexcept {
    // q = (w, x, y, z)
    float w = q[0], x = q[1], y = q[2], z = q[3];

    // Ensure w >= 0 (canonical hemisphere)
    if (w < 0.0f) { w = -w; x = -x; y = -y; z = -z; }

    // Half-angle: theta = acos(w), range [0, pi/2]
    float theta = std::acos(w < 1.0f ? w : 1.0f);
    angle = static_cast<std::uint8_t>(theta * (255.0f / 1.5707963f) + 0.5f);

    // Axis from imaginary part
    float axis_len = std::sqrt(x * x + y * y + z * z);
    if (axis_len < 1e-8f) {
        // Identity rotation — axis doesn't matter
        uv[0] = 128;
        uv[1] = 128;
        return;
    }
    float inv_len = 1.0f / axis_len;
    float ax = x * inv_len;
    float ay = y * inv_len;
    float az = z * inv_len;

    // Octahedral encoding of unit vector (ax, ay, az)
    float abs_sum = std::fabs(ax) + std::fabs(ay) + std::fabs(az);
    float ox = ax / abs_sum;
    float oy = ay / abs_sum;

    if (az < 0.0f) {
        float tmp_ox = (1.0f - std::fabs(oy)) * (ox >= 0.0f ? 1.0f : -1.0f);
        float tmp_oy = (1.0f - std::fabs(ox)) * (oy >= 0.0f ? 1.0f : -1.0f);
        ox = tmp_ox;
        oy = tmp_oy;
    }

    // Map [-1,1] → [0,255]
    uv[0] = static_cast<std::uint8_t>((ox * 0.5f + 0.5f) * 255.0f + 0.5f);
    uv[1] = static_cast<std::uint8_t>((oy * 0.5f + 0.5f) * 255.0f + 0.5f);
}

/// Decode (quat_uv[2], quat_angle) → quaternion (w,x,y,z).
inline void decode_quaternion(const std::uint8_t uv[2],
                               std::uint8_t angle,
                               float q[4]) noexcept {
    // Octahedral decode
    float ox = static_cast<float>(uv[0]) / 255.0f * 2.0f - 1.0f;
    float oy = static_cast<float>(uv[1]) / 255.0f * 2.0f - 1.0f;

    float az = 1.0f - std::fabs(ox) - std::fabs(oy);
    float ax, ay;
    if (az >= 0.0f) {
        ax = ox;
        ay = oy;
    } else {
        ax = (1.0f - std::fabs(oy)) * (ox >= 0.0f ? 1.0f : -1.0f);
        ay = (1.0f - std::fabs(ox)) * (oy >= 0.0f ? 1.0f : -1.0f);
    }

    // Normalize axis
    float len = std::sqrt(ax * ax + ay * ay + az * az);
    if (len < 1e-8f) {
        q[0] = 1.0f; q[1] = 0.0f; q[2] = 0.0f; q[3] = 0.0f;
        return;
    }
    float inv = 1.0f / len;
    ax *= inv; ay *= inv; az *= inv;

    // Reconstruct quaternion from axis-angle
    float theta = static_cast<float>(angle) * (1.5707963f / 255.0f);
    float sin_theta = std::sin(theta);
    q[0] = std::cos(theta);  // w
    q[1] = ax * sin_theta;   // x
    q[2] = ay * sin_theta;   // y
    q[3] = az * sin_theta;   // z
}

// ─── Log Scale Encoding ─────────────────────────────────────────────

/// Encode positive scale → log-encoded byte [0,255].
/// Maps scale range [exp(-8), exp(8)] to [0, 255].
inline std::uint8_t encode_log_scale(float scale) noexcept {
    if (scale <= 0.0f) return 0;
    float log_val = std::log(scale);
    // Clamp to [-8, 8] then map to [0, 255]
    float normalized = (log_val + 8.0f) / 16.0f;
    if (normalized <= 0.0f) return 0;
    if (normalized >= 1.0f) return 255;
    return static_cast<std::uint8_t>(normalized * 255.0f + 0.5f);
}

/// Decode log-encoded byte → positive scale.
inline float decode_log_scale(std::uint8_t encoded) noexcept {
    float normalized = static_cast<float>(encoded) / 255.0f;
    float log_val = normalized * 16.0f - 8.0f;
    return std::exp(log_val);
}

// ─── Pack / Unpack ──────────────────────────────────────────────────

/// Pack a full-precision GaussianParams into a 16-byte PackedSplat.
inline PackedSplat pack_gaussian(const GaussianParams& params) noexcept {
    PackedSplat packed{};

    // Color: linear → sRGB bytes
    packed.rgba[0] = linear_to_srgb_byte(params.color[0]);
    packed.rgba[1] = linear_to_srgb_byte(params.color[1]);
    packed.rgba[2] = linear_to_srgb_byte(params.color[2]);

    // Opacity: linear → byte
    float opacity_clamped = params.opacity < 0.0f ? 0.0f :
                            params.opacity > 1.0f ? 1.0f : params.opacity;
    packed.rgba[3] = static_cast<std::uint8_t>(opacity_clamped * 255.0f + 0.5f);

    // Position: float → float16
    packed.center[0] = float_to_half(params.position[0]);
    packed.center[1] = float_to_half(params.position[1]);
    packed.center[2] = float_to_half(params.position[2]);

    // Rotation: quaternion → octahedral + angle
    encode_quaternion(params.rotation, packed.quat_uv, packed.quat_angle);

    // Scale: positive float → log byte
    packed.log_scale[0] = encode_log_scale(params.scale[0]);
    packed.log_scale[1] = encode_log_scale(params.scale[1]);
    packed.log_scale[2] = encode_log_scale(params.scale[2]);

    return packed;
}

/// Unpack a 16-byte PackedSplat into full-precision GaussianParams.
inline GaussianParams unpack_gaussian(const PackedSplat& packed) noexcept {
    GaussianParams params{};

    // Color: sRGB → linear
    params.color[0] = srgb_byte_to_linear(packed.rgba[0]);
    params.color[1] = srgb_byte_to_linear(packed.rgba[1]);
    params.color[2] = srgb_byte_to_linear(packed.rgba[2]);

    // Opacity: byte → linear
    params.opacity = static_cast<float>(packed.rgba[3]) / 255.0f;

    // Position: float16 → float
    params.position[0] = half_to_float(packed.center[0]);
    params.position[1] = half_to_float(packed.center[1]);
    params.position[2] = half_to_float(packed.center[2]);

    // Rotation: octahedral + angle → quaternion
    decode_quaternion(packed.quat_uv, packed.quat_angle, params.rotation);

    // Scale: log byte → positive float
    params.scale[0] = decode_log_scale(packed.log_scale[0]);
    params.scale[1] = decode_log_scale(packed.log_scale[1]);
    params.scale[2] = decode_log_scale(packed.log_scale[2]);

    return params;
}

// ═══════════════════════════════════════════════════════════════════════
// PackedSplatsBuffer: Dynamic array with incremental push support
// ═══════════════════════════════════════════════════════════════════════
// Modeled after Spark's pushSplat() API for incremental rendering.

class PackedSplatsBuffer {
public:
    PackedSplatsBuffer() noexcept = default;

    explicit PackedSplatsBuffer(std::size_t initial_capacity) noexcept
        : data_(nullptr), size_(0), capacity_(0) {
        reserve(initial_capacity);
    }

    ~PackedSplatsBuffer() noexcept { delete[] data_; }

    // Non-copyable
    PackedSplatsBuffer(const PackedSplatsBuffer&) = delete;
    PackedSplatsBuffer& operator=(const PackedSplatsBuffer&) = delete;

    // Movable
    PackedSplatsBuffer(PackedSplatsBuffer&& other) noexcept
        : data_(other.data_), size_(other.size_), capacity_(other.capacity_) {
        other.data_ = nullptr;
        other.size_ = 0;
        other.capacity_ = 0;
    }

    PackedSplatsBuffer& operator=(PackedSplatsBuffer&& other) noexcept {
        if (this != &other) {
            delete[] data_;
            data_ = other.data_;
            size_ = other.size_;
            capacity_ = other.capacity_;
            other.data_ = nullptr;
            other.size_ = 0;
            other.capacity_ = 0;
        }
        return *this;
    }

    /// Push a single packed splat (incremental add).
    void push(const PackedSplat& splat) noexcept {
        if (size_ >= capacity_) {
            reserve(capacity_ == 0 ? 1024 : capacity_ * 2);
        }
        data_[size_++] = splat;
    }

    /// Push a batch of GaussianParams (pack + add).
    void push_batch(const GaussianParams* params, std::size_t count) noexcept {
        if (size_ + count > capacity_) {
            std::size_t new_cap = capacity_ == 0 ? 1024 : capacity_;
            while (new_cap < size_ + count) new_cap *= 2;
            reserve(new_cap);
            // Safety: if reserve() failed (OOM), capacity_ is unchanged.
            // Do NOT write past buffer — silently drop instead of SIGABRT.
            if (size_ + count > capacity_) return;
        }
        for (std::size_t i = 0; i < count; ++i) {
            data_[size_++] = pack_gaussian(params[i]);
        }
    }

    void clear() noexcept { size_ = 0; }

    void reserve(std::size_t new_capacity) noexcept {
        if (new_capacity <= capacity_) return;
        auto* new_data = new (std::nothrow) PackedSplat[new_capacity];
        if (!new_data) return;
        if (data_ && size_ > 0) {
            std::memcpy(new_data, data_, size_ * sizeof(PackedSplat));
        }
        delete[] data_;
        data_ = new_data;
        capacity_ = new_capacity;
    }

    const PackedSplat* data() const noexcept { return data_; }
    std::size_t size() const noexcept { return size_; }
    std::size_t capacity() const noexcept { return capacity_; }
    std::size_t size_bytes() const noexcept { return size_ * sizeof(PackedSplat); }
    bool empty() const noexcept { return size_ == 0; }

private:
    PackedSplat* data_{nullptr};
    std::size_t size_{0};
    std::size_t capacity_{0};
};

}  // namespace splat
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_CPP_SPLAT_PACKED_SPLATS_H
