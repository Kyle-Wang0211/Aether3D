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
    std::array<double, 7> level_weights{
        0.00, 0.20, 0.50, 0.80, 0.90, 0.95, 1.00};
    double ema_alpha{0.15};
    double max_coverage_delta_per_sec{0.10};
    double view_diversity_boost{0.05};
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
};

core::Status coverage_cells_from_evidence_state(
    const EvidenceState& state,
    std::vector<CoverageCellObservation>* out_cells);

}  // namespace evidence
}  // namespace aether

#endif  // AETHER_EVIDENCE_COVERAGE_ESTIMATOR_H
