// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/evidence/evidence_state_machine.h"

#include <algorithm>
#include <cmath>

namespace aether {
namespace evidence {

namespace {

double safe01(double v) {
    return std::isfinite(v) ? std::max(0.0, std::min(1.0, v)) : 0.0;
}

}  // namespace

// ═══════════════════════════════════════════════════════════════════
// Choquet Integral — non-additive aggregation of 5 super-dimensions
// ═══════════════════════════════════════════════════════════════════

ChoquetFuzzyMeasure ChoquetFuzzyMeasure::default_measure() {
    ChoquetFuzzyMeasure m{};
    // ── Singletons ──
    m.mu[0b00001] = 0.25;  // D_geo alone
    m.mu[0b00010] = 0.30;  // D_view alone (most important)
    m.mu[0b00100] = 0.15;  // D_semantic alone
    m.mu[0b01000] = 0.10;  // D_provenance alone
    m.mu[0b10000] = 0.15;  // D_tracker alone

    // ── Pairs (synergy: geo+view > sum of parts) ──
    m.mu[0b00011] = 0.65;  // D_geo + D_view: strong synergy
    m.mu[0b00101] = 0.42;  // D_geo + D_semantic
    m.mu[0b00110] = 0.48;  // D_view + D_semantic
    m.mu[0b01010] = 0.42;  // D_view + D_provenance
    m.mu[0b10010] = 0.48;  // D_view + D_tracker
    m.mu[0b01001] = 0.35;  // D_geo + D_provenance
    m.mu[0b10001] = 0.42;  // D_geo + D_tracker
    m.mu[0b01100] = 0.25;  // D_semantic + D_provenance: redundancy
    m.mu[0b10100] = 0.32;  // D_semantic + D_tracker
    m.mu[0b11000] = 0.25;  // D_provenance + D_tracker: redundancy

    // ── Triples ──
    m.mu[0b00111] = 0.75;  // D_geo + D_view + D_semantic
    m.mu[0b01011] = 0.72;  // D_geo + D_view + D_provenance
    m.mu[0b10011] = 0.75;  // D_geo + D_view + D_tracker
    m.mu[0b01110] = 0.62;  // D_view + D_semantic + D_provenance
    m.mu[0b10110] = 0.65;  // D_view + D_semantic + D_tracker
    m.mu[0b11010] = 0.62;  // D_view + D_provenance + D_tracker
    m.mu[0b01101] = 0.55;  // D_geo + D_semantic + D_provenance
    m.mu[0b10101] = 0.58;  // D_geo + D_semantic + D_tracker
    m.mu[0b11001] = 0.55;  // D_geo + D_provenance + D_tracker
    m.mu[0b11100] = 0.48;  // D_semantic + D_provenance + D_tracker

    // ── Quadruples ──
    m.mu[0b01111] = 0.88;  // all except D_tracker
    m.mu[0b10111] = 0.90;  // all except D_provenance
    m.mu[0b11011] = 0.88;  // all except D_semantic
    m.mu[0b11101] = 0.82;  // all except D_view
    m.mu[0b11110] = 0.78;  // all except D_geo

    // ── Full set ──
    m.mu[0b11111] = 1.00;
    m.mu[0] = 0.0;  // empty set

    return m;
}

ChoquetResult choquet_aggregate_5(
    const double dim_scores[10],
    const ChoquetFuzzyMeasure& mu) {

    ChoquetResult result{};

    // Step 1: 10 raw dimensions → 5 super-dimensions
    // D_geo  = max(geometryGain[1], depthQuality[2])
    result.super_dims[0] = std::max(safe01(dim_scores[1]), safe01(dim_scores[2]));
    // D_view = min(viewGain[0], viewDiversity[9])  — bottleneck
    result.super_dims[1] = std::min(safe01(dim_scores[0]), safe01(dim_scores[9]));
    // D_semantic = mean(semanticConsistency[3], errorTypeScore[4])
    result.super_dims[2] = (safe01(dim_scores[3]) + safe01(dim_scores[4])) / 2.0;
    // D_provenance = mean(provenanceContribution[6], basicGain[5])
    result.super_dims[3] = (safe01(dim_scores[6]) + safe01(dim_scores[5])) / 2.0;
    // D_tracker = min(coverageTrackerScore[7], resolutionQuality[8])
    result.super_dims[4] = std::min(safe01(dim_scores[7]), safe01(dim_scores[8]));

    // Step 2: Sort permutation ascending by super-dimension value
    int perm[5] = {0, 1, 2, 3, 4};
    for (int i = 0; i < 4; ++i) {
        for (int j = i + 1; j < 5; ++j) {
            if (result.super_dims[perm[i]] > result.super_dims[perm[j]]) {
                int tmp = perm[i];
                perm[i] = perm[j];
                perm[j] = tmp;
            }
        }
    }

    // Step 3: Choquet integral = sum_i delta_i * mu(A_i)
    // where A_i = {perm[i], ..., perm[4]} and delta_i = x_{perm[i]} - x_{perm[i-1]}
    double choquet = 0.0;
    for (int i = 0; i < 5; ++i) {
        std::uint32_t coalition = 0;
        for (int j = i; j < 5; ++j) {
            coalition |= (1u << perm[j]);
        }
        double delta = result.super_dims[perm[i]];
        if (i > 0) {
            delta -= result.super_dims[perm[i - 1]];
        }
        choquet += delta * mu.mu[coalition];
    }
    result.aggregated = std::max(0.0, std::min(1.0, choquet));

    // Reference: simple weighted average for synergy comparison
    const double w[5] = {0.25, 0.30, 0.15, 0.10, 0.15};
    result.additive = 0.0;
    for (int i = 0; i < 5; ++i) {
        result.additive += w[i] * result.super_dims[i];
    }
    result.synergy_bonus = result.aggregated - result.additive;

    return result;
}

// ═══════════════════════════════════════════════════════════════════
// Evidence State Machine
// ═══════════════════════════════════════════════════════════════════

EvidenceStateMachine::EvidenceStateMachine(EvidenceStateMachineConfig config)
    : config_(config), choquet_mu_(ChoquetFuzzyMeasure::default_measure()) {
    // Clamp S0-S5 thresholds to [0,1] for safety.
    auto clamp01 = [](double v) { return std::max(0.0, std::min(1.0, v)); };
    config_.s0_to_s1_threshold     = clamp01(config_.s0_to_s1_threshold);
    config_.s1_to_s2_threshold     = clamp01(config_.s1_to_s2_threshold);
    config_.s2_to_s3_threshold     = clamp01(config_.s2_to_s3_threshold);
    config_.s3_to_s4_threshold     = clamp01(config_.s3_to_s4_threshold);
    config_.s4_to_s5_threshold     = clamp01(config_.s4_to_s5_threshold);
    config_.s5_min_choquet         = clamp01(config_.s5_min_choquet);
    config_.s5_min_dimension_score = clamp01(config_.s5_min_dimension_score);
    config_.s5_max_uncertainty_width = clamp01(config_.s5_max_uncertainty_width);
    config_.s5_min_high_obs_ratio  = clamp01(config_.s5_min_high_obs_ratio);
    // Lyapunov rate is not [0,1] bounded — it's a positive real.
    // Just ensure it's positive.
    if (!std::isfinite(config_.s5_max_lyapunov_rate) || config_.s5_max_lyapunov_rate < 0.0) {
        config_.s5_max_lyapunov_rate = 0.05;
    }
}

ColorState EvidenceStateMachine::compute_raw_state(
    const EvidenceStateMachineInput& input,
    EvidenceStateMachineResult& diag) const {

    const double bel_cov = safe01(input.coverage);
    const double pl_cov  = safe01(input.plausibility_coverage);
    const double unc_width = safe01(input.uncertainty_width);
    const double high_obs = safe01(input.high_observation_ratio);
    const double lyap_rate = std::isfinite(input.lyapunov_rate)
        ? input.lyapunov_rate : 999.0;

    // ── S5: 6-gate information-theoretic certification ──

    // Gate 1: DS Belief coverage (three-valued logic)
    if (bel_cov >= config_.s4_to_s5_threshold) {
        diag.coverage_cert = CertifiedState::kCertified;
    } else if (pl_cov >= config_.s4_to_s5_threshold) {
        diag.coverage_cert = CertifiedState::kUncertain;
    } else {
        diag.coverage_cert = CertifiedState::kImpossible;
    }

    // Gate 2: Choquet integral (non-additive multi-dimensional quality)
    const auto choquet = choquet_aggregate_5(input.dim_scores, choquet_mu_);
    diag.choquet_value = choquet.aggregated;
    diag.min_super_dim = 1.0;
    for (int i = 0; i < 5; ++i) {
        diag.min_super_dim = std::min(diag.min_super_dim, choquet.super_dims[i]);
    }

    if (choquet.aggregated >= config_.s5_min_choquet) {
        diag.choquet_cert = CertifiedState::kCertified;
    } else {
        diag.choquet_cert = CertifiedState::kUncertain;
    }

    // Gates 3-6: uncertainty width, L5+ ratio, convergence rate, min dimension
    const bool unc_ok  = unc_width <= config_.s5_max_uncertainty_width;
    const bool obs_ok  = high_obs >= config_.s5_min_high_obs_ratio;
    const bool conv_ok = lyap_rate <= config_.s5_max_lyapunov_rate;
    const bool dim_ok  = diag.min_super_dim >= config_.s5_min_dimension_score;

    // S5 certified: ALL 6 gates must pass
    const bool s5_certified =
        diag.coverage_cert == CertifiedState::kCertified &&
        diag.choquet_cert == CertifiedState::kCertified &&
        dim_ok && unc_ok && obs_ok && conv_ok;

    // Certification margin: minimum across all 6 gates.
    // Positive = all gates passed.  Negative = furthest gate from passing.
    double margins[6] = {
        bel_cov - config_.s4_to_s5_threshold,
        choquet.aggregated - config_.s5_min_choquet,
        diag.min_super_dim - config_.s5_min_dimension_score,
        config_.s5_max_uncertainty_width - unc_width,
        high_obs - config_.s5_min_high_obs_ratio,
        config_.s5_max_lyapunov_rate - lyap_rate
    };
    diag.certification_margin = margins[0];
    for (int i = 1; i < 6; ++i) {
        diag.certification_margin = std::min(diag.certification_margin, margins[i]);
    }

    if (s5_certified) {
        return ColorState::kOriginal;
    }

    // ── S4-S0: only Belief coverage (UNCHANGED) ──
    if (bel_cov >= config_.s3_to_s4_threshold) return ColorState::kWhite;
    if (bel_cov >= config_.s2_to_s3_threshold) return ColorState::kLightGray;
    if (bel_cov >= config_.s0_to_s1_threshold) return ColorState::kDarkGray;
    return ColorState::kBlack;
}

EvidenceStateMachineResult EvidenceStateMachine::evaluate(
    const EvidenceStateMachineInput& input) {
    EvidenceStateMachineResult result{};
    const ColorState raw = compute_raw_state(input, result);

    // Monotonic enforcement: state NEVER decreases.
    if (color_state_order(raw) > color_state_order(current_state_)) {
        result.previous_state = current_state_;
        previous_state_ = current_state_;
        current_state_ = raw;
        result.transitioned = true;
    } else {
        result.previous_state = previous_state_;
        result.transitioned = false;
    }

    result.state = current_state_;
    return result;
}

void EvidenceStateMachine::reset() {
    current_state_ = ColorState::kBlack;
    previous_state_ = ColorState::kBlack;
}

}  // namespace evidence
}  // namespace aether
