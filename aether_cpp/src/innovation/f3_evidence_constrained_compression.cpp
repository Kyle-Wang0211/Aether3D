// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/innovation/f3_evidence_constrained_compression.h"

#include "aether/crypto/sha256.h"
#include "aether/evidence/deterministic_json.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <vector>

namespace aether {
namespace innovation {
namespace {

inline float clampf(float value, float low, float high) {
    return std::max(low, std::min(value, high));
}

inline std::uint32_t clampu32(std::uint32_t value, std::uint32_t low, std::uint32_t high) {
    return std::max(low, std::min(value, high));
}

std::uint32_t saturating_sub(std::uint32_t value, std::uint32_t amount) {
    return (value > amount) ? (value - amount) : 0u;
}

std::size_t estimate_bytes_per_gaussian(std::uint32_t sh_coeff_count) {
    return 4u + 8u + 2u + 2u + 4u + 1u + 1u + 2u * 3u + 2u * 3u + 2u + static_cast<std::size_t>(sh_coeff_count);
}

F3EvidenceTier tier_from_belief(double belief, const F3PlanConfig& config) {
    if (belief < config.preserve_threshold) {
        return F3EvidenceTier::kPreserve;
    }
    if (belief >= config.aggressive_threshold) {
        return F3EvidenceTier::kAggressive;
    }
    return F3EvidenceTier::kBalanced;
}

int tier_priority(F3EvidenceTier tier) {
    switch (tier) {
        case F3EvidenceTier::kPreserve:
            return 2;
        case F3EvidenceTier::kBalanced:
            return 1;
        case F3EvidenceTier::kAggressive:
            return 0;
    }
    return 0;
}

const char* tier_name(F3EvidenceTier tier) {
    switch (tier) {
        case F3EvidenceTier::kPreserve:
            return "preserve";
        case F3EvidenceTier::kBalanced:
            return "balanced";
        case F3EvidenceTier::kAggressive:
            return "aggressive";
    }
    return "balanced";
}

struct BeliefLookup {
    std::uint64_t unit_id{0};
    std::string patch_id{};
    double belief{0.5};
};

double quantile_sorted(const std::vector<double>& sorted_values, double q) {
    if (sorted_values.empty()) {
        return 0.5;
    }
    const double clamped_q = std::max(0.0, std::min(1.0, q));
    const double idx = clamped_q * static_cast<double>(sorted_values.size() - 1u);
    const std::size_t lo = static_cast<std::size_t>(std::floor(idx));
    const std::size_t hi = static_cast<std::size_t>(std::ceil(idx));
    if (lo == hi) {
        return sorted_values[lo];
    }
    const double t = idx - static_cast<double>(lo);
    return sorted_values[lo] * (1.0 - t) + sorted_values[hi] * t;
}

double lookup_belief_by_unit(const std::vector<BeliefLookup>& lookups, std::uint64_t unit_id) {
    if (unit_id == 0u) {
        return 0.5;
    }
    std::size_t left = 0u;
    std::size_t right = lookups.size();
    while (left < right) {
        const std::size_t mid = left + (right - left) / 2u;
        if (lookups[mid].unit_id < unit_id) {
            left = mid + 1u;
        } else {
            right = mid;
        }
    }
    while (left < lookups.size()) {
        if (lookups[left].unit_id != unit_id) {
            break;
        }
        if (lookups[left].unit_id == unit_id) {
            return lookups[left].belief;
        }
        left += 1u;
    }
    return 0.5;
}

double lookup_belief_by_patch(
    const std::vector<BeliefLookup>& lookups,
    const std::string& patch_id) {
    if (patch_id.empty()) {
        return 0.5;
    }
    for (const auto& item : lookups) {
        if (!item.patch_id.empty() && item.patch_id == patch_id) {
            return item.belief;
        }
    }
    return 0.5;
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

core::Status build_binding_artifacts(
    const GaussianPrimitive* gaussians,
    std::size_t gaussian_count,
    const F3CompressionPlan& plan,
    const F3PlanConfig& plan_config,
    std::string* out_json,
    std::string* out_sha) {
    if (gaussians == nullptr || out_json == nullptr || out_sha == nullptr) {
        return core::Status::kInvalidArgument;
    }

    std::vector<std::uint8_t> digest_input;
    digest_input.reserve(plan.decisions.size() * 10u);
    for (const auto& d : plan.decisions) {
        if (d.gaussian_index >= gaussian_count) {
            return core::Status::kOutOfRange;
        }
        append_u32(digest_input, gaussians[d.gaussian_index].id);
        append_u32(digest_input, d.gaussian_id);
        digest_input.push_back(d.keep ? 1u : 0u);
        digest_input.push_back(static_cast<std::uint8_t>(d.tier));
        append_u16(digest_input, gaussians[d.gaussian_index].patch_priority);
        append_u16(digest_input, gaussians[d.gaussian_index].observation_count);
        append_u16(digest_input, d.target_quant_bits);
    }

    crypto::Sha256Digest decision_digest{};
    crypto::sha256(digest_input.data(), digest_input.size(), decision_digest);
    const std::string decision_digest_hex = to_hex_lower(decision_digest.bytes, sizeof(decision_digest.bytes));

    using evidence::CanonicalJsonValue;
    std::vector<CanonicalJsonValue> units_json;
    units_json.reserve(plan.unit_summaries.size());
    for (const auto& u : plan.unit_summaries) {
        std::vector<std::pair<std::string, CanonicalJsonValue>> unit_obj;
        unit_obj.emplace_back("belief", CanonicalJsonValue::make_number_quantized(u.belief, 6));
        unit_obj.emplace_back("kept_count", CanonicalJsonValue::make_int(static_cast<std::int64_t>(u.kept_count)));
        unit_obj.emplace_back("tier", CanonicalJsonValue::make_string(tier_name(u.tier)));
        unit_obj.emplace_back("total_count", CanonicalJsonValue::make_int(static_cast<std::int64_t>(u.total_count)));
        unit_obj.emplace_back("unit_id", CanonicalJsonValue::make_int(static_cast<std::int64_t>(u.unit_id)));
        units_json.push_back(CanonicalJsonValue::make_object(std::move(unit_obj)));
    }

    std::vector<std::pair<std::string, CanonicalJsonValue>> root_obj;
    root_obj.emplace_back("decision_digest_sha256", CanonicalJsonValue::make_string(decision_digest_hex));
    root_obj.emplace_back("estimated_bytes", CanonicalJsonValue::make_int(static_cast<std::int64_t>(plan.estimated_bytes)));
    root_obj.emplace_back(
        "hash_mode",
        CanonicalJsonValue::make_string(
            plan_config.coverage_binding_hash_pre_compression ? "pre_compression_leaf_hash" : "post_compression_leaf_hash"));
    root_obj.emplace_back("kept_count", CanonicalJsonValue::make_int(static_cast<std::int64_t>(plan.kept_count)));
    root_obj.emplace_back("schema", CanonicalJsonValue::make_string("aether.f3.coverage_binding.v1"));
    root_obj.emplace_back("total_count", CanonicalJsonValue::make_int(static_cast<std::int64_t>(gaussian_count)));
    root_obj.emplace_back("units", CanonicalJsonValue::make_array(std::move(units_json)));

    const CanonicalJsonValue root = CanonicalJsonValue::make_object(std::move(root_obj));
    core::Status status = evidence::encode_canonical_json(root, *out_json);
    if (status != core::Status::kOk) {
        return status;
    }
    status = evidence::canonical_json_sha256_hex(root, *out_sha);
    return status;
}

}  // namespace

core::Status f3_budget_from_belief(
    double belief,
    const F3PlanConfig& plan_config,
    F3BeliefBudgetMapping* out_mapping) {
    if (out_mapping == nullptr) {
        return core::Status::kInvalidArgument;
    }
    if (!(plan_config.preserve_threshold >= 0.0 &&
          plan_config.preserve_threshold < plan_config.aggressive_threshold &&
          plan_config.aggressive_threshold <= 1.0)) {
        return core::Status::kInvalidArgument;
    }
    const double clamped_belief = std::max(0.0, std::min(1.0, belief));
    F3BeliefBudgetMapping mapping{};
    mapping.tier = tier_from_belief(clamped_belief, plan_config);
    switch (mapping.tier) {
        case F3EvidenceTier::kPreserve:
            mapping.target_quant_bits = std::max<std::uint16_t>(plan_config.preserve_quant_bits, 1u);
            mapping.storage_ratio = 1.0;
            break;
        case F3EvidenceTier::kBalanced:
            mapping.target_quant_bits = std::max<std::uint16_t>(plan_config.balanced_quant_bits, 1u);
            mapping.storage_ratio = static_cast<double>(mapping.target_quant_bits) /
                static_cast<double>(std::max<std::uint16_t>(plan_config.preserve_quant_bits, 1u));
            break;
        case F3EvidenceTier::kAggressive:
            mapping.target_quant_bits = std::max<std::uint16_t>(plan_config.aggressive_quant_bits, 1u);
            mapping.storage_ratio = static_cast<double>(mapping.target_quant_bits) /
                static_cast<double>(std::max<std::uint16_t>(plan_config.preserve_quant_bits, 1u));
            break;
    }
    mapping.storage_ratio = std::max(0.05, std::min(1.0, mapping.storage_ratio));
    *out_mapping = mapping;
    return core::Status::kOk;
}

core::Status f3_plan_evidence_constrained_compression(
    const GaussianPrimitive* gaussians,
    std::size_t gaussian_count,
    const F3BeliefRecord* belief_records,
    std::size_t belief_count,
    const ScaffoldPatchMap* patch_map,
    const ProgressiveCompressionConfig& base_config,
    const F3PlanConfig& plan_config,
    F3CompressionPlan* out_plan) {
    if (out_plan == nullptr) {
        return core::Status::kInvalidArgument;
    }
    if (gaussian_count > 0u && gaussians == nullptr) {
        return core::Status::kInvalidArgument;
    }
    if (belief_count > 0u && belief_records == nullptr) {
        return core::Status::kInvalidArgument;
    }
    if (gaussian_count == 0u) {
        out_plan->decisions.clear();
        out_plan->unit_summaries.clear();
        out_plan->kept_count = 0u;
        out_plan->estimated_bytes = 0u;
        out_plan->coverage_binding_json.clear();
        out_plan->coverage_binding_sha256_hex.clear();
        return core::Status::kOutOfRange;
    }
    if (!(plan_config.preserve_threshold >= 0.0 && plan_config.preserve_threshold < plan_config.aggressive_threshold &&
          plan_config.aggressive_threshold <= 1.0) ||
        !(plan_config.score_weight_opacity >= 0.0f &&
          plan_config.score_weight_observation >= 0.0f &&
          plan_config.score_weight_certainty >= 0.0f) ||
        (plan_config.score_weight_opacity +
         plan_config.score_weight_observation +
         plan_config.score_weight_certainty <= 0.0f) ||
        !(plan_config.adaptive_threshold_blend >= 0.0 &&
          plan_config.adaptive_threshold_blend <= 1.0) ||
        !(plan_config.adaptive_threshold_min_gap >= 0.0 &&
          plan_config.adaptive_threshold_min_gap <= 1.0) ||
        !(plan_config.aggressive_quant_reduction_scale >= 0.0f) ||
        !(plan_config.quant_ratio_reduction_scale >= 0.0f) ||
        !(plan_config.aggressive_sh_reduction_scale >= 0.0f)) {
        return core::Status::kInvalidArgument;
    }

    std::vector<BeliefLookup> belief_lookup;
    belief_lookup.reserve(belief_count);
    for (std::size_t i = 0u; i < belief_count; ++i) {
        BeliefLookup item{};
        item.unit_id = belief_records[i].unit_id;
        item.patch_id = belief_records[i].patch_id;
        item.belief = clampf(static_cast<float>(belief_records[i].mass.occupied), 0.0f, 1.0f);
        belief_lookup.push_back(item);
    }
    std::sort(belief_lookup.begin(), belief_lookup.end(), [](const BeliefLookup& lhs, const BeliefLookup& rhs) {
        if (lhs.unit_id != rhs.unit_id) {
            return lhs.unit_id < rhs.unit_id;
        }
        return lhs.patch_id < rhs.patch_id;
    });
    belief_lookup.erase(std::unique(belief_lookup.begin(), belief_lookup.end(), [](const BeliefLookup& lhs, const BeliefLookup& rhs) {
        return lhs.unit_id == rhs.unit_id && lhs.patch_id == rhs.patch_id;
    }), belief_lookup.end());

    std::vector<F3GaussianDecision> decisions(gaussian_count);
    std::vector<std::uint8_t> mandatory(gaussian_count, 0u);
    double preserve_threshold = plan_config.preserve_threshold;
    double aggressive_threshold = plan_config.aggressive_threshold;
    if (belief_lookup.size() >= static_cast<std::size_t>(plan_config.adaptive_threshold_min_samples)) {
        std::vector<double> belief_values;
        belief_values.reserve(belief_lookup.size());
        for (const auto& b : belief_lookup) {
            belief_values.push_back(std::max(0.0, std::min(1.0, b.belief)));
        }
        std::sort(belief_values.begin(), belief_values.end());
        const double p25 = quantile_sorted(belief_values, 0.25);
        const double p75 = quantile_sorted(belief_values, 0.75);
        const double blend = plan_config.adaptive_threshold_blend;
        preserve_threshold = (1.0 - blend) * preserve_threshold + blend * p25;
        aggressive_threshold = (1.0 - blend) * aggressive_threshold + blend * p75;
        if (aggressive_threshold <= preserve_threshold + plan_config.adaptive_threshold_min_gap) {
            aggressive_threshold = std::min(1.0, preserve_threshold + plan_config.adaptive_threshold_min_gap);
        }
    }

    for (std::size_t i = 0u; i < gaussian_count; ++i) {
        F3GaussianDecision d{};
        d.gaussian_index = static_cast<std::uint32_t>(i);
        d.gaussian_id = gaussians[i].id;
        d.patch_id = gaussians[i].patch_id;
        if (d.patch_id.empty() && patch_map != nullptr && gaussians[i].host_unit_id != 0u) {
            (void)patch_map->patch_id_for_unit(gaussians[i].host_unit_id, &d.patch_id);
        }
        d.belief = lookup_belief_by_unit(belief_lookup, gaussians[i].host_unit_id);
        if (d.belief == 0.5 && !d.patch_id.empty()) {
            d.belief = lookup_belief_by_patch(belief_lookup, d.patch_id);
        }
        if (d.belief < preserve_threshold) {
            d.tier = F3EvidenceTier::kPreserve;
        } else if (d.belief >= aggressive_threshold) {
            d.tier = F3EvidenceTier::kAggressive;
        } else {
            d.tier = F3EvidenceTier::kBalanced;
        }
        F3BeliefBudgetMapping mapping{};
        core::Status budget_status = f3_budget_from_belief(d.belief, plan_config, &mapping);
        if (budget_status != core::Status::kOk) {
            return budget_status;
        }
        const double belief_t = (aggressive_threshold > preserve_threshold)
            ? std::max(0.0, std::min(1.0, (d.belief - preserve_threshold) / (aggressive_threshold - preserve_threshold)))
            : 0.0;
        const double smooth_t = belief_t * belief_t * (3.0 - 2.0 * belief_t);
        const double bits_hi = static_cast<double>(std::max<std::uint16_t>(plan_config.preserve_quant_bits, 1u));
        const double bits_lo = static_cast<double>(std::max<std::uint16_t>(plan_config.aggressive_quant_bits, 1u));
        const double soft_bits = bits_hi + (bits_lo - bits_hi) * smooth_t;
        d.target_quant_bits = static_cast<std::uint16_t>(std::max<double>(
            1.0,
            std::round(soft_bits)));
        if (d.tier == F3EvidenceTier::kBalanced) {
            d.target_quant_bits = static_cast<std::uint16_t>(std::min<std::uint16_t>(
                d.target_quant_bits,
                std::max<std::uint16_t>(mapping.target_quant_bits, 1u)));
        }

        const float opacity = clampf(gaussians[i].opacity, 0.0f, 1.0f);
        const float obs_norm = clampf(static_cast<float>(gaussians[i].observation_count) / 20.0f, 0.0f, 1.0f);
        const float certainty = 1.0f - clampf(gaussians[i].uncertainty, 0.0f, 1.0f);

        float tier_weight = 1.0f;
        if (d.tier == F3EvidenceTier::kPreserve) {
            tier_weight = 1.25f;
        } else if (d.tier == F3EvidenceTier::kAggressive) {
            tier_weight = 0.65f;
        }
        const float weight_sum = std::max(
            1e-6f,
            plan_config.score_weight_opacity +
                plan_config.score_weight_observation +
                plan_config.score_weight_certainty);
        const float weighted_score =
            (plan_config.score_weight_opacity * opacity +
             plan_config.score_weight_observation * obs_norm +
             plan_config.score_weight_certainty * certainty) /
            weight_sum;
        const float patch_boost = plan_config.patch_priority_boost *
            clampf(static_cast<float>(gaussians[i].patch_priority) / 8.0f, 0.0f, 1.0f);
        d.score = tier_weight * weighted_score + patch_boost;

        const bool must_keep =
            d.tier == F3EvidenceTier::kPreserve ||
            gaussians[i].observation_count < plan_config.min_observation_keep;
        mandatory[i] = must_keep ? 1u : 0u;
        decisions[i] = d;
    }

    const std::size_t bytes_per_gaussian = estimate_bytes_per_gaussian(base_config.sh_coeff_count);
    std::size_t capacity = gaussian_count;
    if (plan_config.target_byte_budget > 0u) {
        capacity = plan_config.target_byte_budget / std::max<std::size_t>(bytes_per_gaussian, 1u);
        capacity = std::max<std::size_t>(capacity, 1u);
        capacity = std::min<std::size_t>(capacity, gaussian_count);
    }

    std::size_t kept = 0u;
    for (std::size_t i = 0u; i < gaussian_count; ++i) {
        if (mandatory[i] != 0u) {
            decisions[i].keep = true;
            kept++;
        }
    }
    if (kept > capacity) {
        capacity = kept;
    }

    std::vector<std::size_t> rank;
    rank.reserve(gaussian_count);
    for (std::size_t i = 0u; i < gaussian_count; ++i) {
        if (decisions[i].keep) {
            continue;
        }
        rank.push_back(i);
    }

    std::sort(rank.begin(), rank.end(), [&](std::size_t lhs, std::size_t rhs) {
        const auto& dl = decisions[lhs];
        const auto& dr = decisions[rhs];
        const int lp = tier_priority(dl.tier);
        const int rp = tier_priority(dr.tier);
        if (lp != rp) {
            return lp > rp;
        }
        const float utility_l = dl.score / static_cast<float>(std::max<std::uint16_t>(dl.target_quant_bits, 1u));
        const float utility_r = dr.score / static_cast<float>(std::max<std::uint16_t>(dr.target_quant_bits, 1u));
        if (utility_l != utility_r) {
            return utility_l > utility_r;
        }
        if (dl.score != dr.score) {
            return dl.score > dr.score;
        }
        const auto& gl = gaussians[lhs];
        const auto& gr = gaussians[rhs];
        if (gl.patch_priority != gr.patch_priority) {
            return gl.patch_priority > gr.patch_priority;
        }
        if (gl.capture_sequence != gr.capture_sequence) {
            return gl.capture_sequence < gr.capture_sequence;
        }
        if (gl.id != gr.id) {
            return gl.id < gr.id;
        }
        return lhs < rhs;
    });

    for (std::size_t idx : rank) {
        if (kept >= capacity) {
            break;
        }
        decisions[idx].keep = true;
        kept++;
    }

    ProgressiveCompressionConfig adapted = base_config;
    std::size_t aggressive_kept = 0u;
    std::size_t preserve_kept = 0u;
    for (const auto& d : decisions) {
        if (!d.keep) {
            continue;
        }
        if (d.tier == F3EvidenceTier::kAggressive) {
            aggressive_kept++;
        } else if (d.tier == F3EvidenceTier::kPreserve) {
            preserve_kept++;
        }
    }

    if (kept > 0u) {
        const float aggressive_ratio = static_cast<float>(aggressive_kept) / static_cast<float>(kept);
        const float preserve_ratio = static_cast<float>(preserve_kept) / static_cast<float>(kept);
        std::uint32_t reduction = static_cast<std::uint32_t>(
            std::floor(aggressive_ratio * plan_config.aggressive_quant_reduction_scale));
        if (preserve_ratio > 0.40f && reduction > 0u) {
            reduction -= 1u;
        }

        std::uint64_t quant_sum = 0u;
        std::size_t quant_count = 0u;
        for (const auto& d : decisions) {
            if (!d.keep) {
                continue;
            }
            quant_sum += static_cast<std::uint64_t>(d.target_quant_bits);
            quant_count += 1u;
        }
        const float quant_ratio = (quant_count > 0u && plan_config.preserve_quant_bits > 0u)
            ? static_cast<float>(quant_sum) / static_cast<float>(quant_count * plan_config.preserve_quant_bits)
            : 1.0f;
        if (quant_ratio < 1.0f) {
            const std::uint32_t mapped_reduction = static_cast<std::uint32_t>(
                std::floor((1.0f - quant_ratio) * plan_config.quant_ratio_reduction_scale));
            reduction = std::max(reduction, mapped_reduction);
        }

        adapted.quant_bits_position = std::max<std::uint32_t>(
            10u, saturating_sub(base_config.quant_bits_position, reduction));
        adapted.quant_bits_scale = std::max<std::uint32_t>(
            10u, saturating_sub(base_config.quant_bits_scale, reduction));
        adapted.quant_bits_opacity = std::max<std::uint32_t>(
            6u, saturating_sub(base_config.quant_bits_opacity, clampu32(reduction, 0u, 2u)));
        adapted.quant_bits_uncertainty = std::max<std::uint32_t>(
            8u, saturating_sub(base_config.quant_bits_uncertainty, clampu32(reduction, 0u, 2u)));
        const std::uint32_t sh_reduction = clampu32(
            static_cast<std::uint32_t>(
                std::floor(aggressive_ratio * plan_config.aggressive_sh_reduction_scale)),
            0u,
            3u);
        adapted.sh_coeff_count = std::max<std::uint32_t>(4u, saturating_sub(base_config.sh_coeff_count, sh_reduction));
        if (preserve_ratio > 0.40f && adapted.sh_coeff_count < base_config.sh_coeff_count) {
            adapted.sh_coeff_count += 1u;
        }
    }

    std::vector<F3UnitSummary> summaries;
    summaries.reserve(gaussian_count);
    for (const auto& d : decisions) {
        const std::uint64_t unit_id = gaussians[d.gaussian_index].host_unit_id;
        auto it = std::lower_bound(summaries.begin(), summaries.end(), unit_id, [](const F3UnitSummary& lhs, std::uint64_t rhs_id) {
            return lhs.unit_id < rhs_id;
        });
        if (it == summaries.end() || it->unit_id != unit_id) {
            F3UnitSummary s{};
            s.unit_id = unit_id;
            s.tier = d.tier;
            s.belief = d.belief;
            s.total_count = 0u;
            s.kept_count = 0u;
            it = summaries.insert(it, s);
        }
        it->total_count += 1u;
        if (d.keep) {
            it->kept_count += 1u;
        }
    }

    F3CompressionPlan plan{};
    plan.decisions = std::move(decisions);
    plan.unit_summaries = std::move(summaries);
    plan.adapted_config = adapted;
    plan.kept_count = kept;
    plan.estimated_bytes = kept * estimate_bytes_per_gaussian(adapted.sh_coeff_count);
    plan.coverage_binding_hash_mode =
        plan_config.coverage_binding_hash_pre_compression
            ? "pre_compression_leaf_hash"
            : "post_compression_leaf_hash";

    core::Status status = build_binding_artifacts(
        gaussians,
        gaussian_count,
        plan,
        plan_config,
        &plan.coverage_binding_json,
        &plan.coverage_binding_sha256_hex);
    if (status != core::Status::kOk) {
        return status;
    }

    *out_plan = std::move(plan);
    return core::Status::kOk;
}

core::Status f3_extract_kept_gaussians(
    const GaussianPrimitive* gaussians,
    std::size_t gaussian_count,
    const F3CompressionPlan& plan,
    std::vector<GaussianPrimitive>* out_kept_gaussians) {
    if (out_kept_gaussians == nullptr) {
        return core::Status::kInvalidArgument;
    }
    if (gaussian_count > 0u && gaussians == nullptr) {
        return core::Status::kInvalidArgument;
    }

    std::vector<std::uint8_t> keep_mask(gaussian_count, 0u);
    for (const auto& decision : plan.decisions) {
        if (decision.gaussian_index >= gaussian_count) {
            return core::Status::kOutOfRange;
        }
        if (decision.keep) {
            keep_mask[decision.gaussian_index] = 1u;
        }
    }

    out_kept_gaussians->clear();
    out_kept_gaussians->reserve(plan.kept_count);
    for (std::size_t i = 0u; i < gaussian_count; ++i) {
        if (keep_mask[i] != 0u) {
            out_kept_gaussians->push_back(gaussians[i]);
        }
    }

    return core::Status::kOk;
}

}  // namespace innovation
}  // namespace aether
