// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_MERKLE_MERKLE_TREE_H
#define AETHER_MERKLE_MERKLE_TREE_H

#include "aether/core/status.h"
#include "aether/merkle/consistency_proof.h"
#include "aether/merkle/inclusion_proof.h"
#include "aether/merkle/merkle_constants.h"
#include "aether/merkle/merkle_tree_hash.h"

#include <cstddef>
#include <cstdint>
#include <memory>

namespace aether {
namespace merkle {

class MerkleTree {
public:
    MerkleTree();
    ~MerkleTree() = default;
    MerkleTree(const MerkleTree&) = delete;
    MerkleTree& operator=(const MerkleTree&) = delete;

    aether::core::Status reset();

    uint64_t size() const { return size_; }
    const Hash32& root_hash() const { return root_; }

    aether::core::Status append(const uint8_t* data, size_t len);
    aether::core::Status append_hash(const Hash32& leaf_hash);

    aether::core::Status root_at_size(uint64_t tree_size, Hash32& out_root) const;
    aether::core::Status inclusion_proof(uint64_t leaf_index, InclusionProof& out) const;
    aether::core::Status consistency_proof(
        uint64_t first_size,
        uint64_t second_size,
        ConsistencyProof& out) const;

private:
    std::unique_ptr<Hash32[]> leaves_;
    uint64_t size_{0};
    Hash32 root_{};
    Hash32 frontier_[MERKLE_MAX_TREE_DEPTH + 1]{};
    uint8_t frontier_valid_[MERKLE_MAX_TREE_DEPTH + 1]{};

    aether::core::Status ensure_storage();
    void recompute_root_from_frontier();

    static uint64_t largest_power_of_two_less_than(uint64_t value);

    aether::core::Status compute_root_range(uint64_t start, uint64_t count, Hash32& out_root) const;
    aether::core::Status append_inclusion_hash(InclusionProof& out, const Hash32& hash) const;
    aether::core::Status append_consistency_hash(ConsistencyProof& out, const Hash32& hash) const;
    aether::core::Status build_inclusion_path(
        uint64_t start,
        uint64_t count,
        uint64_t target,
        InclusionProof& out) const;
    aether::core::Status build_consistency_path(
        uint64_t start,
        uint64_t first_count,
        uint64_t second_count,
        bool complete_subtree,
        ConsistencyProof& out) const;
};

}  // namespace merkle
}  // namespace aether

#endif  // AETHER_MERKLE_MERKLE_TREE_H
