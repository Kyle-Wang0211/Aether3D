// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/innovation/f5_delta_patch_chain.h"

#include <cstdio>
#include <vector>

namespace {

aether::innovation::GaussianPrimitive make_gaussian(std::uint32_t id, std::uint64_t host_unit) {
    using namespace aether::innovation;
    GaussianPrimitive g{};
    g.id = id;
    g.host_unit_id = host_unit;
    g.opacity = 0.5f;
    g.capture_sequence = id;
    g.patch_priority = 0u;
    g.observation_count = 3u;
    return g;
}

aether::innovation::ScaffoldUnit make_unit(std::uint64_t unit_id, std::uint32_t a, std::uint32_t b, std::uint32_t c) {
    using namespace aether::innovation;
    ScaffoldUnit u{};
    u.unit_id = unit_id;
    u.v0 = a;
    u.v1 = b;
    u.v2 = c;
    u.area = 1.0f;
    u.confidence = 1.0f;
    u.view_count = 1u;
    return u;
}

int test_append_and_verify() {
    int failed = 0;
    using namespace aether::innovation;

    F5DeltaPatchChain chain{};

    F5DeltaPatch p1{};
    p1.parent_version = 0u;
    p1.timestamp_ms = 1000;
    F5PatchOperation p1_op0{};
    p1_op0.type = F5PatchOpType::kUpsertGaussian;
    p1_op0.gaussian = make_gaussian(1u, 10u);
    F5PatchOperation p1_op1{};
    p1_op1.type = F5PatchOpType::kUpsertScaffoldUnit;
    p1_op1.scaffold_unit = make_unit(10u, 0u, 1u, 2u);
    p1.operations = {p1_op0, p1_op1};

    F5PatchReceipt r1{};
    if (chain.append_patch(p1, &r1) != aether::core::Status::kOk) {
        std::fprintf(stderr, "append patch #1 failed\n");
        return 1;
    }
    if (r1.patch_id.empty()) {
        std::fprintf(stderr, "patch receipt should carry patch_id\n");
        failed++;
    }
    if (chain.patch_count() != 1u || chain.latest_version() != 1u) {
        std::fprintf(stderr, "version tracking mismatch after patch #1\n");
        failed++;
    }

    aether::merkle::InclusionProof proof1{};
    if (chain.inclusion_proof_for_version(1u, &proof1) != aether::core::Status::kOk) {
        std::fprintf(stderr, "proof #1 fetch failed\n");
        failed++;
    } else {
        bool valid = false;
        if (chain.verify_receipt(r1, proof1, &valid) != aether::core::Status::kOk || !valid) {
            std::fprintf(stderr, "receipt #1 verification failed\n");
            failed++;
        }
    }

    F5DeltaPatch p2{};
    p2.parent_version = 1u;
    p2.timestamp_ms = 1050;
    F5PatchOperation p2_op0{};
    p2_op0.type = F5PatchOpType::kUpsertGaussian;
    p2_op0.gaussian = make_gaussian(2u, 10u);
    F5PatchOperation p2_op1{};
    p2_op1.type = F5PatchOpType::kRemoveGaussian;
    p2_op1.gaussian_id = 1u;
    p2.operations = {p2_op0, p2_op1};

    F5PatchReceipt r2{};
    if (chain.append_patch(p2, &r2) != aether::core::Status::kOk) {
        std::fprintf(stderr, "append patch #2 failed\n");
        return failed + 1;
    }

    bool transition_valid = false;
    if (chain.verify_delta_transition(p2, &transition_valid) != aether::core::Status::kOk || !transition_valid) {
        std::fprintf(stderr, "delta transition verification failed\n");
        failed++;
    }

    std::vector<GaussianPrimitive> gaussians;
    std::vector<ScaffoldUnit> units;
    if (chain.materialize_scene(&gaussians, &units) != aether::core::Status::kOk) {
        std::fprintf(stderr, "materialize scene failed\n");
        failed++;
    } else {
        if (gaussians.size() != 1u || gaussians[0].id != 2u) {
            std::fprintf(stderr, "materialized gaussian state mismatch\n");
            failed++;
        }
        if (units.size() != 1u || units[0].unit_id != 10u) {
            std::fprintf(stderr, "materialized scaffold state mismatch\n");
            failed++;
        }
    }

    F5SceneSnapshot snapshot_v1{};
    if (chain.snapshot_for_version(1u, &snapshot_v1) != aether::core::Status::kOk) {
        std::fprintf(stderr, "snapshot_for_version failed\n");
        failed++;
    } else if (snapshot_v1.version != 1u || snapshot_v1.state_sha256_hex.size() != 64u) {
        std::fprintf(stderr, "snapshot_for_version payload mismatch\n");
        failed++;
    }

    aether::merkle::InclusionProof proof2{};
    if (chain.inclusion_proof_for_version(2u, &proof2) != aether::core::Status::kOk) {
        std::fprintf(stderr, "proof #2 fetch failed\n");
        failed++;
    } else {
        bool valid = false;
        if (chain.verify_receipt(r2, proof2, &valid) != aether::core::Status::kOk || !valid) {
            std::fprintf(stderr, "receipt #2 verification failed\n");
            failed++;
        }
    }

    return failed;
}

int test_deterministic_canonicalization() {
    int failed = 0;
    using namespace aether::innovation;

    F5DeltaPatch patch{};
    patch.parent_version = 0u;
    patch.timestamp_ms = 2000;
    F5PatchOperation op_a{};
    op_a.type = F5PatchOpType::kUpsertGaussian;
    op_a.gaussian = make_gaussian(5u, 20u);
    F5PatchOperation op_b{};
    op_b.type = F5PatchOpType::kUpsertScaffoldUnit;
    op_b.scaffold_unit = make_unit(20u, 1u, 2u, 3u);
    patch.operations = {op_b, op_a};  // intentionally out of canonical order.

    F5DeltaPatch patch_swapped = patch;
    patch_swapped.operations = {op_a, op_b};

    F5DeltaPatchChain chain_a{};
    F5DeltaPatchChain chain_b{};
    F5PatchReceipt ra{};
    F5PatchReceipt rb{};
    if (chain_a.append_patch(patch, &ra) != aether::core::Status::kOk ||
        chain_b.append_patch(patch_swapped, &rb) != aether::core::Status::kOk) {
        std::fprintf(stderr, "determinism append failed\n");
        return 1;
    }
    if (ra.patch_sha256_hex != rb.patch_sha256_hex || ra.merkle_root_hex != rb.merkle_root_hex) {
        std::fprintf(stderr, "canonicalization mismatch between equivalent patches\n");
        failed++;
    }
    return failed;
}

int test_invalid_paths() {
    int failed = 0;
    using namespace aether::innovation;

    F5DeltaPatchChain chain{};
    F5DeltaPatch bad_parent{};
    bad_parent.parent_version = 5u;
    bad_parent.timestamp_ms = 0;
    F5PatchOperation op{};
    op.type = F5PatchOpType::kUpsertGaussian;
    op.gaussian = make_gaussian(1u, 1u);
    bad_parent.operations = {op};
    if (chain.append_patch(bad_parent, nullptr) != aether::core::Status::kInvalidArgument) {
        std::fprintf(stderr, "bad parent version should fail\n");
        failed++;
    }

    F5DeltaPatch duplicate{};
    duplicate.parent_version = 0u;
    duplicate.timestamp_ms = 1;
    F5PatchOperation dup_a{};
    dup_a.type = F5PatchOpType::kUpsertGaussian;
    dup_a.gaussian = make_gaussian(7u, 1u);
    F5PatchOperation dup_b = dup_a;
    duplicate.operations = {dup_a, dup_b};
    if (chain.append_patch(duplicate, nullptr) != aether::core::Status::kInvalidArgument) {
        std::fprintf(stderr, "duplicate operation key should fail\n");
        failed++;
    }

    if (chain.inclusion_proof_for_version(1u, nullptr) != aether::core::Status::kInvalidArgument) {
        std::fprintf(stderr, "null proof output should fail\n");
        failed++;
    }

    bool valid = false;
    F5DeltaPatch unknown{};
    unknown.version = 99u;
    if (chain.verify_delta_transition(unknown, &valid) != aether::core::Status::kOutOfRange) {
        std::fprintf(stderr, "unknown version delta verification should fail\n");
        failed++;
    }

    return failed;
}

}  // namespace

int main() {
    int failed = 0;
    failed += test_append_and_verify();
    failed += test_deterministic_canonicalization();
    failed += test_invalid_paths();
    return failed;
}
