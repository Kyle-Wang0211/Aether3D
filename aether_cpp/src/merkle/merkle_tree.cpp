// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/merkle/merkle_tree.h"

#include <cstring>
#include <new>

namespace aether {
namespace merkle {

MerkleTree::MerkleTree() {
    reset();
}

aether::core::Status MerkleTree::reset() {
    size_ = 0;
    root_ = empty_root();
    std::memset(frontier_, 0, sizeof(frontier_));
    std::memset(frontier_valid_, 0, sizeof(frontier_valid_));
    return aether::core::Status::kOk;
}

aether::core::Status MerkleTree::ensure_storage() {
    if (leaves_) {
        return aether::core::Status::kOk;
    }
    auto* raw = new (std::nothrow) Hash32[MERKLE_MAX_LEAVES];
    if (raw == nullptr) {
        return aether::core::Status::kResourceExhausted;
    }
    std::memset(raw, 0, sizeof(Hash32) * MERKLE_MAX_LEAVES);
    leaves_.reset(raw);
    return aether::core::Status::kOk;
}

uint64_t MerkleTree::largest_power_of_two_less_than(uint64_t value) {
    if (value <= 1) {
        return 0;
    }
    uint64_t k = 1;
    while (k * 2 < value) {
        k *= 2;
    }
    return k;
}

aether::core::Status MerkleTree::append(const uint8_t* data, size_t len) {
    if (len > static_cast<size_t>(MERKLE_LEAF_DATA_MAX_LEN)) {
        return aether::core::Status::kInvalidArgument;
    }
    if (len > 0 && data == nullptr) {
        return aether::core::Status::kInvalidArgument;
    }
    const Hash32 leaf = hash_leaf(data, len);
    return append_hash(leaf);
}

aether::core::Status MerkleTree::append_hash(const Hash32& leaf_hash) {
    if (size_ >= MERKLE_MAX_LEAVES) {
        return aether::core::Status::kResourceExhausted;
    }

    const aether::core::Status storage_status = ensure_storage();
    if (storage_status != aether::core::Status::kOk) {
        return storage_status;
    }

    leaves_[size_] = leaf_hash;

    // Update frontier: merge upward where the binary decomposition has a carry.
    Hash32 current = leaf_hash;
    uint64_t index = size_;
    for (uint32_t level = 0; level <= MERKLE_MAX_TREE_DEPTH; ++level) {
        if ((index & 1ULL) == 0ULL) {
            // Left child at this level: store in frontier and stop.
            frontier_[level] = current;
            frontier_valid_[level] = 1;
            break;
        }
        // Right child: merge with the left sibling from the frontier.
        current = hash_nodes(frontier_[level], current);
        frontier_valid_[level] = 0;
        index >>= 1ULL;
    }

    ++size_;
    recompute_root_from_frontier();
    return aether::core::Status::kOk;
}

void MerkleTree::recompute_root_from_frontier() {
    if (size_ == 0) {
        root_ = empty_root();
        return;
    }

    bool have_hash = false;
    Hash32 current{};
    for (uint32_t level = 0; level <= MERKLE_MAX_TREE_DEPTH; ++level) {
        if (frontier_valid_[level] == 0) {
            continue;
        }
        if (!have_hash) {
            current = frontier_[level];
            have_hash = true;
        } else {
            current = hash_nodes(frontier_[level], current);
        }
    }

    if (have_hash) {
        root_ = current;
    } else {
        root_ = empty_root();
    }
}

aether::core::Status MerkleTree::root_at_size(uint64_t tree_size, Hash32& out_root) const {
    if (tree_size == 0) {
        out_root = empty_root();
        return aether::core::Status::kOk;
    }
    if (tree_size > size_) {
        return aether::core::Status::kOutOfRange;
    }
    if (tree_size == size_) {
        out_root = root_;
        return aether::core::Status::kOk;
    }
    return compute_root_range(0, tree_size, out_root);
}

aether::core::Status MerkleTree::compute_root_range(
    uint64_t start, uint64_t count, Hash32& out_root) const {
    if (count == 0) {
        out_root = empty_root();
        return aether::core::Status::kOk;
    }
    if (count == 1) {
        if (start >= size_) {
            return aether::core::Status::kOutOfRange;
        }
        out_root = leaves_[start];
        return aether::core::Status::kOk;
    }

    const uint64_t split = largest_power_of_two_less_than(count);
    Hash32 left_hash{};
    Hash32 right_hash{};

    aether::core::Status status = compute_root_range(start, split, left_hash);
    if (status != aether::core::Status::kOk) {
        return status;
    }
    status = compute_root_range(start + split, count - split, right_hash);
    if (status != aether::core::Status::kOk) {
        return status;
    }

    out_root = hash_nodes(left_hash, right_hash);
    return aether::core::Status::kOk;
}

aether::core::Status MerkleTree::append_inclusion_hash(
    InclusionProof& out, const Hash32& hash) const {
    if (out.path_length >= MERKLE_PROOF_MAX_HASHES) {
        return aether::core::Status::kResourceExhausted;
    }
    out.path[out.path_length] = hash;
    ++out.path_length;
    return aether::core::Status::kOk;
}

aether::core::Status MerkleTree::append_consistency_hash(
    ConsistencyProof& out, const Hash32& hash) const {
    if (out.proof_length >= MERKLE_CONSISTENCY_PROOF_MAX_HASHES) {
        return aether::core::Status::kResourceExhausted;
    }
    out.proof[out.proof_length] = hash;
    ++out.proof_length;
    return aether::core::Status::kOk;
}

aether::core::Status MerkleTree::inclusion_proof(
    uint64_t leaf_index, InclusionProof& out) const {
    if (size_ == 0) {
        return aether::core::Status::kOutOfRange;
    }
    if (leaf_index >= size_) {
        return aether::core::Status::kOutOfRange;
    }

    out = InclusionProof{};
    out.tree_size = size_;
    out.leaf_index = leaf_index;
    out.leaf_hash = leaves_[leaf_index];
    out.path_length = 0;

    return build_inclusion_path(0, size_, leaf_index, out);
}

aether::core::Status MerkleTree::build_inclusion_path(
    uint64_t start, uint64_t count, uint64_t target,
    InclusionProof& out) const {
    if (count == 1) {
        return aether::core::Status::kOk;
    }

    const uint64_t split = largest_power_of_two_less_than(count);
    const uint64_t relative_target = target - start;

    if (relative_target < split) {
        // Target is in the left subtree; sibling is the right subtree root.
        Hash32 right_hash{};
        aether::core::Status status = compute_root_range(start + split, count - split, right_hash);
        if (status != aether::core::Status::kOk) {
            return status;
        }
        status = append_inclusion_hash(out, right_hash);
        if (status != aether::core::Status::kOk) {
            return status;
        }
        return build_inclusion_path(start, split, target, out);
    }
    // Target is in the right subtree; sibling is the left subtree root.
    Hash32 left_hash{};
    aether::core::Status status = compute_root_range(start, split, left_hash);
    if (status != aether::core::Status::kOk) {
        return status;
    }
    status = append_inclusion_hash(out, left_hash);
    if (status != aether::core::Status::kOk) {
        return status;
    }
    return build_inclusion_path(start + split, count - split, target, out);
}

aether::core::Status MerkleTree::consistency_proof(
    uint64_t first_size,
    uint64_t second_size,
    ConsistencyProof& out) const {
    if (first_size > second_size) {
        return aether::core::Status::kInvalidArgument;
    }
    if (second_size > size_) {
        return aether::core::Status::kOutOfRange;
    }

    out = ConsistencyProof{};
    out.first_tree_size = first_size;
    out.second_tree_size = second_size;
    out.proof_length = 0;

    if (first_size == 0 || first_size == second_size) {
        // Empty proof for these degenerate cases.
        return aether::core::Status::kOk;
    }

    // Per RFC 6962, find where first_size sits in the binary decomposition.
    // The proof starts with build_consistency_path from the root of second_size.
    // The complete_subtree flag is initially true when first_size is a power of two.
    const bool first_is_pot = (first_size & (first_size - 1ULL)) == 0ULL;

    return build_consistency_path(0, first_size, second_size, first_is_pot, out);
}

aether::core::Status MerkleTree::build_consistency_path(
    uint64_t start,
    uint64_t first_count,
    uint64_t second_count,
    bool complete_subtree,
    ConsistencyProof& out) const {
    if (first_count == second_count) {
        if (!complete_subtree) {
            // Emit the root of first_count as a proof element.
            Hash32 sub_root{};
            aether::core::Status status = compute_root_range(start, first_count, sub_root);
            if (status != aether::core::Status::kOk) {
                return status;
            }
            status = append_consistency_hash(out, sub_root);
            if (status != aether::core::Status::kOk) {
                return status;
            }
        }
        return aether::core::Status::kOk;
    }

    // Split the second tree.
    const uint64_t split = largest_power_of_two_less_than(second_count);

    if (first_count <= split) {
        // The first tree fits entirely in the left subtree.
        // We need to provide the right subtree hash as a proof node,
        // then recurse into the left subtree.
        Hash32 right_hash{};
        aether::core::Status status = compute_root_range(
            start + split, second_count - split, right_hash);
        if (status != aether::core::Status::kOk) {
            return status;
        }
        status = build_consistency_path(start, first_count, split, complete_subtree, out);
        if (status != aether::core::Status::kOk) {
            return status;
        }
        return append_consistency_hash(out, right_hash);
    }
    // The first tree straddles the split.
    // Emit the left subtree hash, then recurse into the right subtree.
    Hash32 left_hash{};
    aether::core::Status status = compute_root_range(start, split, left_hash);
    if (status != aether::core::Status::kOk) {
        return status;
    }
    status = build_consistency_path(
        start + split, first_count - split, second_count - split, false, out);
    if (status != aether::core::Status::kOk) {
        return status;
    }
    return append_consistency_hash(out, left_hash);
}

}  // namespace merkle
}  // namespace aether
