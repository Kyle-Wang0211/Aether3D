// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/merkle/inclusion_proof.h"
#include "aether/merkle/merkle_tree_hash.h"
#include "aether/merkle/merkle_constants.h"

#include <cstdio>
#include <cstring>

int main() {
    int failed = 0;
    using namespace aether::merkle;

    // -- Test 1: Default-constructed InclusionProof has zero values. --
    {
        InclusionProof proof{};
        if (proof.tree_size != 0) {
            std::fprintf(stderr, "default tree_size should be 0\n");
            failed++;
        }
        if (proof.leaf_index != 0) {
            std::fprintf(stderr, "default leaf_index should be 0\n");
            failed++;
        }
        if (proof.path_length != 0) {
            std::fprintf(stderr, "default path_length should be 0\n");
            failed++;
        }
        if (!hash_is_zero(proof.leaf_hash)) {
            std::fprintf(stderr, "default leaf_hash should be zero\n");
            failed++;
        }
    }

    // -- Test 2: Verify with empty root for tree_size=0 should fail. --
    {
        InclusionProof proof{};
        proof.tree_size = 0;
        proof.leaf_index = 0;
        proof.path_length = 0;
        Hash32 root = empty_root();
        // An empty tree has no leaves, so inclusion proof cannot be valid.
        bool ok = proof.verify(root);
        if (ok) {
            std::fprintf(stderr,
                         "verify should fail for empty tree (tree_size=0)\n");
            failed++;
        }
    }

    // -- Test 3: Single-leaf tree: leaf_index=0, tree_size=1. --
    {
        const uint8_t data[] = {0xAA, 0xBB, 0xCC};
        Hash32 leaf = hash_leaf(data, sizeof(data));

        // For a single-leaf tree, the root IS the leaf hash,
        // and the path is empty.
        InclusionProof proof{};
        proof.tree_size = 1;
        proof.leaf_index = 0;
        proof.path_length = 0;
        proof.leaf_hash = leaf;

        bool ok = proof.verify(leaf);
        if (!ok) {
            std::fprintf(stderr,
                         "single-leaf tree: verify should succeed\n");
            failed++;
        }
    }

    // -- Test 4: verify_with_leaf_data for single-leaf tree. --
    {
        const uint8_t data[] = {0x01, 0x02, 0x03, 0x04};
        Hash32 leaf = hash_leaf(data, sizeof(data));

        InclusionProof proof{};
        proof.tree_size = 1;
        proof.leaf_index = 0;
        proof.path_length = 0;
        proof.leaf_hash = leaf;

        bool ok = proof.verify_with_leaf_data(data, sizeof(data), leaf);
        if (!ok) {
            std::fprintf(stderr,
                         "verify_with_leaf_data should succeed for matching data\n");
            failed++;
        }
    }

    // -- Test 5: verify_with_leaf_data should fail for wrong data. --
    {
        const uint8_t data[] = {0x01, 0x02, 0x03};
        const uint8_t wrong[] = {0xFF, 0xFE, 0xFD};
        Hash32 leaf = hash_leaf(data, sizeof(data));

        InclusionProof proof{};
        proof.tree_size = 1;
        proof.leaf_index = 0;
        proof.path_length = 0;
        proof.leaf_hash = leaf;

        bool ok = proof.verify_with_leaf_data(wrong, sizeof(wrong), leaf);
        if (ok) {
            std::fprintf(stderr,
                         "verify_with_leaf_data should fail for mismatched data\n");
            failed++;
        }
    }

    // -- Test 6: Two-leaf tree with manually computed root. --
    {
        const uint8_t data_a[] = {0x10};
        const uint8_t data_b[] = {0x20};
        Hash32 leaf_a = hash_leaf(data_a, sizeof(data_a));
        Hash32 leaf_b = hash_leaf(data_b, sizeof(data_b));
        Hash32 root = hash_nodes(leaf_a, leaf_b);

        // Proof for leaf 0 in a 2-leaf tree: path = [leaf_b].
        InclusionProof proof{};
        proof.tree_size = 2;
        proof.leaf_index = 0;
        proof.path_length = 1;
        proof.leaf_hash = leaf_a;
        proof.path[0] = leaf_b;

        bool ok = proof.verify(root);
        if (!ok) {
            std::fprintf(stderr,
                         "two-leaf tree: verify for leaf 0 should succeed\n");
            failed++;
        }
    }

    // -- Test 7: Two-leaf tree, proof for leaf 1. --
    {
        const uint8_t data_a[] = {0x10};
        const uint8_t data_b[] = {0x20};
        Hash32 leaf_a = hash_leaf(data_a, sizeof(data_a));
        Hash32 leaf_b = hash_leaf(data_b, sizeof(data_b));
        Hash32 root = hash_nodes(leaf_a, leaf_b);

        // Proof for leaf 1: path = [leaf_a].
        InclusionProof proof{};
        proof.tree_size = 2;
        proof.leaf_index = 1;
        proof.path_length = 1;
        proof.leaf_hash = leaf_b;
        proof.path[0] = leaf_a;

        bool ok = proof.verify(root);
        if (!ok) {
            std::fprintf(stderr,
                         "two-leaf tree: verify for leaf 1 should succeed\n");
            failed++;
        }
    }

    // -- Test 8: Verify with wrong root should fail. --
    {
        const uint8_t data_a[] = {0x10};
        const uint8_t data_b[] = {0x20};
        Hash32 leaf_a = hash_leaf(data_a, sizeof(data_a));
        Hash32 leaf_b = hash_leaf(data_b, sizeof(data_b));

        InclusionProof proof{};
        proof.tree_size = 2;
        proof.leaf_index = 0;
        proof.path_length = 1;
        proof.leaf_hash = leaf_a;
        proof.path[0] = leaf_b;

        // Use a bogus root.
        Hash32 bogus_root{};
        std::memset(bogus_root.data(), 0xFF, 32);

        bool ok = proof.verify(bogus_root);
        if (ok) {
            std::fprintf(stderr,
                         "verify with wrong root should fail\n");
            failed++;
        }
    }

    // -- Test 9: leaf_index out of range should fail. --
    {
        const uint8_t data[] = {0x42};
        Hash32 leaf = hash_leaf(data, sizeof(data));

        InclusionProof proof{};
        proof.tree_size = 1;
        proof.leaf_index = 5;  // out of range
        proof.path_length = 0;
        proof.leaf_hash = leaf;

        bool ok = proof.verify(leaf);
        if (ok) {
            std::fprintf(stderr,
                         "verify should fail when leaf_index >= tree_size\n");
            failed++;
        }
    }

    return failed;
}
