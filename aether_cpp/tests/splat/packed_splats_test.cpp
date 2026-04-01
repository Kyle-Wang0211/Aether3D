// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/splat/packed_splats.h"

#include <cmath>
#include <cstdio>
#include <cstring>
#include <utility>

static int g_failed = 0;

static void check(bool cond, const char* msg, int line) {
    if (!cond) {
        std::fprintf(stderr, "FAIL [line %d]: %s\n", line, msg);
        ++g_failed;
    }
}
#define CHECK(cond) check((cond), #cond, __LINE__)

static bool near(float a, float b, float eps = 1e-3f) {
    return std::fabs(a - b) <= eps;
}

using namespace aether::splat;

// ---------------------------------------------------------------------------
// sizeof static_assert sanity
// ---------------------------------------------------------------------------

static void test_struct_sizes() {
    CHECK(sizeof(PackedSplat) == 16);
    CHECK(sizeof(GaussianParams) == 92);  // 56 base + 36 (sh1[9] float array)
}

// ---------------------------------------------------------------------------
// Float16 roundtrip
// ---------------------------------------------------------------------------

static void test_float16_zero() {
    std::uint16_t h = float_to_half(0.0f);
    float back = half_to_float(h);
    CHECK(back == 0.0f);
}

static void test_float16_one() {
    std::uint16_t h = float_to_half(1.0f);
    float back = half_to_float(h);
    CHECK(back == 1.0f);
}

static void test_float16_negative() {
    std::uint16_t h = float_to_half(-3.5f);
    float back = half_to_float(h);
    CHECK(near(back, -3.5f, 0.01f));
}

static void test_float16_small_value() {
    // float16 subnormal range
    float small = 0.00006f;
    std::uint16_t h = float_to_half(small);
    float back = half_to_float(h);
    // Subnormals lose precision, but should be in the right ballpark
    CHECK(back >= 0.0f);
    CHECK(back < 0.001f);
}

static void test_float16_large_value() {
    // 65504 is max representable float16
    std::uint16_t h = float_to_half(65504.0f);
    float back = half_to_float(h);
    CHECK(near(back, 65504.0f, 1.0f));
}

static void test_float16_overflow() {
    // Beyond float16 range → infinity
    std::uint16_t h = float_to_half(100000.0f);
    float back = half_to_float(h);
    CHECK(std::isinf(back));
}

static void test_float16_typical_positions() {
    // Typical 3DGS position values
    float values[] = {-2.5f, 0.0f, 1.37f, -0.001f, 42.0f};
    for (float v : values) {
        std::uint16_t h = float_to_half(v);
        float back = half_to_float(h);
        float eps = std::fabs(v) * 0.002f + 0.001f;  // ~0.2% relative error
        CHECK(near(back, v, eps));
    }
}

// ---------------------------------------------------------------------------
// sRGB ↔ Linear roundtrip
// ---------------------------------------------------------------------------

static void test_srgb_black() {
    CHECK(linear_to_srgb_byte(0.0f) == 0);
    CHECK(near(srgb_byte_to_linear(0), 0.0f, 1e-6f));
}

static void test_srgb_white() {
    CHECK(linear_to_srgb_byte(1.0f) == 255);
    CHECK(near(srgb_byte_to_linear(255), 1.0f, 1e-3f));
}

static void test_srgb_roundtrip_midtones() {
    // For various linear values, check roundtrip fidelity (8-bit quantization)
    float test_values[] = {0.0f, 0.01f, 0.1f, 0.18f, 0.5f, 0.8f, 1.0f};
    for (float v : test_values) {
        std::uint8_t srgb = linear_to_srgb_byte(v);
        float back = srgb_byte_to_linear(srgb);
        // 8-bit quantization: expect ~1/255 ≈ 0.004 error in sRGB space,
        // which maps to larger error in linear near black
        CHECK(near(back, v, 0.02f));
    }
}

static void test_srgb_clamp() {
    CHECK(linear_to_srgb_byte(-1.0f) == 0);
    CHECK(linear_to_srgb_byte(2.0f) == 255);
}

// ---------------------------------------------------------------------------
// Log scale encode/decode roundtrip
// ---------------------------------------------------------------------------

static void test_log_scale_roundtrip() {
    float test_values[] = {0.001f, 0.01f, 0.1f, 1.0f, 10.0f, 100.0f};
    for (float v : test_values) {
        std::uint8_t encoded = encode_log_scale(v);
        float decoded = decode_log_scale(encoded);
        // 8-bit quantization in log space: relative error ~6%
        float ratio = decoded / v;
        CHECK(ratio > 0.85f && ratio < 1.18f);
    }
}

static void test_log_scale_zero() {
    std::uint8_t encoded = encode_log_scale(0.0f);
    CHECK(encoded == 0);
}

static void test_log_scale_negative() {
    std::uint8_t encoded = encode_log_scale(-1.0f);
    CHECK(encoded == 0);
}

static void test_log_scale_monotonic() {
    // Larger values should produce larger encoded bytes
    std::uint8_t e1 = encode_log_scale(0.01f);
    std::uint8_t e2 = encode_log_scale(0.1f);
    std::uint8_t e3 = encode_log_scale(1.0f);
    std::uint8_t e4 = encode_log_scale(10.0f);
    CHECK(e1 < e2);
    CHECK(e2 < e3);
    CHECK(e3 < e4);
}

// ---------------------------------------------------------------------------
// Quaternion encode/decode roundtrip
// ---------------------------------------------------------------------------

static float quat_dot(const float a[4], const float b[4]) {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3];
}

static void test_quaternion_identity() {
    float q_in[4] = {1.0f, 0.0f, 0.0f, 0.0f};
    std::uint8_t uv[2];
    std::uint8_t angle;
    encode_quaternion(q_in, uv, angle);

    float q_out[4];
    decode_quaternion(uv, angle, q_out);

    // Identity: w ≈ 1, xyz ≈ 0
    CHECK(near(q_out[0], 1.0f, 0.05f));
    CHECK(near(q_out[1], 0.0f, 0.05f));
    CHECK(near(q_out[2], 0.0f, 0.05f));
    CHECK(near(q_out[3], 0.0f, 0.05f));
}

static void test_quaternion_90deg_x() {
    // 90° rotation around X: q = (cos(45°), sin(45°), 0, 0)
    float c = std::cos(0.7853981f);
    float s = std::sin(0.7853981f);
    float q_in[4] = {c, s, 0.0f, 0.0f};

    std::uint8_t uv[2];
    std::uint8_t angle_byte;
    encode_quaternion(q_in, uv, angle_byte);

    float q_out[4];
    decode_quaternion(uv, angle_byte, q_out);

    // Check rotation equivalence via dot product (|dot| ≈ 1 means same rotation)
    float dot = std::fabs(quat_dot(q_in, q_out));
    CHECK(dot > 0.95f);
}

static void test_quaternion_arbitrary() {
    // Arbitrary rotation
    float q_in[4] = {0.5f, 0.5f, 0.5f, 0.5f};  // 120° around (1,1,1)

    std::uint8_t uv[2];
    std::uint8_t angle_byte;
    encode_quaternion(q_in, uv, angle_byte);

    float q_out[4];
    decode_quaternion(uv, angle_byte, q_out);

    float dot = std::fabs(quat_dot(q_in, q_out));
    CHECK(dot > 0.92f);  // 3-byte encoding has limited precision
}

static void test_quaternion_negative_w() {
    // Negative w → should be canonicalized to positive hemisphere
    float q_in[4] = {-0.707f, 0.707f, 0.0f, 0.0f};

    std::uint8_t uv[2];
    std::uint8_t angle_byte;
    encode_quaternion(q_in, uv, angle_byte);

    float q_out[4];
    decode_quaternion(uv, angle_byte, q_out);

    // Same rotation as (0.707, -0.707, 0, 0)
    float q_canonical[4] = {0.707f, -0.707f, 0.0f, 0.0f};
    float dot = std::fabs(quat_dot(q_canonical, q_out));
    CHECK(dot > 0.92f);
}

// ---------------------------------------------------------------------------
// Pack / Unpack roundtrip
// ---------------------------------------------------------------------------

static void test_pack_unpack_roundtrip() {
    GaussianParams original{};
    original.position[0] = 1.5f;
    original.position[1] = -0.3f;
    original.position[2] = 2.7f;
    original.color[0] = 0.8f;  // linear red
    original.color[1] = 0.2f;
    original.color[2] = 0.5f;
    original.opacity = 0.9f;
    original.scale[0] = 0.05f;
    original.scale[1] = 0.1f;
    original.scale[2] = 0.02f;
    original.rotation[0] = 1.0f;  // identity quaternion
    original.rotation[1] = 0.0f;
    original.rotation[2] = 0.0f;
    original.rotation[3] = 0.0f;

    PackedSplat packed = pack_gaussian(original);
    GaussianParams unpacked = unpack_gaussian(packed);

    // Position: float16 → ~0.1% relative error for small values
    CHECK(near(unpacked.position[0], original.position[0], 0.01f));
    CHECK(near(unpacked.position[1], original.position[1], 0.01f));
    CHECK(near(unpacked.position[2], original.position[2], 0.01f));

    // Color: sRGB 8-bit quantization → ~2% error
    CHECK(near(unpacked.color[0], original.color[0], 0.03f));
    CHECK(near(unpacked.color[1], original.color[1], 0.03f));
    CHECK(near(unpacked.color[2], original.color[2], 0.03f));

    // Opacity: 8-bit quantization → ~0.4% error
    CHECK(near(unpacked.opacity, original.opacity, 0.01f));

    // Scale: log 8-bit → ~6% relative error
    CHECK(unpacked.scale[0] / original.scale[0] > 0.85f);
    CHECK(unpacked.scale[0] / original.scale[0] < 1.18f);

    // Rotation: 3-byte encoding → limited precision
    float dot = std::fabs(quat_dot(unpacked.rotation, original.rotation));
    CHECK(dot > 0.95f);
}

static void test_pack_unpack_extreme_values() {
    GaussianParams original{};
    original.position[0] = 0.0f;
    original.position[1] = 0.0f;
    original.position[2] = 0.0f;
    original.color[0] = 0.0f;
    original.color[1] = 0.0f;
    original.color[2] = 0.0f;
    original.opacity = 0.0f;
    original.scale[0] = 0.001f;
    original.scale[1] = 0.001f;
    original.scale[2] = 0.001f;
    original.rotation[0] = 1.0f;
    original.rotation[1] = 0.0f;
    original.rotation[2] = 0.0f;
    original.rotation[3] = 0.0f;

    PackedSplat packed = pack_gaussian(original);
    GaussianParams unpacked = unpack_gaussian(packed);

    CHECK(unpacked.position[0] == 0.0f);
    CHECK(unpacked.position[1] == 0.0f);
    CHECK(unpacked.position[2] == 0.0f);
    CHECK(unpacked.opacity < 0.01f);
}

// ---------------------------------------------------------------------------
// PackedSplatsBuffer
// ---------------------------------------------------------------------------

static void test_buffer_push() {
    PackedSplatsBuffer buf;
    CHECK(buf.empty());
    CHECK(buf.size() == 0);

    PackedSplat s{};
    s.rgba[0] = 255;
    buf.push(s);

    CHECK(!buf.empty());
    CHECK(buf.size() == 1);
    CHECK(buf.data()[0].rgba[0] == 255);
}

static void test_buffer_push_batch() {
    PackedSplatsBuffer buf;

    GaussianParams params[3] = {};
    params[0].position[0] = 1.0f;
    params[0].rotation[0] = 1.0f;
    params[0].scale[0] = params[0].scale[1] = params[0].scale[2] = 0.1f;
    params[1].position[0] = 2.0f;
    params[1].rotation[0] = 1.0f;
    params[1].scale[0] = params[1].scale[1] = params[1].scale[2] = 0.1f;
    params[2].position[0] = 3.0f;
    params[2].rotation[0] = 1.0f;
    params[2].scale[0] = params[2].scale[1] = params[2].scale[2] = 0.1f;

    buf.push_batch(params, 3);
    CHECK(buf.size() == 3);
    CHECK(buf.size_bytes() == 3 * 16);
}

static void test_buffer_clear() {
    PackedSplatsBuffer buf;
    PackedSplat s{};
    buf.push(s);
    buf.push(s);
    CHECK(buf.size() == 2);

    buf.clear();
    CHECK(buf.empty());
    CHECK(buf.size() == 0);
    // Capacity should still be allocated
    CHECK(buf.capacity() > 0);
}

static void test_buffer_grow() {
    PackedSplatsBuffer buf(4);
    CHECK(buf.capacity() >= 4);

    PackedSplat s{};
    for (int i = 0; i < 100; ++i) {
        buf.push(s);
    }
    CHECK(buf.size() == 100);
    CHECK(buf.capacity() >= 100);
}

static void test_buffer_move() {
    PackedSplatsBuffer buf1;
    PackedSplat s{};
    s.rgba[0] = 42;
    buf1.push(s);

    PackedSplatsBuffer buf2(std::move(buf1));
    CHECK(buf2.size() == 1);
    CHECK(buf2.data()[0].rgba[0] == 42);
    CHECK(buf1.size() == 0);
    CHECK(buf1.data() == nullptr);
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

int main() {
    test_struct_sizes();

    test_float16_zero();
    test_float16_one();
    test_float16_negative();
    test_float16_small_value();
    test_float16_large_value();
    test_float16_overflow();
    test_float16_typical_positions();

    test_srgb_black();
    test_srgb_white();
    test_srgb_roundtrip_midtones();
    test_srgb_clamp();

    test_log_scale_roundtrip();
    test_log_scale_zero();
    test_log_scale_negative();
    test_log_scale_monotonic();

    test_quaternion_identity();
    test_quaternion_90deg_x();
    test_quaternion_arbitrary();
    test_quaternion_negative_w();

    test_pack_unpack_roundtrip();
    test_pack_unpack_extreme_values();

    test_buffer_push();
    test_buffer_push_batch();
    test_buffer_clear();
    test_buffer_grow();
    test_buffer_move();

    if (g_failed == 0) {
        std::fprintf(stdout, "packed_splats_test: all tests passed\n");
    }
    return g_failed;
}
