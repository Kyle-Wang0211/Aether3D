// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/merkle/inclusion_proof.h"

namespace aether {
namespace merkle {

bool InclusionProof::verify(const Hash32& expected_root) const {
    if (tree_size == 0 || leaf_index >= tree_size) {
        return false;
    }
    if (path_length > MERKLE_PROOF_MAX_HASHES) {
        return false;
    }

    Hash32 current = leaf_hash;
    uint64_t index = leaf_index;
    uint64_t remaining = tree_size;
    uint32_t used = 0;

    while (remaining > 1) {
        const bool current_is_left = (index & 1ULL) == 0ULL;
        bool has_sibling = false;

        if (current_is_left) {
            // Left child. It has a right sibling if (index + 1) < remaining
            // at this level, i.e., there are more leaves on the right.
            // In an RFC 6962 tree with non-power-of-two size, the rightmost
            // node at a level may not have a sibling. We determine this by
            // checking if there is more than one node when we halve.
            //
            // Actually, the standard approach: if index is even and index+1
            // is within bounds at this level, we have a sibling from the path.
            // The tree size at each level is ceil(remaining / 2) for the next
            // level. If index is the last (odd-count), it gets promoted.
            if (index + 1 < remaining) {
                has_sibling = true;
            }
        } else {
            // Right child always has a left sibling.
            has_sibling = true;
        }

        if (has_sibling) {
            if (used >= path_length) {
                return false;
            }
            if (current_is_left) {
                current = hash_nodes(current, path[used]);
            } else {
                current = hash_nodes(path[used], current);
            }
            ++used;
        }
        // else: no sibling, the node is promoted as-is (rightmost at odd level).

        index >>= 1ULL;
        remaining = (remaining + 1ULL) >> 1ULL;
    }

    if (used != path_length) {
        return false;
    }

    return current == expected_root;
}

bool InclusionProof::verify_with_leaf_data(
    const uint8_t* leaf_data, size_t leaf_len,
    const Hash32& expected_root) const {
    const Hash32 computed_leaf = hash_leaf(leaf_data, leaf_len);
    if (computed_leaf != leaf_hash) {
        return false;
    }
    return verify(expected_root);
}

}  // namespace merkle
}  // namespace aether
