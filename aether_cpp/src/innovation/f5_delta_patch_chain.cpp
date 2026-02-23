// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/innovation/f5_delta_patch_chain.h"

#include "aether/crypto/sha256.h"
#include "aether/evidence/deterministic_json.h"

#include <algorithm>
#include <cstdint>
#include <string>
#include <utility>
#include <vector>

namespace aether {
namespace innovation {
namespace {

std::uint64_t op_target_id(const F5PatchOperation& op) {
    switch (op.type) {
        case F5PatchOpType::kUpsertGaussian:
            return static_cast<std::uint64_t>(op.gaussian.id);
        case F5PatchOpType::kRemoveGaussian:
            return static_cast<std::uint64_t>(op.gaussian_id);
        case F5PatchOpType::kUpsertScaffoldUnit:
            return op.scaffold_unit.unit_id;
        case F5PatchOpType::kRemoveScaffoldUnit:
            return op.scaffold_unit_id;
    }
    return 0u;
}

const char* op_name(F5PatchOpType type) {
    switch (type) {
        case F5PatchOpType::kUpsertGaussian:
            return "upsert_gaussian";
        case F5PatchOpType::kRemoveGaussian:
            return "remove_gaussian";
        case F5PatchOpType::kUpsertScaffoldUnit:
            return "upsert_scaffold_unit";
        case F5PatchOpType::kRemoveScaffoldUnit:
            return "remove_scaffold_unit";
    }
    return "unknown";
}

bool is_same_op_key(const F5PatchOperation& lhs, const F5PatchOperation& rhs) {
    return lhs.type == rhs.type && op_target_id(lhs) == op_target_id(rhs);
}

evidence::CanonicalJsonValue encode_gaussian_json(const GaussianPrimitive& g) {
    using evidence::CanonicalJsonValue;

    std::vector<CanonicalJsonValue> pos;
    pos.emplace_back(CanonicalJsonValue::make_number_quantized(g.position.x, 6));
    pos.emplace_back(CanonicalJsonValue::make_number_quantized(g.position.y, 6));
    pos.emplace_back(CanonicalJsonValue::make_number_quantized(g.position.z, 6));

    std::vector<CanonicalJsonValue> scale;
    scale.emplace_back(CanonicalJsonValue::make_number_quantized(g.scale.x, 6));
    scale.emplace_back(CanonicalJsonValue::make_number_quantized(g.scale.y, 6));
    scale.emplace_back(CanonicalJsonValue::make_number_quantized(g.scale.z, 6));

    std::vector<CanonicalJsonValue> sh;
    sh.reserve(g.sh_coeffs.size());
    for (float coeff : g.sh_coeffs) {
        sh.emplace_back(CanonicalJsonValue::make_number_quantized(coeff, 6));
    }

    std::vector<std::pair<std::string, CanonicalJsonValue>> obj;
    obj.emplace_back("capture_sequence", CanonicalJsonValue::make_int(static_cast<std::int64_t>(g.capture_sequence)));
    obj.emplace_back("flags", CanonicalJsonValue::make_int(static_cast<std::int64_t>(g.flags)));
    obj.emplace_back("host_unit_id", CanonicalJsonValue::make_int(static_cast<std::int64_t>(g.host_unit_id)));
    obj.emplace_back("id", CanonicalJsonValue::make_int(static_cast<std::int64_t>(g.id)));
    obj.emplace_back("observation_count", CanonicalJsonValue::make_int(static_cast<std::int64_t>(g.observation_count)));
    obj.emplace_back("opacity", CanonicalJsonValue::make_number_quantized(g.opacity, 6));
    obj.emplace_back("patch_priority", CanonicalJsonValue::make_int(static_cast<std::int64_t>(g.patch_priority)));
    obj.emplace_back("position", CanonicalJsonValue::make_array(std::move(pos)));
    obj.emplace_back("scale", CanonicalJsonValue::make_array(std::move(scale)));
    obj.emplace_back("sh_coeffs", CanonicalJsonValue::make_array(std::move(sh)));
    obj.emplace_back("uncertainty", CanonicalJsonValue::make_number_quantized(g.uncertainty, 6));
    return CanonicalJsonValue::make_object(std::move(obj));
}

evidence::CanonicalJsonValue encode_scaffold_unit_json(const ScaffoldUnit& u) {
    using evidence::CanonicalJsonValue;
    std::vector<std::pair<std::string, CanonicalJsonValue>> obj;
    obj.emplace_back("area", CanonicalJsonValue::make_number_quantized(u.area, 6));
    obj.emplace_back("confidence", CanonicalJsonValue::make_number_quantized(u.confidence, 6));
    obj.emplace_back("normal_x", CanonicalJsonValue::make_number_quantized(u.normal.x, 6));
    obj.emplace_back("normal_y", CanonicalJsonValue::make_number_quantized(u.normal.y, 6));
    obj.emplace_back("normal_z", CanonicalJsonValue::make_number_quantized(u.normal.z, 6));
    obj.emplace_back("unit_id", CanonicalJsonValue::make_int(static_cast<std::int64_t>(u.unit_id)));
    obj.emplace_back("v0", CanonicalJsonValue::make_int(static_cast<std::int64_t>(u.v0)));
    obj.emplace_back("v1", CanonicalJsonValue::make_int(static_cast<std::int64_t>(u.v1)));
    obj.emplace_back("v2", CanonicalJsonValue::make_int(static_cast<std::int64_t>(u.v2)));
    obj.emplace_back("view_count", CanonicalJsonValue::make_int(static_cast<std::int64_t>(u.view_count)));
    return CanonicalJsonValue::make_object(std::move(obj));
}

core::Status encode_patch_json(const F5DeltaPatch& patch, std::string* out_json, std::string* out_sha) {
    if (out_json == nullptr || out_sha == nullptr) {
        return core::Status::kInvalidArgument;
    }

    using evidence::CanonicalJsonValue;
    std::vector<CanonicalJsonValue> ops_json;
    ops_json.reserve(patch.operations.size());
    for (const auto& op : patch.operations) {
        std::vector<std::pair<std::string, CanonicalJsonValue>> op_obj;
        op_obj.emplace_back("target_id", CanonicalJsonValue::make_int(static_cast<std::int64_t>(op_target_id(op))));
        op_obj.emplace_back("type", CanonicalJsonValue::make_string(op_name(op.type)));
        if (op.type == F5PatchOpType::kUpsertGaussian) {
            op_obj.emplace_back("gaussian", encode_gaussian_json(op.gaussian));
        } else if (op.type == F5PatchOpType::kUpsertScaffoldUnit) {
            op_obj.emplace_back("scaffold_unit", encode_scaffold_unit_json(op.scaffold_unit));
        }
        ops_json.emplace_back(CanonicalJsonValue::make_object(std::move(op_obj)));
    }

    std::vector<std::pair<std::string, CanonicalJsonValue>> root_obj;
    root_obj.emplace_back("patch_id", CanonicalJsonValue::make_string(patch.patch_id));
    root_obj.emplace_back("operations", CanonicalJsonValue::make_array(std::move(ops_json)));
    {
        std::vector<CanonicalJsonValue> affected_units;
        affected_units.reserve(patch.affected_scaffold_unit_ids.size());
        for (const ScaffoldUnitId unit_id : patch.affected_scaffold_unit_ids) {
            affected_units.emplace_back(CanonicalJsonValue::make_int(static_cast<std::int64_t>(unit_id)));
        }
        root_obj.emplace_back("affected_scaffold_unit_ids", CanonicalJsonValue::make_array(std::move(affected_units)));
    }
    {
        std::vector<CanonicalJsonValue> removed_ids;
        removed_ids.reserve(patch.removed_gaussian_ids.size());
        for (const GaussianId gaussian_id : patch.removed_gaussian_ids) {
            removed_ids.emplace_back(CanonicalJsonValue::make_int(static_cast<std::int64_t>(gaussian_id)));
        }
        root_obj.emplace_back("removed_gaussian_ids", CanonicalJsonValue::make_array(std::move(removed_ids)));
    }
    {
        std::vector<CanonicalJsonValue> added_gaussians;
        added_gaussians.reserve(patch.added_gaussians.size());
        for (const auto& gaussian : patch.added_gaussians) {
            added_gaussians.emplace_back(encode_gaussian_json(gaussian));
        }
        root_obj.emplace_back("added_gaussians", CanonicalJsonValue::make_array(std::move(added_gaussians)));
    }
    if (!patch.old_state_sha256_hex.empty()) {
        root_obj.emplace_back("old_state_sha256_hex", CanonicalJsonValue::make_string(patch.old_state_sha256_hex));
    }
    if (!patch.new_state_sha256_hex.empty()) {
        root_obj.emplace_back("new_state_sha256_hex", CanonicalJsonValue::make_string(patch.new_state_sha256_hex));
    }
    root_obj.emplace_back("parent_version", CanonicalJsonValue::make_int(static_cast<std::int64_t>(patch.parent_version)));
    root_obj.emplace_back("schema", CanonicalJsonValue::make_string("aether.f5.delta_patch.v1"));
    root_obj.emplace_back("timestamp_ms", CanonicalJsonValue::make_int(static_cast<std::int64_t>(patch.timestamp_ms)));
    root_obj.emplace_back("version", CanonicalJsonValue::make_int(static_cast<std::int64_t>(patch.version)));

    const CanonicalJsonValue root = CanonicalJsonValue::make_object(std::move(root_obj));
    core::Status status = evidence::encode_canonical_json(root, *out_json);
    if (status != core::Status::kOk) {
        return status;
    }
    status = evidence::canonical_json_sha256_hex(root, *out_sha);
    return status;
}

int hex_nibble(char c) {
    if (c >= '0' && c <= '9') {
        return static_cast<int>(c - '0');
    }
    if (c >= 'a' && c <= 'f') {
        return static_cast<int>(10 + (c - 'a'));
    }
    if (c >= 'A' && c <= 'F') {
        return static_cast<int>(10 + (c - 'A'));
    }
    return -1;
}

bool parse_hash32_hex(const std::string& hex, merkle::Hash32* out_hash) {
    if (out_hash == nullptr || hex.size() != 64u) {
        return false;
    }
    for (std::size_t i = 0u; i < 32u; ++i) {
        const int hi = hex_nibble(hex[2u * i]);
        const int lo = hex_nibble(hex[2u * i + 1u]);
        if (hi < 0 || lo < 0) {
            return false;
        }
        (*out_hash)[i] = static_cast<std::uint8_t>((hi << 4) | lo);
    }
    return true;
}

std::string default_patch_id_from_version(std::uint64_t version) {
    return std::string("patch:") + std::to_string(static_cast<unsigned long long>(version));
}

void append_u32(std::vector<std::uint8_t>& out, std::uint32_t value) {
    out.push_back(static_cast<std::uint8_t>(value & 0xffu));
    out.push_back(static_cast<std::uint8_t>((value >> 8u) & 0xffu));
    out.push_back(static_cast<std::uint8_t>((value >> 16u) & 0xffu));
    out.push_back(static_cast<std::uint8_t>((value >> 24u) & 0xffu));
}

void append_u16(std::vector<std::uint8_t>& out, std::uint16_t value) {
    out.push_back(static_cast<std::uint8_t>(value & 0xffu));
    out.push_back(static_cast<std::uint8_t>((value >> 8u) & 0xffu));
}

void append_u64(std::vector<std::uint8_t>& out, std::uint64_t value) {
    for (std::uint32_t i = 0u; i < 8u; ++i) {
        out.push_back(static_cast<std::uint8_t>((value >> (8u * i)) & 0xffu));
    }
}

}  // namespace

core::Status F5DeltaPatchChain::reset() {
    patch_count_ = 0u;
    scene_gaussians_.clear();
    scene_scaffold_units_.clear();
    patches_.clear();
    latest_version_ = 0u;
    return merkle_.reset();
}

core::Status F5DeltaPatchChain::apply_operation(
    const F5PatchOperation& op,
    std::vector<GaussianPrimitive>* inout_gaussians,
    std::vector<ScaffoldUnit>* inout_scaffold_units) const {
    if (inout_gaussians == nullptr || inout_scaffold_units == nullptr) {
        return core::Status::kInvalidArgument;
    }
    switch (op.type) {
        case F5PatchOpType::kUpsertGaussian: {
            auto it = std::lower_bound(inout_gaussians->begin(), inout_gaussians->end(), op.gaussian.id, [](const GaussianPrimitive& lhs, std::uint32_t rhs_id) {
                return lhs.id < rhs_id;
            });
            if (it != inout_gaussians->end() && it->id == op.gaussian.id) {
                *it = op.gaussian;
            } else {
                inout_gaussians->insert(it, op.gaussian);
            }
            return core::Status::kOk;
        }
        case F5PatchOpType::kRemoveGaussian: {
            auto it = std::lower_bound(inout_gaussians->begin(), inout_gaussians->end(), op.gaussian_id, [](const GaussianPrimitive& lhs, std::uint32_t rhs_id) {
                return lhs.id < rhs_id;
            });
            if (it != inout_gaussians->end() && it->id == op.gaussian_id) {
                inout_gaussians->erase(it);
            }
            return core::Status::kOk;
        }
        case F5PatchOpType::kUpsertScaffoldUnit: {
            auto it = std::lower_bound(inout_scaffold_units->begin(), inout_scaffold_units->end(), op.scaffold_unit.unit_id, [](const ScaffoldUnit& lhs, std::uint64_t rhs_id) {
                return lhs.unit_id < rhs_id;
            });
            if (it != inout_scaffold_units->end() && it->unit_id == op.scaffold_unit.unit_id) {
                *it = op.scaffold_unit;
            } else {
                inout_scaffold_units->insert(it, op.scaffold_unit);
            }
            return core::Status::kOk;
        }
        case F5PatchOpType::kRemoveScaffoldUnit: {
            auto it = std::lower_bound(inout_scaffold_units->begin(), inout_scaffold_units->end(), op.scaffold_unit_id, [](const ScaffoldUnit& lhs, std::uint64_t rhs_id) {
                return lhs.unit_id < rhs_id;
            });
            if (it != inout_scaffold_units->end() && it->unit_id == op.scaffold_unit_id) {
                inout_scaffold_units->erase(it);
            }
            return core::Status::kOk;
        }
    }
    return core::Status::kInvalidArgument;
}

core::Status F5DeltaPatchChain::compute_scene_state_sha256(
    const std::vector<GaussianPrimitive>& gaussians,
    const std::vector<ScaffoldUnit>& scaffold_units,
    std::string* out_sha256_hex) const {
    if (out_sha256_hex == nullptr) {
        return core::Status::kInvalidArgument;
    }
    std::vector<std::uint8_t> payload;
    payload.reserve(32u + gaussians.size() * 16u + scaffold_units.size() * 16u);
    append_u64(payload, static_cast<std::uint64_t>(gaussians.size()));
    append_u64(payload, static_cast<std::uint64_t>(scaffold_units.size()));
    for (const auto& gaussian : gaussians) {
        append_u32(payload, gaussian.id);
        append_u64(payload, gaussian.host_unit_id);
        append_u16(payload, gaussian.observation_count);
        append_u16(payload, gaussian.patch_priority);
    }
    for (const auto& unit : scaffold_units) {
        append_u64(payload, unit.unit_id);
        append_u32(payload, unit.generation);
        append_u32(payload, unit.v0);
        append_u32(payload, unit.v1);
        append_u32(payload, unit.v2);
    }
    crypto::Sha256Digest digest{};
    crypto::sha256(payload.data(), payload.size(), digest);
    *out_sha256_hex = to_hex_lower(digest.bytes, sizeof(digest.bytes));
    return core::Status::kOk;
}

core::Status F5DeltaPatchChain::summarize_patch(F5DeltaPatch* inout_patch) const {
    if (inout_patch == nullptr) {
        return core::Status::kInvalidArgument;
    }
    inout_patch->affected_scaffold_unit_ids.clear();
    inout_patch->removed_gaussian_ids.clear();
    inout_patch->added_gaussians.clear();
    for (const auto& op : inout_patch->operations) {
        switch (op.type) {
            case F5PatchOpType::kUpsertGaussian:
                inout_patch->added_gaussians.push_back(op.gaussian);
                if (op.gaussian.host_unit_id != 0u) {
                    inout_patch->affected_scaffold_unit_ids.push_back(op.gaussian.host_unit_id);
                }
                break;
            case F5PatchOpType::kRemoveGaussian:
                inout_patch->removed_gaussian_ids.push_back(op.gaussian_id);
                break;
            case F5PatchOpType::kUpsertScaffoldUnit:
                inout_patch->affected_scaffold_unit_ids.push_back(op.scaffold_unit.unit_id);
                break;
            case F5PatchOpType::kRemoveScaffoldUnit:
                inout_patch->affected_scaffold_unit_ids.push_back(op.scaffold_unit_id);
                break;
        }
    }
    std::sort(
        inout_patch->affected_scaffold_unit_ids.begin(),
        inout_patch->affected_scaffold_unit_ids.end());
    inout_patch->affected_scaffold_unit_ids.erase(
        std::unique(
            inout_patch->affected_scaffold_unit_ids.begin(),
            inout_patch->affected_scaffold_unit_ids.end()),
        inout_patch->affected_scaffold_unit_ids.end());
    std::sort(
        inout_patch->removed_gaussian_ids.begin(),
        inout_patch->removed_gaussian_ids.end());
    inout_patch->removed_gaussian_ids.erase(
        std::unique(
            inout_patch->removed_gaussian_ids.begin(),
            inout_patch->removed_gaussian_ids.end()),
        inout_patch->removed_gaussian_ids.end());
    return core::Status::kOk;
}

core::Status F5DeltaPatchChain::append_patch(const F5DeltaPatch& patch, F5PatchReceipt* out_receipt) {
    const std::uint64_t expected_parent = latest_version_;
    if (patch.parent_version != expected_parent) {
        return core::Status::kInvalidArgument;
    }
    const std::uint64_t expected_version = latest_version_ + 1u;
    if (patch.version != 0u && patch.version != expected_version) {
        return core::Status::kInvalidArgument;
    }
    if (patch.operations.empty()) {
        return core::Status::kInvalidArgument;
    }

    F5DeltaPatch canonical = patch;
    canonical.version = expected_version;
    if (canonical.patch_id.empty()) {
        canonical.patch_id = default_patch_id_from_version(expected_version);
    }
    std::sort(canonical.operations.begin(), canonical.operations.end(), [](const F5PatchOperation& lhs, const F5PatchOperation& rhs) {
        if (lhs.type != rhs.type) {
            return static_cast<std::uint8_t>(lhs.type) < static_cast<std::uint8_t>(rhs.type);
        }
        const std::uint64_t lid = op_target_id(lhs);
        const std::uint64_t rid = op_target_id(rhs);
        if (lid != rid) {
            return lid < rid;
        }
        if (lhs.type == F5PatchOpType::kUpsertGaussian) {
            return lhs.gaussian.capture_sequence < rhs.gaussian.capture_sequence;
        }
        return false;
    });
    for (std::size_t i = 1u; i < canonical.operations.size(); ++i) {
        if (is_same_op_key(canonical.operations[i - 1u], canonical.operations[i])) {
            return core::Status::kInvalidArgument;
        }
    }

    core::Status status = summarize_patch(&canonical);
    if (status != core::Status::kOk) {
        return status;
    }

    status = compute_scene_state_sha256(scene_gaussians_, scene_scaffold_units_, &canonical.old_state_sha256_hex);
    if (status != core::Status::kOk) {
        return status;
    }

    std::string patch_json;
    std::string patch_sha;
    status = encode_patch_json(canonical, &patch_json, &patch_sha);
    if (status != core::Status::kOk) {
        return status;
    }

    status = merkle_.append(reinterpret_cast<const std::uint8_t*>(patch_json.data()), patch_json.size());
    if (status != core::Status::kOk) {
        return status;
    }

    for (const auto& op : canonical.operations) {
        status = apply_operation(op, &scene_gaussians_, &scene_scaffold_units_);
        if (status != core::Status::kOk) {
            return status;
        }
    }

    status = compute_scene_state_sha256(scene_gaussians_, scene_scaffold_units_, &canonical.new_state_sha256_hex);
    if (status != core::Status::kOk) {
        return status;
    }

    (void)patch_json;
    (void)patch_sha;
    patches_.push_back(canonical);
    patch_count_ += 1u;
    latest_version_ = canonical.version;

    if (out_receipt != nullptr) {
        return f5_make_delta_patch_receipt(*this, latest_version_, out_receipt);
    }
    return core::Status::kOk;
}

core::Status F5DeltaPatchChain::inclusion_proof_for_version(
    std::uint64_t version,
    merkle::InclusionProof* out_proof) const {
    if (out_proof == nullptr) {
        return core::Status::kInvalidArgument;
    }
    if (version == 0u || version > latest_version_) {
        return core::Status::kOutOfRange;
    }
    const std::uint64_t leaf_index = version - 1u;
    return merkle_.inclusion_proof(leaf_index, *out_proof);
}

core::Status F5DeltaPatchChain::verify_receipt(
    const F5PatchReceipt& receipt,
    const merkle::InclusionProof& proof,
    bool* out_valid) const {
    if (out_valid == nullptr) {
        return core::Status::kInvalidArgument;
    }
    *out_valid = false;
    if (receipt.version == 0u || receipt.version > latest_version_) {
        return core::Status::kOutOfRange;
    }

    merkle::Hash32 expected_root{};
    if (!parse_hash32_hex(receipt.merkle_root_hex, &expected_root)) {
        return core::Status::kInvalidArgument;
    }
    if (proof.leaf_index != receipt.leaf_index) {
        *out_valid = false;
        return core::Status::kOk;
    }
    const std::string proof_leaf_hex = to_hex_lower(proof.leaf_hash.data(), proof.leaf_hash.size());
    if (proof_leaf_hex != receipt.patch_sha256_hex) {
        *out_valid = false;
        return core::Status::kOk;
    }

    *out_valid = proof.verify(expected_root);
    return core::Status::kOk;
}

core::Status F5DeltaPatchChain::verify_delta_transition(
    const F5DeltaPatch& patch,
    bool* out_valid) const {
    if (out_valid == nullptr) {
        return core::Status::kInvalidArgument;
    }
    *out_valid = false;

    std::uint64_t target_version = patch.version;
    if (target_version == 0u) {
        if (patch.parent_version >= latest_version_) {
            return core::Status::kOutOfRange;
        }
        target_version = patch.parent_version + 1u;
    }
    if (target_version == 0u || target_version > patches_.size()) {
        return core::Status::kOutOfRange;
    }
    const F5DeltaPatch& canonical_patch = patches_[target_version - 1u];
    if (!patch.patch_id.empty() && patch.patch_id != canonical_patch.patch_id) {
        return core::Status::kOk;
    }

    const std::uint64_t parent_version =
        (patch.parent_version == 0u) ? canonical_patch.parent_version : patch.parent_version;
    if (parent_version != canonical_patch.parent_version) {
        return core::Status::kOk;
    }

    const std::vector<F5PatchOperation>& operations =
        patch.operations.empty() ? canonical_patch.operations : patch.operations;

    std::vector<GaussianPrimitive> before_gaussians;
    std::vector<ScaffoldUnit> before_units;
    core::Status status = materialize_scene_at_version(
        parent_version, &before_gaussians, &before_units);
    if (status != core::Status::kOk) {
        return status;
    }
    std::string old_hash;
    status = compute_scene_state_sha256(before_gaussians, before_units, &old_hash);
    if (status != core::Status::kOk) {
        return status;
    }
    if (!canonical_patch.old_state_sha256_hex.empty() &&
        canonical_patch.old_state_sha256_hex != old_hash) {
        *out_valid = false;
        return core::Status::kOk;
    }
    if (!patch.old_state_sha256_hex.empty() && patch.old_state_sha256_hex != old_hash) {
        *out_valid = false;
        return core::Status::kOk;
    }

    std::vector<GaussianPrimitive> after_gaussians = before_gaussians;
    std::vector<ScaffoldUnit> after_units = before_units;
    for (const auto& op : operations) {
        status = apply_operation(op, &after_gaussians, &after_units);
        if (status != core::Status::kOk) {
            return status;
        }
    }
    std::string new_hash;
    status = compute_scene_state_sha256(after_gaussians, after_units, &new_hash);
    if (status != core::Status::kOk) {
        return status;
    }
    if (!canonical_patch.new_state_sha256_hex.empty() &&
        canonical_patch.new_state_sha256_hex != new_hash) {
        *out_valid = false;
        return core::Status::kOk;
    }
    if (!patch.new_state_sha256_hex.empty() && patch.new_state_sha256_hex != new_hash) {
        *out_valid = false;
        return core::Status::kOk;
    }
    *out_valid = true;
    return core::Status::kOk;
}

core::Status F5DeltaPatchChain::materialize_scene(
    std::vector<GaussianPrimitive>* out_gaussians,
    std::vector<ScaffoldUnit>* out_scaffold_units) const {
    if (out_gaussians == nullptr || out_scaffold_units == nullptr) {
        return core::Status::kInvalidArgument;
    }
    *out_gaussians = scene_gaussians_;
    *out_scaffold_units = scene_scaffold_units_;
    return core::Status::kOk;
}

core::Status F5DeltaPatchChain::materialize_scene_at_version(
    std::uint64_t version,
    std::vector<GaussianPrimitive>* out_gaussians,
    std::vector<ScaffoldUnit>* out_scaffold_units) const {
    if (out_gaussians == nullptr || out_scaffold_units == nullptr) {
        return core::Status::kInvalidArgument;
    }
    if (version > latest_version_) {
        return core::Status::kOutOfRange;
    }
    if (version == latest_version_) {
        *out_gaussians = scene_gaussians_;
        *out_scaffold_units = scene_scaffold_units_;
        return core::Status::kOk;
    }
    out_gaussians->clear();
    out_scaffold_units->clear();
    for (std::uint64_t i = 0u; i < version; ++i) {
        if (i >= patches_.size()) {
            return core::Status::kOutOfRange;
        }
        for (const auto& op : patches_[i].operations) {
            const core::Status status = apply_operation(op, out_gaussians, out_scaffold_units);
            if (status != core::Status::kOk) {
                return status;
            }
        }
    }
    return core::Status::kOk;
}

core::Status F5DeltaPatchChain::snapshot_for_version(
    std::uint64_t version,
    F5SceneSnapshot* out_snapshot) const {
    if (out_snapshot == nullptr) {
        return core::Status::kInvalidArgument;
    }
    F5SceneSnapshot snapshot{};
    snapshot.version = version;
    core::Status status = materialize_scene_at_version(
        version, &snapshot.gaussians, &snapshot.scaffold_units);
    if (status != core::Status::kOk) {
        return status;
    }
    status = compute_scene_state_sha256(
        snapshot.gaussians, snapshot.scaffold_units, &snapshot.state_sha256_hex);
    if (status != core::Status::kOk) {
        return status;
    }
    *out_snapshot = std::move(snapshot);
    return core::Status::kOk;
}

core::Status f5_make_delta_patch_receipt(
    const F5DeltaPatchChain& chain,
    std::uint64_t version,
    F5PatchReceipt* out_receipt) {
    if (out_receipt == nullptr) {
        return core::Status::kInvalidArgument;
    }
    merkle::InclusionProof proof{};
    core::Status status = chain.inclusion_proof_for_version(version, &proof);
    if (status != core::Status::kOk) {
        return status;
    }

    F5PatchReceipt receipt{};
    receipt.version = version;
    receipt.leaf_index = proof.leaf_index;
    receipt.patch_id = default_patch_id_from_version(version);
    receipt.patch_sha256_hex = to_hex_lower(proof.leaf_hash.data(), proof.leaf_hash.size());
    receipt.merkle_root_hex = to_hex_lower(chain.merkle_root().data(), chain.merkle_root().size());
    *out_receipt = std::move(receipt);
    return core::Status::kOk;
}

}  // namespace innovation
}  // namespace aether
