// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_INNOVATION_F5_DELTA_PATCH_CHAIN_H
#define AETHER_INNOVATION_F5_DELTA_PATCH_CHAIN_H

#ifdef __cplusplus

#include "aether/core/status.h"
#include "aether/innovation/core_types.h"
#include "aether/merkle/inclusion_proof.h"
#include "aether/merkle/merkle_tree.h"

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace aether {
namespace innovation {

enum class F5PatchOpType : std::uint8_t {
    kUpsertGaussian = 0,
    kRemoveGaussian = 1,
    kUpsertScaffoldUnit = 2,
    kRemoveScaffoldUnit = 3,
};

struct F5PatchOperation {
    F5PatchOpType type{F5PatchOpType::kUpsertGaussian};
    GaussianPrimitive gaussian{};
    ScaffoldUnit scaffold_unit{};
    std::uint32_t gaussian_id{0};
    std::uint64_t scaffold_unit_id{0};
};

struct F5DeltaPatch {
    std::uint64_t parent_version{0};
    std::uint64_t version{0};
    std::int64_t timestamp_ms{0};
    std::string patch_id{};
    std::vector<ScaffoldUnitId> affected_scaffold_unit_ids{};
    std::vector<GaussianId> removed_gaussian_ids{};
    std::vector<GaussianPrimitive> added_gaussians{};
    std::string old_state_sha256_hex{};
    std::string new_state_sha256_hex{};
    std::vector<F5PatchOperation> operations{};
};

struct F5PatchReceipt {
    std::uint64_t version{0};
    std::uint64_t leaf_index{0};
    std::string patch_id{};
    std::string patch_sha256_hex{};
    std::string merkle_root_hex{};
};

struct F5SceneSnapshot {
    std::uint64_t version{0};
    std::vector<GaussianPrimitive> gaussians{};
    std::vector<ScaffoldUnit> scaffold_units{};
    std::string state_sha256_hex{};
};

class F5DeltaPatchChain {
public:
    F5DeltaPatchChain() = default;

    core::Status reset();
    std::size_t patch_count() const { return patch_count_; }
    std::uint64_t latest_version() const { return latest_version_; }
    const merkle::Hash32& merkle_root() const { return merkle_.root_hash(); }

    core::Status append_patch(const F5DeltaPatch& patch, F5PatchReceipt* out_receipt);
    core::Status inclusion_proof_for_version(std::uint64_t version, merkle::InclusionProof* out_proof) const;
    core::Status verify_receipt(
        const F5PatchReceipt& receipt,
        const merkle::InclusionProof& proof,
        bool* out_valid) const;
    core::Status verify_delta_transition(
        const F5DeltaPatch& patch,
        bool* out_valid) const;

    core::Status materialize_scene(
        std::vector<GaussianPrimitive>* out_gaussians,
        std::vector<ScaffoldUnit>* out_scaffold_units) const;
    core::Status materialize_scene_at_version(
        std::uint64_t version,
        std::vector<GaussianPrimitive>* out_gaussians,
        std::vector<ScaffoldUnit>* out_scaffold_units) const;
    core::Status snapshot_for_version(
        std::uint64_t version,
        F5SceneSnapshot* out_snapshot) const;

private:
    core::Status apply_operation(
        const F5PatchOperation& op,
        std::vector<GaussianPrimitive>* inout_gaussians,
        std::vector<ScaffoldUnit>* inout_scaffold_units) const;
    core::Status compute_scene_state_sha256(
        const std::vector<GaussianPrimitive>& gaussians,
        const std::vector<ScaffoldUnit>& scaffold_units,
        std::string* out_sha256_hex) const;
    core::Status summarize_patch(F5DeltaPatch* inout_patch) const;

    std::size_t patch_count_{0};
    std::vector<GaussianPrimitive> scene_gaussians_{};
    std::vector<ScaffoldUnit> scene_scaffold_units_{};
    std::vector<F5DeltaPatch> patches_{};
    merkle::MerkleTree merkle_{};
    std::uint64_t latest_version_{0};
};

core::Status f5_make_delta_patch_receipt(
    const F5DeltaPatchChain& chain,
    std::uint64_t version,
    F5PatchReceipt* out_receipt);

}  // namespace innovation
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_INNOVATION_F5_DELTA_PATCH_CHAIN_H
