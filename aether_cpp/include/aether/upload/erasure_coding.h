// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_UPLOAD_ERASURE_CODING_H
#define AETHER_UPLOAD_ERASURE_CODING_H

#ifdef __cplusplus

#include "aether/core/status.h"

#include <cstdint>

namespace aether {
namespace upload {

enum class ErasureMode : std::int32_t {
    kReedSolomon = 0,
    kRaptorQ = 1,
};

enum class ErasureField : std::int32_t {
    kGF256 = 0,
    kGF65536 = 1,
};

struct ErasureSelection {
    ErasureMode mode{ErasureMode::kReedSolomon};
    ErasureField field{ErasureField::kGF256};
};

core::Status erasure_select_mode(
    int chunk_count,
    double loss_rate,
    ErasureSelection* out_selection);

core::Status erasure_encode(
    const std::uint8_t* input_data,
    const std::uint32_t* input_offsets,
    int block_count,
    double redundancy,
    std::uint8_t* out_data,
    std::uint32_t out_data_capacity,
    std::uint32_t* out_offsets,
    int out_block_capacity,
    int* out_block_count,
    std::uint32_t* out_data_size);

core::Status erasure_encode_with_mode(
    const std::uint8_t* input_data,
    const std::uint32_t* input_offsets,
    int block_count,
    double redundancy,
    ErasureMode mode,
    ErasureField field,
    std::uint8_t* out_data,
    std::uint32_t out_data_capacity,
    std::uint32_t* out_offsets,
    int out_block_capacity,
    int* out_block_count,
    std::uint32_t* out_data_size);

core::Status erasure_encode_with_mode(
    const std::uint8_t* input_data,
    const std::uint32_t* input_offsets,
    int block_count,
    double redundancy,
    ErasureMode mode,
    ErasureField field,
    std::uint8_t* out_data,
    std::uint32_t out_data_capacity,
    std::uint32_t* out_offsets,
    int out_block_capacity,
    int* out_block_count,
    std::uint32_t* out_data_size);

core::Status erasure_encode_with_mode(
    const std::uint8_t* input_data,
    const std::uint32_t* input_offsets,
    int block_count,
    double redundancy,
    ErasureMode mode,
    ErasureField field,
    std::uint8_t* out_data,
    std::uint32_t out_data_capacity,
    std::uint32_t* out_offsets,
    int out_block_capacity,
    int* out_block_count,
    std::uint32_t* out_data_size);

core::Status erasure_decode_systematic(
    const std::uint8_t* blocks_data,
    const std::uint32_t* block_offsets,
    const std::uint8_t* block_present,
    int block_count,
    int original_count,
    std::uint8_t* out_data,
    std::uint32_t out_data_capacity,
    std::uint32_t* out_offsets,
    int out_block_capacity,
    int* out_block_count,
    std::uint32_t* out_data_size);

core::Status erasure_decode_systematic_with_mode(
    const std::uint8_t* blocks_data,
    const std::uint32_t* block_offsets,
    const std::uint8_t* block_present,
    int block_count,
    int original_count,
    ErasureMode mode,
    ErasureField field,
    std::uint8_t* out_data,
    std::uint32_t out_data_capacity,
    std::uint32_t* out_offsets,
    int out_block_capacity,
    int* out_block_count,
    std::uint32_t* out_data_size);

core::Status erasure_decode_systematic_with_mode(
    const std::uint8_t* blocks_data,
    const std::uint32_t* block_offsets,
    const std::uint8_t* block_present,
    int block_count,
    int original_count,
    ErasureMode mode,
    ErasureField field,
    std::uint8_t* out_data,
    std::uint32_t out_data_capacity,
    std::uint32_t* out_offsets,
    int out_block_capacity,
    int* out_block_count,
    std::uint32_t* out_data_size);

core::Status erasure_decode_systematic_with_mode(
    const std::uint8_t* blocks_data,
    const std::uint32_t* block_offsets,
    const std::uint8_t* block_present,
    int block_count,
    int original_count,
    ErasureMode mode,
    ErasureField field,
    std::uint8_t* out_data,
    std::uint32_t out_data_capacity,
    std::uint32_t* out_offsets,
    int out_block_capacity,
    int* out_block_count,
    std::uint32_t* out_data_size);

}  // namespace upload
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_UPLOAD_ERASURE_CODING_H
