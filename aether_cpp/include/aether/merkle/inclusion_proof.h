// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_MERKLE_INCLUSION_PROOF_H
#define AETHER_MERKLE_INCLUSION_PROOF_H

#include "aether/merkle/merkle_constants.h"
#include "aether/merkle/merkle_tree_hash.h"

#include <cstddef>
#include <cstdint>

namespace aether {
namespace merkle {

struct InclusionProof {
    uint64_t tree_size{0};
    uint64_t leaf_index{0};
    uint32_t path_length{0};
    Hash32 leaf_hash{};
    Hash32 path[MERKLE_PROOF_MAX_HASHES]{};

    bool verify(const Hash32& expected_root) const;
    bool verify_with_leaf_data(const uint8_t* leaf_data, size_t leaf_len, const Hash32& expected_root) const;
};

}  // namespace merkle
}  // namespace aether

#endif  // AETHER_MERKLE_INCLUSION_PROOF_H
