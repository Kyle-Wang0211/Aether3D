// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/merkle/consistency_proof.h"
#include "aether/merkle/merkle_tree_hash.h"
#include "aether/merkle/merkle_constants.h"

#include <cstdio>
#include <cstring>

int main() {
    int failed = 0;
    using namespace aether::merkle;

    // -- Test 1: Default-constructed ConsistencyProof has zero values. --
    {
        ConsistencyProof proof{};
        if (proof.first_tree_size != 0) {
            std::fprintf(stderr, "default first_tree_size should be 0\n");
            failed++;
        }
        if (proof.second_tree_size != 0) {
            std::fprintf(stderr, "default second_tree_size should be 0\n");
            failed++;
        }
        if (proof.proof_length != 0) {
            std::fprintf(stderr, "default proof_length should be 0\n");
            failed++;
        }
    }

    // -- Test 2: Consistency of tree with itself (size 1 -> 1). --
    {
        const uint8_t data[] = {0xAA};
        Hash32 leaf = hash_leaf(data, sizeof(data));

        ConsistencyProof proof{};
        proof.first_tree_size = 1;
        proof.second_tree_size = 1;
        proof.proof_length = 0;

        bool ok = proof.verify(leaf, leaf);
        if (!ok) {
            std::fprintf(stderr,
                         "consistency of tree(1) with itself should succeed\n");
            failed++;
        }
    }

    // -- Test 3: Consistency from tree(1) to tree(2). --
    {
        const uint8_t data_a[] = {0x10};
        const uint8_t data_b[] = {0x20};
        Hash32 leaf_a = hash_leaf(data_a, sizeof(data_a));
        Hash32 leaf_b = hash_leaf(data_b, sizeof(data_b));
        Hash32 root2 = hash_nodes(leaf_a, leaf_b);

        // For tree(1)->tree(2), the consistency proof contains [leaf_b]
        // so the verifier can compute root2 from leaf_a and leaf_b.
        ConsistencyProof proof{};
        proof.first_tree_size = 1;
        proof.second_tree_size = 2;
        proof.proof_length = 1;
        proof.proof[0] = leaf_b;

        bool ok = proof.verify(leaf_a, root2);
        if (!ok) {
            std::fprintf(stderr,
                         "consistency from tree(1) to tree(2) should succeed\n");
            failed++;
        }
    }

    // -- Test 4: Verify with wrong first_root should fail. --
    {
        const uint8_t data_a[] = {0x10};
        const uint8_t data_b[] = {0x20};
        Hash32 leaf_a = hash_leaf(data_a, sizeof(data_a));
        Hash32 leaf_b = hash_leaf(data_b, sizeof(data_b));
        Hash32 root2 = hash_nodes(leaf_a, leaf_b);

        ConsistencyProof proof{};
        proof.first_tree_size = 1;
        proof.second_tree_size = 2;
        proof.proof_length = 1;
        proof.proof[0] = leaf_b;

        // Use a bogus first root.
        Hash32 bogus{};
        std::memset(bogus.data(), 0xFF, 32);

        bool ok = proof.verify(bogus, root2);
        if (ok) {
            std::fprintf(stderr,
                         "verify with wrong first_root should fail\n");
            failed++;
        }
    }

    // -- Test 5: Verify with wrong second_root should fail. --
    {
        const uint8_t data_a[] = {0x10};
        const uint8_t data_b[] = {0x20};
        Hash32 leaf_a = hash_leaf(data_a, sizeof(data_a));
        Hash32 leaf_b = hash_leaf(data_b, sizeof(data_b));

        ConsistencyProof proof{};
        proof.first_tree_size = 1;
        proof.second_tree_size = 2;
        proof.proof_length = 1;
        proof.proof[0] = leaf_b;

        Hash32 bogus{};
        std::memset(bogus.data(), 0xAA, 32);

        bool ok = proof.verify(leaf_a, bogus);
        if (ok) {
            std::fprintf(stderr,
                         "verify with wrong second_root should fail\n");
            failed++;
        }
    }

    // -- Test 6: first_tree_size > second_tree_size is invalid. --
    {
        const uint8_t data[] = {0x42};
        Hash32 leaf = hash_leaf(data, sizeof(data));

        ConsistencyProof proof{};
        proof.first_tree_size = 5;
        proof.second_tree_size = 2;
        proof.proof_length = 0;

        bool ok = proof.verify(leaf, leaf);
        if (ok) {
            std::fprintf(stderr,
                         "verify should fail when first_tree_size > second_tree_size\n");
            failed++;
        }
    }

    // -- Test 7: Zero-size trees should fail or degenerate gracefully. --
    {
        Hash32 er = empty_root();

        ConsistencyProof proof{};
        proof.first_tree_size = 0;
        proof.second_tree_size = 0;
        proof.proof_length = 0;

        bool ok = proof.verify(er, er);
        // Either pass (vacuously true) or fail is acceptable; just ensure no crash.
        (void)ok;
    }

    // -- Test 8: proof_length exceeding max should be handled safely. --
    {
        ConsistencyProof proof{};
        proof.first_tree_size = 1;
        proof.second_tree_size = 2;
        proof.proof_length = MERKLE_CONSISTENCY_PROOF_MAX_HASHES + 1;

        Hash32 dummy{};
        std::memset(dummy.data(), 0x11, 32);

        bool ok = proof.verify(dummy, dummy);
        if (ok) {
            std::fprintf(stderr,
                         "verify with over-max proof_length should fail\n");
            failed++;
        }
    }

    // -- Test 9: Consistency of tree(2) to tree(2). --
    {
        const uint8_t data_a[] = {0x10};
        const uint8_t data_b[] = {0x20};
        Hash32 leaf_a = hash_leaf(data_a, sizeof(data_a));
        Hash32 leaf_b = hash_leaf(data_b, sizeof(data_b));
        Hash32 root2 = hash_nodes(leaf_a, leaf_b);

        ConsistencyProof proof{};
        proof.first_tree_size = 2;
        proof.second_tree_size = 2;
        proof.proof_length = 0;

        bool ok = proof.verify(root2, root2);
        if (!ok) {
            std::fprintf(stderr,
                         "consistency of tree(2) with itself should succeed\n");
            failed++;
        }
    }

    return failed;
}
