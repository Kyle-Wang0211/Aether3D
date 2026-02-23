// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_MERKLE_CONSISTENCY_PROOF_H
#define AETHER_MERKLE_CONSISTENCY_PROOF_H

#include "aether/merkle/merkle_constants.h"
#include "aether/merkle/merkle_tree_hash.h"

#include <cstdint>

namespace aether {
namespace merkle {

struct ConsistencyProof {
    uint64_t first_tree_size{0};
    uint64_t second_tree_size{0};
    uint32_t proof_length{0};
    Hash32 proof[MERKLE_CONSISTENCY_PROOF_MAX_HASHES]{};

    bool verify(const Hash32& first_root, const Hash32& second_root) const;
};

}  // namespace merkle
}  // namespace aether

#endif  // AETHER_MERKLE_CONSISTENCY_PROOF_H
