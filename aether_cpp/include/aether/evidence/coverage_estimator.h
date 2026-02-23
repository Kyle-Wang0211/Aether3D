// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_EVIDENCE_COVERAGE_ESTIMATOR_H
#define AETHER_EVIDENCE_COVERAGE_ESTIMATOR_H

#include "aether/core/status.h"
#include "aether/evidence/ds_mass_function.h"
#include "aether/evidence/replay_engine.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <vector>

namespace aether {
namespace evidence {

struct CoverageCellObservation {
    std::uint8_t level{0};        // L0..L6
    DSMassFunction mass{};        // Use occupied mass as primary evidence.
    double area_weight{1.0};      // Relative area contribution.
    bool excluded{false};         // Excluded from denominator if true.
    std::uint32_t view_count{0};  // Optional view diversity hint.
};

struct CoverageEstimatorConfig {
    // Fisher Information mode: continuous weights from I = n/(p(1-p))
    // replacing hand-tuned discrete level_weights.  When enabled,
    // each cell's weight = floor + (1-floor) * min(1, fisher/normalization).
    bool use_fisher_weights{true};
    double fisher_normalization{200.0};  // Fisher I ceiling for weight=1
    double fisher_floor{0.05};           // Minimum Fisher weight (prevent zero)

    // Discrete level weights — used as fallback when use_fisher_weights=false.
    std::array<double, 7> level_weights{
        0.00, 0.10, 0.30, 0.55, 0.80, 0.92, 1.00};
    double ema_alpha{0.15};
    double max_coverage_delta_per_sec{0.10};
    double view_diversity_boost{0.15};   // 3x boost for multi-angle scanning

    // Monotonic ratchet: when true, coverage can only increase (capture mode).
    // Grounded in Lyapunov stability theory — V(t) = sum(1-c_i)^2 is monotone
    // non-increasing, guaranteeing convergence without visual regression.
    bool monotonic_mode{false};
};

struct CoverageResult {
    double raw_coverage{0.0};
    double smoothed_coverage{0.0};
    double coverage{0.0};
    std::array<std::uint32_t, 7> breakdown_counts{};
    std::array<double, 7> weighted_sum_components{};
    std::size_t active_cell_count{0};
    double excluded_area_weight{0.0};
    int non_monotonic_time_count{0};

    // Lyapunov convergence metric: V(t) = sum(1 - c_i)^2 over all active cells.
    // Monotone non-increasing under consistent evidence accumulation.
    // If this value INCREASES between frames, it signals a regression anomaly.
    double lyapunov_convergence{0.0};

    // ── Information-theoretic extensions ──

    // L5+ (≥15 observations) ratio — CRLB precision guarantee proxy.
    double high_observation_ratio{0.0};

    // DS Belief coverage lower bound: mean(sealed.occupied) weighted.
    double belief_coverage{0.0};

    // DS Plausibility coverage upper bound: mean(sealed.occupied + sealed.unknown).
    double plausibility_coverage{0.0};

    // DS uncertainty width: plausibility - belief = mean(sealed.unknown).
    double uncertainty_width{0.0};

    // Mean Fisher information across active cells.
    double mean_fisher_info{0.0};

    // Lyapunov convergence RATE: |dV/dt| / V.
    // Near zero means converged; large means still changing rapidly.
    double lyapunov_rate{1.0};

    // ── PAC (Probably Approximately Correct) probability certificates ──
    // Based on: Pr[cell_i misclassified] ≤ exp(-n_i × KL(b_i || 0.5))
    // where n_i = observation count, b_i = DS Belief(occupied).

    // Union bound over all active cells: Σ exp(-n_i * KL(b_i||0.5)).
    // Lower = better.  < 1.0 means PAC-style completeness certificate holds.
    double pac_failure_bound{1.0};

    // Worst-case single cell risk: max_i exp(-n_i * KL(b_i||0.5)).
    double pac_max_cell_risk{1.0};

    // Number of cells with individual risk < 0.01 (well-certified cells).
    std::size_t pac_certified_cell_count{0};
};

class CoverageEstimator {
public:
    explicit CoverageEstimator(CoverageEstimatorConfig config = {});

    void reset();
    core::Status update(
        const CoverageCellObservation* cells,
        std::size_t cell_count,
        std::int64_t monotonic_timestamp_ms,
        CoverageResult* out_result);

    double last_coverage() const { return last_coverage_; }
    int non_monotonic_time_count() const { return non_monotonic_time_count_; }

private:
    CoverageEstimatorConfig config_{};
    double last_coverage_{0.0};
    std::int64_t last_timestamp_ms_{0};
    int non_monotonic_time_count_{0};
    bool initialized_{false};
    double prev_lyapunov_{0.0};  // For Lyapunov rate: |dV/dt|/V
};

core::Status coverage_cells_from_evidence_state(
    const EvidenceState& state,
    std::vector<CoverageCellObservation>* out_cells);

}  // namespace evidence
}  // namespace aether

#endif  // AETHER_EVIDENCE_COVERAGE_ESTIMATOR_H
