// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/evidence/coverage_estimator.h"

#include <algorithm>
#include <cmath>
#include <cstddef>

namespace aether {
namespace evidence {
namespace {

double clamp01(double value) {
    return std::max(0.0, std::min(1.0, value));
}

std::uint8_t level_from_observation_count(int observation_count) {
    if (observation_count <= 0) return 0u;
    if (observation_count < 3) return 1u;
    if (observation_count < 6) return 2u;
    if (observation_count < 10) return 3u;
    if (observation_count < 15) return 4u;
    if (observation_count < 25) return 5u;
    return 6u;
}

bool is_valid_config(const CoverageEstimatorConfig& config) {
    if (!(config.ema_alpha >= 0.0 && config.ema_alpha <= 1.0) ||
        !(config.max_coverage_delta_per_sec >= 0.0) ||
        !(config.view_diversity_boost >= 0.0 && config.view_diversity_boost <= 1.0)) {
        return false;
    }
    if (config.use_fisher_weights) {
        if (!(config.fisher_normalization > 0.0) ||
            !(config.fisher_floor >= 0.0 && config.fisher_floor <= 1.0)) {
            return false;
        }
    }
    for (double w : config.level_weights) {
        if (!std::isfinite(w) || w < 0.0) {
            return false;
        }
    }
    return true;
}

}  // namespace

CoverageEstimator::CoverageEstimator(CoverageEstimatorConfig config)
    : config_(config) {}

void CoverageEstimator::reset() {
    last_coverage_ = 0.0;
    last_timestamp_ms_ = 0;
    non_monotonic_time_count_ = 0;
    initialized_ = false;
    prev_lyapunov_ = 0.0;
}

core::Status CoverageEstimator::update(
    const CoverageCellObservation* cells,
    std::size_t cell_count,
    std::int64_t monotonic_timestamp_ms,
    CoverageResult* out_result) {
    if (out_result == nullptr) {
        return core::Status::kInvalidArgument;
    }
    if (cell_count > 0u && cells == nullptr) {
        return core::Status::kInvalidArgument;
    }
    if (!is_valid_config(config_)) {
        return core::Status::kInvalidArgument;
    }

    CoverageResult result{};

    double numerator = 0.0;
    double denominator = 0.0;

    // ── Information-theoretic accumulators ──
    std::uint32_t high_obs_count = 0;
    double bel_numerator = 0.0;
    double pl_numerator = 0.0;
    double total_fisher = 0.0;
    std::uint32_t fisher_count = 0;

    // ── PAC certificate accumulators ──
    double pac_sum = 0.0;
    double pac_max = 0.0;
    std::size_t pac_certified = 0;

    for (std::size_t i = 0u; i < cell_count; ++i) {
        const auto& cell = cells[i];
        const std::uint8_t level = cell.level < 7u ? cell.level : 6u;
        const double area = std::max(0.0, cell.area_weight);
        if (area <= 0.0) {
            continue;
        }
        if (cell.excluded) {
            result.excluded_area_weight += area;
            continue;
        }

        const DSMassFunction sealed = cell.mass.sealed();
        const double occupied = clamp01(sealed.occupied);
        const double unknown = clamp01(sealed.unknown);
        const double plausibility = clamp01(occupied + unknown);  // DS Pl upper bound

        const double view_norm = clamp01(static_cast<double>(cell.view_count) / 12.0);
        const double diversity_factor = 1.0 + config_.view_diversity_boost * view_norm;
        const double effective_area = area * diversity_factor;

        // ── Weight selection: Fisher or discrete fallback ──
        double weight;
        if (config_.use_fisher_weights) {
            // Fisher Information: I = n / (p * (1-p))
            // Provides continuous, information-theoretic weight for each cell.
            // Higher Fisher → more informative cell → higher weight.
            const double p_safe = std::max(0.01, std::min(0.99, occupied));
            const double n = static_cast<double>(
                std::max(1u, static_cast<unsigned>(cell.view_count)));
            const double fisher = n / (p_safe * (1.0 - p_safe));
            weight = std::min(1.0,
                config_.fisher_floor + (1.0 - config_.fisher_floor)
                * (fisher / config_.fisher_normalization));
            total_fisher += fisher;
            ++fisher_count;
        } else {
            // Fallback: hand-tuned discrete level_weights
            weight = clamp01(config_.level_weights[level]);
        }

        const double contribution = weight * occupied * effective_area;
        numerator += contribution;
        denominator += effective_area;

        // ── DS interval accumulation (same loop, no second pass) ──
        bel_numerator += weight * occupied * effective_area;
        pl_numerator += weight * plausibility * effective_area;

        // ── Per-level breakdown (unchanged) ──
        result.breakdown_counts[level] += 1u;
        result.weighted_sum_components[level] += contribution;
        result.active_cell_count += 1u;

        // ── L5+ count (≥15 observations → CRLB precision proxy) ──
        if (cell.level >= 5u) {
            ++high_obs_count;
        }

        // ── PAC: KL divergence + exponential bound ──
        // Pr[cell misclassified] ≤ exp(-n * KL(b || 0.5))
        // KL(b||0.5) = b*ln(2b) + (1-b)*ln(2(1-b))
        {
            const double b = std::max(0.01, std::min(0.99, occupied));
            const double kl = b * std::log(2.0 * b)
                            + (1.0 - b) * std::log(2.0 * (1.0 - b));
            const double n_obs = static_cast<double>(
                std::max(1u, static_cast<unsigned>(cell.view_count)));
            const double cell_risk = std::exp(-n_obs * std::max(0.0, kl));
            pac_sum += cell_risk;
            if (cell_risk > pac_max) pac_max = cell_risk;
            if (cell_risk < 0.01) ++pac_certified;
        }
    }

    result.raw_coverage = (denominator > 0.0) ? clamp01(numerator / denominator) : 0.0;
    result.smoothed_coverage = initialized_
        ? clamp01(config_.ema_alpha * result.raw_coverage + (1.0 - config_.ema_alpha) * last_coverage_)
        : result.raw_coverage;

    double limited = result.smoothed_coverage;
    if (initialized_) {
        const std::int64_t dt_ms = monotonic_timestamp_ms - last_timestamp_ms_;
        if (dt_ms <= 0) {
            non_monotonic_time_count_ += 1;
        } else {
            const double dt_sec = static_cast<double>(dt_ms) / 1000.0;
            const double max_delta = config_.max_coverage_delta_per_sec * dt_sec;
            const double delta = limited - last_coverage_;
            if (delta > max_delta) {
                limited = last_coverage_ + max_delta;
            } else if (config_.monotonic_mode) {
                // Monotonic ratchet: coverage can ONLY increase during capture.
                // Grounded in isotonic regression (PAVA) — the max operator is
                // the projection onto the monotone cone in L2 space.
                limited = std::max(limited, last_coverage_);
            } else if (delta < -max_delta) {
                limited = last_coverage_ - max_delta;
            }
        }
    }

    result.coverage = clamp01(limited);

    // Lyapunov convergence metric: V(t) = sum_i (1 - c_i)^2 over all active cells.
    // Under consistent evidence, V(t) is monotone non-increasing, proving convergence.
    // A rising V signals regression — useful as a pipeline health diagnostic.
    result.lyapunov_convergence = 0.0;
    if (denominator > 0.0) {
        for (std::size_t i = 0u; i < cell_count; ++i) {
            const auto& cell = cells[i];
            const double area = std::max(0.0, cell.area_weight);
            if (area <= 0.0 || cell.excluded) {
                continue;
            }
            const DSMassFunction sealed = cell.mass.sealed();
            const double gap = 1.0 - clamp01(sealed.occupied);
            result.lyapunov_convergence += gap * gap;
        }
    }

    // ── Lyapunov convergence rate: |dV/dt| / V ──
    // Measures how fast we're converging.  Near-zero = stable (good for S5).
    if (initialized_ && result.lyapunov_convergence > 1e-9) {
        result.lyapunov_rate = std::abs(prev_lyapunov_ - result.lyapunov_convergence)
                             / std::max(result.lyapunov_convergence, 1e-9);
    } else {
        result.lyapunov_rate = 1.0;  // Not yet initialized → "not converged"
    }
    prev_lyapunov_ = result.lyapunov_convergence;

    // ── Output information-theoretic metrics ──
    result.high_observation_ratio = (result.active_cell_count > 0u)
        ? static_cast<double>(high_obs_count) / static_cast<double>(result.active_cell_count)
        : 0.0;
    result.belief_coverage = (denominator > 0.0) ? clamp01(bel_numerator / denominator) : 0.0;
    result.plausibility_coverage = (denominator > 0.0) ? clamp01(pl_numerator / denominator) : 0.0;
    result.uncertainty_width = result.plausibility_coverage - result.belief_coverage;
    result.mean_fisher_info = (fisher_count > 0u)
        ? total_fisher / static_cast<double>(fisher_count) : 0.0;

    // ── PAC certificate output ──
    result.pac_failure_bound = pac_sum;
    result.pac_max_cell_risk = pac_max;
    result.pac_certified_cell_count = pac_certified;

    result.non_monotonic_time_count = non_monotonic_time_count_;

    last_coverage_ = result.coverage;
    last_timestamp_ms_ = monotonic_timestamp_ms;
    initialized_ = true;
    *out_result = result;
    return core::Status::kOk;
}

core::Status coverage_cells_from_evidence_state(
    const EvidenceState& state,
    std::vector<CoverageCellObservation>* out_cells) {
    if (out_cells == nullptr) {
        return core::Status::kInvalidArgument;
    }
    out_cells->clear();
    out_cells->reserve(state.patches.size());
    for (const auto& kv : state.patches) {
        (void)kv.first;
        const PatchEntrySnapshot& patch = kv.second;
        CoverageCellObservation cell{};
        cell.level = level_from_observation_count(patch.observation_count);
        const double occupied = clamp01(patch.evidence);
        cell.mass = DSMassFunction(occupied, 0.0, 1.0 - occupied).sealed();
        cell.area_weight = 1.0;
        cell.excluded = false;
        cell.view_count = patch.observation_count > 0 ? static_cast<std::uint32_t>(patch.observation_count) : 0u;
        out_cells->push_back(cell);
    }
    return core::Status::kOk;
}

}  // namespace evidence
}  // namespace aether
