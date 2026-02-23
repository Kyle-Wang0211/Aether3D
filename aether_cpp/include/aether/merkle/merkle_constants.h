// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_MERKLE_MERKLE_CONSTANTS_H
#define AETHER_MERKLE_MERKLE_CONSTANTS_H

#include <cstdint>

namespace aether {
namespace merkle {

static constexpr uint64_t MERKLE_MAX_LEAVES = 1ULL << 20;           // 1,048,576
static constexpr uint32_t MERKLE_MAX_TREE_DEPTH = 20;               // log2(MERKLE_MAX_LEAVES)
static constexpr uint32_t MERKLE_LEAF_DATA_MAX_LEN = 4096;
static constexpr uint32_t MERKLE_PROOF_MAX_HASHES = MERKLE_MAX_TREE_DEPTH;
static constexpr uint32_t MERKLE_CONSISTENCY_PROOF_MAX_HASHES = MERKLE_MAX_TREE_DEPTH * 2U;

static_assert((1ULL << MERKLE_MAX_TREE_DEPTH) == MERKLE_MAX_LEAVES, "MERKLE depth/leaves mismatch");

}  // namespace merkle
}  // namespace aether

#endif  // AETHER_MERKLE_MERKLE_CONSTANTS_H
