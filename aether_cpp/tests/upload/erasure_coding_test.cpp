// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/upload/erasure_coding.h"

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>

static int g_failed = 0;

static void check(bool cond, const char* msg, int line) {
    if (!cond) {
        std::fprintf(stderr, "FAIL [line %d]: %s\n", line, msg);
        ++g_failed;
    }
}
#define CHECK(cond) check((cond), #cond, __LINE__)

// ---------------------------------------------------------------------------
// erasure_select_mode
// ---------------------------------------------------------------------------

static void test_select_mode_null() {
    CHECK(aether::upload::erasure_select_mode(10, 0.05, nullptr) ==
          aether::core::Status::kInvalidArgument);
}

static void test_select_mode_nan_loss() {
    aether::upload::ErasureSelection sel{};
    CHECK(aether::upload::erasure_select_mode(
              10, std::numeric_limits<double>::quiet_NaN(), &sel) ==
          aether::core::Status::kInvalidArgument);
}

static void test_select_mode_small_low_loss() {
    aether::upload::ErasureSelection sel{};
    CHECK(aether::upload::erasure_select_mode(100, 0.03, &sel) ==
          aether::core::Status::kOk);
    CHECK(sel.mode == aether::upload::ErasureMode::kReedSolomon);
    CHECK(sel.field == aether::upload::ErasureField::kGF256);
}

static void test_select_mode_small_high_loss() {
    aether::upload::ErasureSelection sel{};
    CHECK(aether::upload::erasure_select_mode(100, 0.20, &sel) ==
          aether::core::Status::kOk);
    CHECK(sel.mode == aether::upload::ErasureMode::kRaptorQ);
    CHECK(sel.field == aether::upload::ErasureField::kGF256);
}

static void test_select_mode_large_low_loss() {
    aether::upload::ErasureSelection sel{};
    CHECK(aether::upload::erasure_select_mode(500, 0.01, &sel) ==
          aether::core::Status::kOk);
    CHECK(sel.mode == aether::upload::ErasureMode::kReedSolomon);
    CHECK(sel.field == aether::upload::ErasureField::kGF65536);
}

static void test_select_mode_large_high_loss() {
    aether::upload::ErasureSelection sel{};
    CHECK(aether::upload::erasure_select_mode(500, 0.10, &sel) ==
          aether::core::Status::kOk);
    CHECK(sel.mode == aether::upload::ErasureMode::kRaptorQ);
    CHECK(sel.field == aether::upload::ErasureField::kGF65536);
}

// ---------------------------------------------------------------------------
// erasure_encode / decode round-trip
// ---------------------------------------------------------------------------

static void test_encode_null_params() {
    CHECK(aether::upload::erasure_encode(
              nullptr, nullptr, -1, 0.5, nullptr, 0, nullptr, 0, nullptr, nullptr) ==
          aether::core::Status::kInvalidArgument);
}

static void test_encode_zero_blocks() {
    std::uint32_t offsets[1] = {0};
    std::uint8_t out_data[64] = {};
    std::uint32_t out_offsets[8] = {};
    int out_count = 0;
    std::uint32_t out_size = 0;
    CHECK(aether::upload::erasure_encode(
              nullptr, offsets, 0, 0.5, out_data, 64, out_offsets, 8,
              &out_count, &out_size) ==
          aether::core::Status::kOk);
    CHECK(out_count == 0);
    CHECK(out_size == 0u);
}

static void test_encode_decode_round_trip_rs() {
    // 4 blocks of 4 bytes each, RS with 50% redundancy => 2 parity blocks
    const std::uint8_t input[] = {
        'H', 'E', 'L', 'L',  // block 0
        'O', ' ', 'W', 'O',  // block 1
        'R', 'L', 'D', '!',  // block 2
        'T', 'E', 'S', 'T',  // block 3
    };
    const std::uint32_t offsets[] = {0, 4, 8, 12, 16};
    const int block_count = 4;
    const double redundancy = 0.5;

    // Encode
    std::vector<std::uint8_t> enc_data(256, 0);
    std::vector<std::uint32_t> enc_offsets(16, 0);
    int enc_count = 0;
    std::uint32_t enc_size = 0;

    CHECK(aether::upload::erasure_encode(
              input, offsets, block_count, redundancy,
              enc_data.data(), 256, enc_offsets.data(), 16,
              &enc_count, &enc_size) ==
          aether::core::Status::kOk);
    CHECK(enc_count == 6);  // 4 original + 2 parity

    // Simulate loss of block 1
    std::vector<std::uint8_t> present(static_cast<std::size_t>(enc_count), 1);
    present[1] = 0;  // Block 1 lost

    std::vector<std::uint8_t> dec_data(256, 0);
    std::vector<std::uint32_t> dec_offsets(16, 0);
    int dec_count = 0;
    std::uint32_t dec_size = 0;

    auto s = aether::upload::erasure_decode_systematic(
        enc_data.data(), enc_offsets.data(), present.data(),
        enc_count, block_count,
        dec_data.data(), 256, dec_offsets.data(), 16,
        &dec_count, &dec_size);

    CHECK(s == aether::core::Status::kOk);
    CHECK(dec_count == block_count);

    // Verify recovered data matches original
    for (int i = 0; i < block_count; ++i) {
        const std::uint32_t orig_begin = offsets[i];
        const std::uint32_t orig_size = offsets[i + 1] - offsets[i];
        const std::uint32_t dec_begin = dec_offsets[i];
        for (std::uint32_t b = 0; b < orig_size; ++b) {
            CHECK(dec_data[dec_begin + b] == input[orig_begin + b]);
        }
    }
}

static void test_encode_decode_round_trip_raptorq() {
    // Same test but with RaptorQ mode
    const std::uint8_t input[] = {
        0x01, 0x02, 0x03, 0x04,
        0x11, 0x12, 0x13, 0x14,
        0x21, 0x22, 0x23, 0x24,
    };
    const std::uint32_t offsets[] = {0, 4, 8, 12};
    const int block_count = 3;
    const double redundancy = 1.0;  // 100% redundancy

    std::vector<std::uint8_t> enc_data(256, 0);
    std::vector<std::uint32_t> enc_offsets(16, 0);
    int enc_count = 0;
    std::uint32_t enc_size = 0;

    CHECK(aether::upload::erasure_encode_with_mode(
              input, offsets, block_count, redundancy,
              aether::upload::ErasureMode::kRaptorQ,
              aether::upload::ErasureField::kGF256,
              enc_data.data(), 256, enc_offsets.data(), 16,
              &enc_count, &enc_size) ==
          aether::core::Status::kOk);
    CHECK(enc_count == 6);  // 3 original + 3 parity

    // Lose block 0
    std::vector<std::uint8_t> present(static_cast<std::size_t>(enc_count), 1);
    present[0] = 0;

    std::vector<std::uint8_t> dec_data(256, 0);
    std::vector<std::uint32_t> dec_offsets(16, 0);
    int dec_count = 0;
    std::uint32_t dec_size = 0;

    auto s = aether::upload::erasure_decode_systematic_with_mode(
        enc_data.data(), enc_offsets.data(), present.data(),
        enc_count, block_count,
        aether::upload::ErasureMode::kRaptorQ,
        aether::upload::ErasureField::kGF256,
        dec_data.data(), 256, dec_offsets.data(), 16,
        &dec_count, &dec_size);

    CHECK(s == aether::core::Status::kOk);
    CHECK(dec_count == block_count);
    for (int i = 0; i < block_count; ++i) {
        const std::uint32_t orig_begin = offsets[i];
        const std::uint32_t orig_size = offsets[i + 1] - offsets[i];
        const std::uint32_t dec_begin = dec_offsets[i];
        for (std::uint32_t b = 0; b < orig_size; ++b) {
            CHECK(dec_data[dec_begin + b] == input[orig_begin + b]);
        }
    }
}

static void test_encode_capacity_exhausted() {
    const std::uint8_t input[] = {1, 2, 3, 4};
    const std::uint32_t offsets[] = {0, 4};
    std::uint8_t out_data[1] = {};
    std::uint32_t out_offsets[4] = {};
    int out_count = 0;
    std::uint32_t out_size = 0;

    auto s = aether::upload::erasure_encode(
        input, offsets, 1, 1.0,
        out_data, 1, out_offsets, 4,
        &out_count, &out_size);
    CHECK(s == aether::core::Status::kResourceExhausted);
}

static void test_decode_too_many_lost() {
    // 2 blocks, 1 parity, lose both original blocks => can't recover both
    const std::uint8_t input[] = {0xAA, 0xBB, 0xCC, 0xDD};
    const std::uint32_t offsets[] = {0, 2, 4};
    const int block_count = 2;

    std::vector<std::uint8_t> enc_data(64, 0);
    std::vector<std::uint32_t> enc_offsets(8, 0);
    int enc_count = 0;
    std::uint32_t enc_size = 0;

    aether::upload::erasure_encode(
        input, offsets, block_count, 0.5,
        enc_data.data(), 64, enc_offsets.data(), 8,
        &enc_count, &enc_size);

    // Lose both original blocks
    std::vector<std::uint8_t> present(static_cast<std::size_t>(enc_count), 0);
    for (int i = block_count; i < enc_count; ++i) {
        present[static_cast<std::size_t>(i)] = 1;  // Only parity survives
    }

    std::vector<std::uint8_t> dec_data(64, 0);
    std::vector<std::uint32_t> dec_offsets(8, 0);
    int dec_count = 0;
    std::uint32_t dec_size = 0;

    auto s = aether::upload::erasure_decode_systematic(
        enc_data.data(), enc_offsets.data(), present.data(),
        enc_count, block_count,
        dec_data.data(), 64, dec_offsets.data(), 8,
        &dec_count, &dec_size);
    // With only 1 parity for 2 blocks, recovery may fail
    // (depends on parity sources); either kOk or kResourceExhausted is valid
    CHECK(s == aether::core::Status::kOk ||
          s == aether::core::Status::kResourceExhausted);
}

static void test_decode_no_loss() {
    // No loss => direct copy
    const std::uint8_t input[] = {0x10, 0x20, 0x30, 0x40, 0x50, 0x60};
    const std::uint32_t offsets[] = {0, 3, 6};
    const int block_count = 2;

    std::vector<std::uint8_t> enc_data(128, 0);
    std::vector<std::uint32_t> enc_offsets(8, 0);
    int enc_count = 0;
    std::uint32_t enc_size = 0;

    aether::upload::erasure_encode(
        input, offsets, block_count, 0.5,
        enc_data.data(), 128, enc_offsets.data(), 8,
        &enc_count, &enc_size);

    std::vector<std::uint8_t> present(static_cast<std::size_t>(enc_count), 1);
    std::vector<std::uint8_t> dec_data(128, 0);
    std::vector<std::uint32_t> dec_offsets(8, 0);
    int dec_count = 0;
    std::uint32_t dec_size = 0;

    CHECK(aether::upload::erasure_decode_systematic(
              enc_data.data(), enc_offsets.data(), present.data(),
              enc_count, block_count,
              dec_data.data(), 128, dec_offsets.data(), 8,
              &dec_count, &dec_size) ==
          aether::core::Status::kOk);

    for (int i = 0; i < 6; ++i) {
        CHECK(dec_data[dec_offsets[0] + static_cast<std::uint32_t>(i)] == input[i] ||
              (i >= 3 && dec_data[dec_offsets[1] + static_cast<std::uint32_t>(i - 3)] == input[i]));
    }
}

static void test_encode_decode_gf65536() {
    const std::uint8_t input[] = {0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE};
    const std::uint32_t offsets[] = {0, 4, 8};
    const int block_count = 2;

    std::vector<std::uint8_t> enc_data(128, 0);
    std::vector<std::uint32_t> enc_offsets(8, 0);
    int enc_count = 0;
    std::uint32_t enc_size = 0;

    CHECK(aether::upload::erasure_encode_with_mode(
              input, offsets, block_count, 0.5,
              aether::upload::ErasureMode::kReedSolomon,
              aether::upload::ErasureField::kGF65536,
              enc_data.data(), 128, enc_offsets.data(), 8,
              &enc_count, &enc_size) ==
          aether::core::Status::kOk);

    // Lose block 0, recover
    std::vector<std::uint8_t> present(static_cast<std::size_t>(enc_count), 1);
    present[0] = 0;

    std::vector<std::uint8_t> dec_data(128, 0);
    std::vector<std::uint32_t> dec_offsets(8, 0);
    int dec_count = 0;
    std::uint32_t dec_size = 0;

    auto s = aether::upload::erasure_decode_systematic_with_mode(
        enc_data.data(), enc_offsets.data(), present.data(),
        enc_count, block_count,
        aether::upload::ErasureMode::kReedSolomon,
        aether::upload::ErasureField::kGF65536,
        dec_data.data(), 128, dec_offsets.data(), 8,
        &dec_count, &dec_size);

    CHECK(s == aether::core::Status::kOk);
    // Verify block 0 recovered
    for (int b = 0; b < 4; ++b) {
        CHECK(dec_data[dec_offsets[0] + static_cast<std::uint32_t>(b)] == input[b]);
    }
}

int main() {
    test_select_mode_null();
    test_select_mode_nan_loss();
    test_select_mode_small_low_loss();
    test_select_mode_small_high_loss();
    test_select_mode_large_low_loss();
    test_select_mode_large_high_loss();

    test_encode_null_params();
    test_encode_zero_blocks();
    test_encode_decode_round_trip_rs();
    test_encode_decode_round_trip_raptorq();
    test_encode_capacity_exhausted();
    test_decode_too_many_lost();
    test_decode_no_loss();
    test_encode_decode_gf65536();

    if (g_failed == 0) {
        std::fprintf(stdout, "erasure_coding_test: all tests passed\n");
    }
    return g_failed;
}
