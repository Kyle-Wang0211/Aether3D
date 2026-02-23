// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/merkle/consistency_proof.h"

namespace aether {
namespace merkle {

namespace {

bool is_power_of_two(uint64_t value) {
    return value != 0ULL && (value & (value - 1ULL)) == 0ULL;
}

[[maybe_unused]] uint64_t largest_power_of_two_less_than(uint64_t value) {
    if (value <= 1) {
        return 0;
    }
    uint64_t k = 1;
    while (k * 2 < value) {
        k *= 2;
    }
    return k;
}

}  // namespace

bool ConsistencyProof::verify(const Hash32& first_root, const Hash32& second_root) const {
    if (first_tree_size > second_tree_size) {
        return false;
    }
    if (proof_length > MERKLE_CONSISTENCY_PROOF_MAX_HASHES) {
        return false;
    }

    if (first_tree_size == 0) {
        // An empty first tree is trivially consistent with any second tree.
        // The proof should be empty.
        return proof_length == 0;
    }

    if (first_tree_size == second_tree_size) {
        // Same size: the roots must match, proof should be empty.
        if (proof_length != 0) {
            return false;
        }
        return first_root == second_root;
    }

    // RFC 6962 consistency proof verification.
    // We walk the proof to reconstruct both first_root and second_root.
    //
    // The proof is constructed by the prover using build_consistency_path.
    // During verification we consume proof nodes from the front.
    //
    // Algorithm:
    //   - Start with fn = first_tree_size - 1, sn = second_tree_size - 1.
    //   - While LSB(fn) is 1, shift fn and sn right (fn was a right child).
    //   - Set fr = proof[0] if first_tree_size is NOT a power of two,
    //     otherwise set fr = proof[0] with index starting at 0 (the first
    //     node IS the old root for power-of-two case, obtained implicitly).
    //
    // Following the reference implementation from RFC 9162 / CT:
    //   If first_tree_size is a power of two, the old root is a complete
    //   subtree and is not included in the proof. The verifier starts with
    //   fr = sr = first_root as the seed. Otherwise, the first proof element
    //   is the hash of the old subtree, used as the seed for both fr and sr.

    uint32_t idx = 0;  // index into proof[]

    Hash32 fr{};
    Hash32 sr{};

    if (is_power_of_two(first_tree_size)) {
        // The old tree is a complete subtree: seed from first_root directly.
        fr = first_root;
        sr = first_root;
    } else {
        // The first proof element is the hash of the subtree at the
        // position where the first tree's frontier node sits.
        if (idx >= proof_length) {
            return false;
        }
        fr = proof[idx];
        sr = proof[idx];
        ++idx;
    }

    // fn and sn track the node indices as we walk up the tree.
    uint64_t fn = first_tree_size - 1ULL;
    uint64_t sn = second_tree_size - 1ULL;

    // Strip common right-child path: while fn's LSB is 1,
    // both fn and sn are right children at the same level.
    while (fn > 0 && (fn & 1ULL) == 1ULL) {
        fn >>= 1ULL;
        sn >>= 1ULL;
    }

    // Now consume the remaining proof nodes.
    while (idx < proof_length) {
        const Hash32& p = proof[idx];
        ++idx;

        if (fn & 1ULL || fn == sn) {
            // fn is a right child, or fn and sn are at the same position:
            // the proof node is a left sibling.
            fr = hash_nodes(p, fr);
            sr = hash_nodes(p, sr);
        } else {
            // fn is a left child: the proof node is a right sibling.
            // Only sr is updated (first tree doesn't extend this far).
            sr = hash_nodes(sr, p);
        }

        if (fn == 0 && sn == 0) {
            break;
        }

        fn >>= 1ULL;
        sn >>= 1ULL;
    }

    // After consuming all proof nodes, we should have fn == sn == 0
    // (reached the root level) and used exactly proof_length nodes.
    if (idx != proof_length) {
        return false;
    }

    return fr == first_root && sr == second_root;
}

}  // namespace merkle
}  // namespace aether
