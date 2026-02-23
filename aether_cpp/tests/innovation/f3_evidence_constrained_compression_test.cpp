// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/innovation/f3_evidence_constrained_compression.h"

#include <cstdio>
#include <string>
#include <vector>

namespace {

std::vector<aether::innovation::GaussianPrimitive> make_gaussians() {
    using namespace aether::innovation;
    std::vector<GaussianPrimitive> out(6);
    for (std::size_t i = 0; i < out.size(); ++i) {
        out[i].id = static_cast<std::uint32_t>(100u + i);
        out[i].host_unit_id = 1001u + static_cast<std::uint64_t>(i % 4u);
        out[i].patch_id = "blk:" + std::to_string(static_cast<int>(i % 4u)) + "_0_0";
        out[i].opacity = 0.30f + 0.08f * static_cast<float>(i);
        out[i].observation_count = static_cast<std::uint16_t>(2u + i);
        out[i].patch_priority = 0u;
        out[i].capture_sequence = static_cast<std::uint32_t>(i);
        out[i].uncertainty = 0.1f + 0.1f * static_cast<float>(i);
    }
    out[0].host_unit_id = 1001u;
    out[1].host_unit_id = 1001u;
    out[2].host_unit_id = 1002u;
    out[3].host_unit_id = 1003u;
    out[4].host_unit_id = 1004u;
    out[5].host_unit_id = 1003u;
    out[0].observation_count = 1u;  // mandatory keep path.
    out[5].patch_priority = 3u;      // reshoot style boost.
    return out;
}

std::vector<aether::innovation::F3BeliefRecord> make_beliefs() {
    using namespace aether::innovation;
    using aether::evidence::DSMassFunction;

    std::vector<F3BeliefRecord> beliefs(4);
    beliefs[0].unit_id = 1001u;
    beliefs[0].patch_id = "blk:0_0_0";
    beliefs[0].mass = DSMassFunction(0.20, 0.20, 0.60);  // preserve
    beliefs[1].unit_id = 1002u;
    beliefs[1].patch_id = "blk:1_0_0";
    beliefs[1].mass = DSMassFunction(0.55, 0.20, 0.25);  // balanced
    beliefs[2].unit_id = 1003u;
    beliefs[2].patch_id = "blk:2_0_0";
    beliefs[2].mass = DSMassFunction(0.90, 0.05, 0.05);  // aggressive
    beliefs[3].unit_id = 1004u;
    beliefs[3].patch_id = "blk:3_0_0";
    beliefs[3].mass = DSMassFunction(0.85, 0.10, 0.05);  // aggressive
    return beliefs;
}

int test_belief_budget_mapping() {
    using namespace aether::innovation;
    int failed = 0;
    F3PlanConfig cfg{};
    cfg.preserve_threshold = 0.4;
    cfg.aggressive_threshold = 0.75;
    cfg.preserve_quant_bits = 16u;
    cfg.balanced_quant_bits = 12u;
    cfg.aggressive_quant_bits = 8u;

    F3BeliefBudgetMapping preserve{};
    F3BeliefBudgetMapping balanced{};
    F3BeliefBudgetMapping aggressive{};
    if (f3_budget_from_belief(0.2, cfg, &preserve) != aether::core::Status::kOk ||
        f3_budget_from_belief(0.6, cfg, &balanced) != aether::core::Status::kOk ||
        f3_budget_from_belief(0.9, cfg, &aggressive) != aether::core::Status::kOk) {
        std::fprintf(stderr, "f3_budget_from_belief failed\n");
        return 1;
    }
    if (!(preserve.target_quant_bits > balanced.target_quant_bits &&
          balanced.target_quant_bits > aggressive.target_quant_bits)) {
        std::fprintf(stderr, "budget mapping should monotonically reduce quant bits with higher belief\n");
        failed++;
    }
    return failed;
}

int test_plan_and_extract() {
    int failed = 0;
    using namespace aether::innovation;

    const auto gaussians = make_gaussians();
    const auto beliefs = make_beliefs();

    ProgressiveCompressionConfig base{};
    base.sh_coeff_count = 8u;
    base.quant_bits_position = 16u;
    base.quant_bits_scale = 16u;
    base.quant_bits_opacity = 8u;
    base.quant_bits_uncertainty = 12u;

    F3PlanConfig cfg{};
    cfg.target_byte_budget = 44u * 3u;
    cfg.preserve_threshold = 0.40;
    cfg.aggressive_threshold = 0.75;
    cfg.min_observation_keep = 2u;

    F3CompressionPlan plan{};
    const auto status = f3_plan_evidence_constrained_compression(
        gaussians.data(),
        gaussians.size(),
        beliefs.data(),
        beliefs.size(),
        nullptr,
        base,
        cfg,
        &plan);
    if (status != aether::core::Status::kOk) {
        std::fprintf(stderr, "f3 plan failed\n");
        return 1;
    }
    if (plan.kept_count == 0u || plan.kept_count > gaussians.size()) {
        std::fprintf(stderr, "invalid kept count\n");
        failed++;
    }
    if (plan.coverage_binding_json.empty() || plan.coverage_binding_sha256_hex.size() != 64u) {
        std::fprintf(stderr, "coverage binding artifact missing\n");
        failed++;
    }
    if (plan.adapted_config.quant_bits_position > base.quant_bits_position ||
        plan.adapted_config.quant_bits_scale > base.quant_bits_scale ||
        plan.adapted_config.sh_coeff_count > base.sh_coeff_count) {
        std::fprintf(stderr, "adapted config should not exceed base\n");
        failed++;
    }

    bool preserve_kept = false;
    bool aggressive_dropped = false;
    for (const auto& d : plan.decisions) {
        const std::uint64_t host = gaussians[d.gaussian_index].host_unit_id;
        if (host == 1001u && d.keep) {
            preserve_kept = true;
        }
        if ((host == 1003u || host == 1004u) && !d.keep) {
            aggressive_dropped = true;
        }
    }
    if (!preserve_kept) {
        std::fprintf(stderr, "low-belief preserve tier should keep redundancy\n");
        failed++;
    }
    if (!aggressive_dropped) {
        std::fprintf(stderr, "high-belief aggressive tier should allow drops\n");
        failed++;
    }

    F3CompressionPlan plan2{};
    if (f3_plan_evidence_constrained_compression(
            gaussians.data(),
            gaussians.size(),
            beliefs.data(),
            beliefs.size(),
            nullptr,
            base,
            cfg,
            &plan2) != aether::core::Status::kOk) {
        std::fprintf(stderr, "determinism second run failed\n");
        failed++;
    } else if (plan.coverage_binding_sha256_hex != plan2.coverage_binding_sha256_hex) {
        std::fprintf(stderr, "determinism hash mismatch\n");
        failed++;
    }

    std::vector<GaussianPrimitive> kept;
    if (f3_extract_kept_gaussians(
            gaussians.data(),
            gaussians.size(),
            plan,
            &kept) != aether::core::Status::kOk) {
        std::fprintf(stderr, "extract kept gaussians failed\n");
        failed++;
    } else if (kept.size() != plan.kept_count) {
        std::fprintf(stderr, "kept cloud size mismatch\n");
        failed++;
    }

    return failed;
}

int test_invalid_paths() {
    int failed = 0;
    using namespace aether::innovation;

    const auto gaussians = make_gaussians();
    const auto beliefs = make_beliefs();
    ProgressiveCompressionConfig base{};
    base.sh_coeff_count = 8u;

    F3PlanConfig bad_cfg{};
    bad_cfg.preserve_threshold = 0.8;
    bad_cfg.aggressive_threshold = 0.7;
    F3CompressionPlan plan{};
    if (f3_plan_evidence_constrained_compression(
            gaussians.data(),
            gaussians.size(),
            beliefs.data(),
            beliefs.size(),
            nullptr,
            base,
            bad_cfg,
            &plan) != aether::core::Status::kInvalidArgument) {
        std::fprintf(stderr, "invalid thresholds should fail\n");
        failed++;
    }

    if (f3_plan_evidence_constrained_compression(
            nullptr,
            gaussians.size(),
            beliefs.data(),
            beliefs.size(),
            nullptr,
            base,
            F3PlanConfig{},
            &plan) != aether::core::Status::kInvalidArgument) {
        std::fprintf(stderr, "null gaussian pointer should fail\n");
        failed++;
    }

    if (f3_extract_kept_gaussians(
            gaussians.data(),
            gaussians.size(),
            plan,
            nullptr) != aether::core::Status::kInvalidArgument) {
        std::fprintf(stderr, "null output vector should fail\n");
        failed++;
    }

    return failed;
}

}  // namespace

int main() {
    int failed = 0;
    failed += test_belief_budget_mapping();
    failed += test_plan_and_extract();
    failed += test_invalid_paths();
    return failed;
}
