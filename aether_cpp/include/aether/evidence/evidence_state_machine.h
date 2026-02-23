// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_EVIDENCE_EVIDENCE_STATE_MACHINE_H
#define AETHER_EVIDENCE_EVIDENCE_STATE_MACHINE_H

#include "aether/core/status.h"

#include <cstdint>

namespace aether {
namespace evidence {

/// Global scan color state — discrete summary of continuous coverage.
///
/// Maps 1:1 to the S0-S5 stages used in scan guidance:
///   S0 = kBlack        coverage < 0.10
///   S1 = kDarkGray     coverage >= 0.10
///   S2 = kDarkGray     coverage >= 0.25  (same visual as S1)
///   S3 = kLightGray    coverage >= 0.50
///   S4 = kWhite        coverage >= 0.75
///   S5 = kOriginal     6-gate information-theoretic certification
///
/// Note: PR7 uses continuous grayscale [0,1] for per-triangle color.
/// This enum provides the coarse global indicator for UI guidance,
/// haptic feedback, and state machine transitions.
enum class ColorState : std::uint8_t {
    kBlack     = 0,  // S0: no/minimal coverage
    kDarkGray  = 1,  // S1/S2: low-medium coverage
    kLightGray = 2,  // S3: medium-high coverage
    kWhite     = 3,  // S4: high coverage
    kOriginal  = 4,  // S5: capture complete (original color)
    kUnknown   = 255 // Forward compatibility sentinel
};

/// Integer ordering for monotonic comparison.
/// kUnknown maps to -1 (lowest), ensuring it never blocks transitions.
inline int color_state_order(ColorState state) {
    switch (state) {
        case ColorState::kBlack:     return 0;
        case ColorState::kDarkGray:  return 1;
        case ColorState::kLightGray: return 2;
        case ColorState::kWhite:     return 3;
        case ColorState::kOriginal:  return 4;
        case ColorState::kUnknown:   return -1;
    }
    return -1;
}

/// S5 certification state — three-valued logic from DS theory.
/// Bel >= tau  →  Certified  (proven to meet threshold)
/// Bel < tau <= Pl → Uncertain (cannot determine, need more data)
/// Pl < tau   →  Impossible (proven impossible to meet threshold)
enum class CertifiedState : std::uint8_t {
    kCertified  = 0,
    kUncertain  = 1,
    kImpossible = 2
};

// ── Choquet Integral for non-additive aggregation ──

/// 5 super-dimension fuzzy measure (2^5 = 32 values, bitmask-indexed).
/// Captures synergy (view+geometry together > sum of parts) and
/// redundancy (depth+resolution overlap → don't double-count).
struct ChoquetFuzzyMeasure {
    double mu[32]{};
    static ChoquetFuzzyMeasure default_measure();
};

/// Result of Choquet integral aggregation.
struct ChoquetResult {
    double aggregated{0.0};     // Choquet integral value [0,1]
    double additive{0.0};       // Reference: simple weighted average
    double synergy_bonus{0.0};  // aggregated - additive (synergy effect)
    double super_dims[5]{};     // 5 super-dimension values
};

/// Compute Choquet integral over 5 super-dimensions from 10 raw dimensions.
/// Pure function, no side effects.
///
/// Super-dimension grouping:
///   D_geo  = max(geometryGain, depthQuality)      — geometry quality
///   D_view = min(viewGain, viewDiversity)          — view completeness
///   D_semantic = mean(semanticConsistency, errorTypeScore) — semantic reliability
///   D_provenance = mean(provenanceContribution, basicGain)  — data provenance
///   D_tracker = min(coverageTrackerScore, resolutionQuality) — tracking precision
ChoquetResult choquet_aggregate_5(
    const double dim_scores[10],
    const ChoquetFuzzyMeasure& mu);

/// Configuration for the evidence state machine.
/// S0-S4 thresholds are UNCHANGED — only S5 uses information-theoretic gates.
struct EvidenceStateMachineConfig {
    // S0-S4 coverage thresholds (UNCHANGED)
    double s0_to_s1_threshold{0.10};  // coverage >= this → S1 (kDarkGray)
    double s1_to_s2_threshold{0.25};  // coverage >= this → S2 (kDarkGray)
    double s2_to_s3_threshold{0.50};  // coverage >= this → S3 (kLightGray)
    double s3_to_s4_threshold{0.75};  // coverage >= this → S4 (kWhite)
    double s4_to_s5_threshold{0.88};  // Bel(coverage) >= this → S5 gate 1

    // ── S5 information-theoretic gate thresholds ──
    double s5_min_choquet{0.72};             // Choquet integral >= this
    double s5_min_dimension_score{0.45};     // min(5 super-dims) >= this
    double s5_max_uncertainty_width{0.15};   // DS uncertainty Pl-Bel <= this
    double s5_min_high_obs_ratio{0.30};      // L5+ ratio >= this (CRLB proxy)
    double s5_max_lyapunov_rate{0.05};       // |dV/dt|/V <= this (convergence)
};

/// Input to a single evaluate() call.
struct EvidenceStateMachineInput {
    // ── Core signals from CoverageEstimator ──
    double coverage{0.0};                    // [0,1] DS Belief coverage (lower bound)
    double plausibility_coverage{0.0};       // [0,1] DS Plausibility (upper bound)
    double uncertainty_width{0.0};           // Pl - Bel (DS uncertainty interval)
    double high_observation_ratio{0.0};      // L5+ ratio (CRLB precision proxy)
    double lyapunov_rate{1.0};               // |dV/dt|/V convergence rate

    // ── 10 dimensional raw scores (Swift transparent passthrough) ──
    // Index: 0=viewGain, 1=geometryGain, 2=depthQuality,
    //        3=semanticConsistency, 4=errorTypeScore, 5=basicGain,
    //        6=provenanceContribution, 7=coverageTrackerScore,
    //        8=resolutionQuality, 9=viewDiversity
    double dim_scores[10]{};
};

/// Result of a single evaluate() call.
struct EvidenceStateMachineResult {
    ColorState state{ColorState::kBlack};
    ColorState previous_state{ColorState::kBlack};
    bool transitioned{false};    // true if state changed this call

    // ── Certification diagnostics ──
    CertifiedState coverage_cert{CertifiedState::kImpossible};
    CertifiedState choquet_cert{CertifiedState::kImpossible};
    double choquet_value{0.0};               // Actual Choquet integral value
    double min_super_dim{0.0};               // Minimum of 5 super-dimensions
    double certification_margin{0.0};        // Min margin across all 6 gates
                                             // (positive = all gates passed)
};

/// Evidence State Machine: S0-S5 monotonic transitions.
///
/// Monotonic guarantee: state NEVER decreases (S0 → S1 → … → S5).
/// This is the projection onto the isotone cone — once a user sees
/// "white", they will never regress to "gray".
///
/// S5 certification uses 6 information-theoretic gates:
///   1. DS Belief coverage >= threshold (three-valued: Certified/Uncertain/Impossible)
///   2. Choquet integral >= threshold (non-additive multi-dimensional quality)
///   3. Min super-dimension >= threshold (no weak dimension allowed)
///   4. DS uncertainty width <= threshold (evidence must be decisive)
///   5. High observation ratio >= threshold (CRLB precision guarantee)
///   6. Lyapunov rate <= threshold (convergence certificate)
///
/// Thread safety: NOT thread-safe.  Caller must synchronize.
class EvidenceStateMachine {
public:
    explicit EvidenceStateMachine(EvidenceStateMachineConfig config = {});

    /// Evaluate state transition.  Returns the (monotonically enforced) state.
    EvidenceStateMachineResult evaluate(const EvidenceStateMachineInput& input);

    /// Current state (read-only query, no side effects).
    ColorState current_state() const { return current_state_; }

    /// Reset to S0.
    void reset();

private:
    /// Compute raw state from input (no monotonic enforcement).
    /// Also populates diagnostic fields in result.
    ColorState compute_raw_state(const EvidenceStateMachineInput& input,
                                  EvidenceStateMachineResult& diag) const;

    EvidenceStateMachineConfig config_;
    ChoquetFuzzyMeasure choquet_mu_;
    ColorState current_state_{ColorState::kBlack};
    ColorState previous_state_{ColorState::kBlack};
};

}  // namespace evidence
}  // namespace aether

#endif  // AETHER_EVIDENCE_EVIDENCE_STATE_MACHINE_H
