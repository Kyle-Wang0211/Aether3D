// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/merkle/merkle_tree_hash.h"

#include <cstdio>
#include <cstring>

namespace {

size_t make_leaf_bytes(uint32_t index, uint8_t out[32]) {
    const int n = std::snprintf(reinterpret_cast<char*>(out), 32, "leaf-%u", static_cast<unsigned>(index));
    if (n < 0) {
        return 0;
    }
    if (n >= 32) {
        return 31;
    }
    return static_cast<size_t>(n);
}

}  // namespace

int main() {
    int failed = 0;
    using namespace aether::merkle;

    // RFC 9162 §2.1.1: empty_root() = SHA-256("") — NOT all zeros.
    // Verify empty_root is deterministic and non-zero.
    const Hash32 er1 = empty_root();
    const Hash32 er2 = empty_root();
    if (!hash_equal(er1, er2)) {
        std::fprintf(stderr, "empty_root determinism mismatch\n");
        ++failed;
    }
    // SHA-256("") = e3b0c442... — first byte is 0xe3, definitely not all-zeros.
    if (hash_is_zero(er1)) {
        std::fprintf(stderr, "empty_root should be SHA-256(\"\"), not all zeros\n");
        ++failed;
    }
    // Verify first byte matches known SHA-256("") value.
    if (er1[0] != 0xe3) {
        std::fprintf(stderr, "empty_root first byte: expected 0xe3, got 0x%02x\n", er1[0]);
        ++failed;
    }

    uint8_t leaf_a_bytes[32] = {};
    const size_t leaf_a_len = make_leaf_bytes(0, leaf_a_bytes);
    const Hash32 leaf_a_1 = hash_leaf(leaf_a_bytes, leaf_a_len);
    const Hash32 leaf_a_2 = hash_leaf(leaf_a_bytes, leaf_a_len);
    if (!hash_equal(leaf_a_1, leaf_a_2)) {
        std::fprintf(stderr, "hash_leaf determinism mismatch\n");
        ++failed;
    }

    uint8_t leaf_b_bytes[32] = {};
    const size_t leaf_b_len = make_leaf_bytes(1, leaf_b_bytes);
    const Hash32 leaf_b = hash_leaf(leaf_b_bytes, leaf_b_len);
    if (hash_equal(leaf_a_1, leaf_b)) {
        std::fprintf(stderr, "hash_leaf should differ for different payloads\n");
        ++failed;
    }

    const Hash32 node_ab_1 = hash_nodes(leaf_a_1, leaf_b);
    const Hash32 node_ab_2 = hash_nodes(leaf_a_1, leaf_b);
    if (!hash_equal(node_ab_1, node_ab_2)) {
        std::fprintf(stderr, "hash_nodes determinism mismatch\n");
        ++failed;
    }

    const Hash32 node_ba = hash_nodes(leaf_b, leaf_a_1);
    if (hash_equal(node_ab_1, node_ba)) {
        std::fprintf(stderr, "hash_nodes should be order-sensitive\n");
        ++failed;
    }

    if (hash_equal(node_ab_1, leaf_a_1)) {
        std::fprintf(stderr, "node hash must not equal leaf hash\n");
        ++failed;
    }

    return failed;
}
