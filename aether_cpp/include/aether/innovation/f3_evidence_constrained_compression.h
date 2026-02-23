// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_INNOVATION_F3_EVIDENCE_CONSTRAINED_COMPRESSION_H
#define AETHER_INNOVATION_F3_EVIDENCE_CONSTRAINED_COMPRESSION_H

#ifdef __cplusplus

#include "aether/core/status.h"
#include "aether/evidence/ds_mass_function.h"
#include "aether/innovation/f1_progressive_compression.h"
#include "aether/innovation/scaffold_patch_map.h"

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace aether {
namespace innovation {

enum class F3EvidenceTier : std::uint8_t {
    kPreserve = 0,
    kBalanced = 1,
    kAggressive = 2,
};

struct F3BeliefRecord {
    std::uint64_t unit_id{0};
    std::string patch_id{};
    evidence::DSMassFunction mass{};
};

struct F3PlanConfig {
    double preserve_threshold{0.4};
    double aggressive_threshold{0.75};
    std::size_t target_byte_budget{0};
    std::uint16_t min_observation_keep{2};
    float patch_priority_boost{0.15f};
    float score_weight_opacity{0.40f};
    float score_weight_observation{0.25f};
    float score_weight_certainty{0.35f};
    std::uint16_t adaptive_threshold_min_samples{8};
    double adaptive_threshold_blend{0.60};
    double adaptive_threshold_min_gap{0.12};
    std::uint16_t preserve_quant_bits{16};
    std::uint16_t balanced_quant_bits{12};
    std::uint16_t aggressive_quant_bits{8};
    float aggressive_quant_reduction_scale{4.5f};
    float quant_ratio_reduction_scale{6.5f};
    float aggressive_sh_reduction_scale{3.5f};
    bool coverage_binding_hash_pre_compression{true};
};

struct F3GaussianDecision {
    std::uint32_t gaussian_index{0};
    GaussianId gaussian_id{0};
    std::string patch_id{};
    F3EvidenceTier tier{F3EvidenceTier::kBalanced};
    bool keep{false};
    float score{0.0f};
    double belief{0.0};
    std::uint16_t target_quant_bits{0};
};

struct F3UnitSummary {
    std::uint64_t unit_id{0};
    F3EvidenceTier tier{F3EvidenceTier::kBalanced};
    double belief{0.0};
    std::uint32_t total_count{0};
    std::uint32_t kept_count{0};
};

struct F3CompressionPlan {
    std::vector<F3GaussianDecision> decisions{};
    std::vector<F3UnitSummary> unit_summaries{};
    ProgressiveCompressionConfig adapted_config{};
    std::size_t kept_count{0};
    std::size_t estimated_bytes{0};
    std::string coverage_binding_hash_mode{};
    std::string coverage_binding_json{};
    std::string coverage_binding_sha256_hex{};
};

struct F3BeliefBudgetMapping {
    F3EvidenceTier tier{F3EvidenceTier::kBalanced};
    std::uint16_t target_quant_bits{12};
    double storage_ratio{1.0};
};

core::Status f3_budget_from_belief(
    double belief,
    const F3PlanConfig& plan_config,
    F3BeliefBudgetMapping* out_mapping);

core::Status f3_plan_evidence_constrained_compression(
    const GaussianPrimitive* gaussians,
    std::size_t gaussian_count,
    const F3BeliefRecord* belief_records,
    std::size_t belief_count,
    const ScaffoldPatchMap* patch_map,
    const ProgressiveCompressionConfig& base_config,
    const F3PlanConfig& plan_config,
    F3CompressionPlan* out_plan);

core::Status f3_extract_kept_gaussians(
    const GaussianPrimitive* gaussians,
    std::size_t gaussian_count,
    const F3CompressionPlan& plan,
    std::vector<GaussianPrimitive>* out_kept_gaussians);

}  // namespace innovation
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_INNOVATION_F3_EVIDENCE_CONSTRAINED_COMPRESSION_H
