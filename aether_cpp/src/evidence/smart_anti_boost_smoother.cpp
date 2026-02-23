// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/evidence/smart_anti_boost_smoother.h"

#include <algorithm>
#include <cmath>
#include <limits>

namespace aether {
namespace evidence {

SmartAntiBoostSmoother::SmartAntiBoostSmoother(const SmartSmootherConfig& config)
    : config_(config) {
    config_.window_size = std::max<std::size_t>(1u, config_.window_size);
    config_.max_consecutive_invalid = std::max(1, config_.max_consecutive_invalid);
    config_.jitter_band = std::max(0.0, config_.jitter_band);
    history_.reserve(config_.window_size);
}

double SmartAntiBoostSmoother::handle_invalid_input() {
    consecutive_invalid_count_ += 1;
    if (consecutive_invalid_count_ >= config_.max_consecutive_invalid) {
        has_previous_smoothed_ = true;
        previous_smoothed_ = config_.worst_case_fallback;
        return config_.worst_case_fallback;
    }
    if (has_previous_smoothed_) {
        return previous_smoothed_;
    }
    return config_.worst_case_fallback;
}

double SmartAntiBoostSmoother::compute_median() const {
    if (history_.empty()) {
        return 0.0;
    }
    std::vector<double> sorted = history_;
    std::sort(sorted.begin(), sorted.end());
    const std::size_t n = sorted.size();
    if ((n % 2u) == 0u) {
        return 0.5 * (sorted[n / 2u - 1u] + sorted[n / 2u]);
    }
    return sorted[n / 2u];
}

double SmartAntiBoostSmoother::compute_smoothed(double new_value) {
    const double median = compute_median();
    const double previous = has_previous_smoothed_ ? previous_smoothed_ : median;
    const double change = new_value - previous;

    if (std::fabs(change) < config_.jitter_band) {
        return median;
    }

    if (change > 0.0) {
        if (change > config_.jitter_band * 3.0) {
            return previous + change * config_.anti_boost_factor;
        }
        return previous + change * config_.normal_improve_factor;
    }

    // In capture mode, degrade_factor is forced to 0: no visual regression.
    const double effective_degrade = config_.capture_mode ? 0.0 : config_.degrade_factor;
    return previous + change * effective_degrade;
}

double SmartAntiBoostSmoother::add(double value) {
    if (!std::isfinite(value)) {
        return handle_invalid_input();
    }

    consecutive_invalid_count_ = 0;

    if (history_.size() >= config_.window_size) {
        history_.erase(history_.begin());
    }
    history_.push_back(value);

    double smoothed = compute_smoothed(value);

    // In capture mode, enforce high-water mark: output never falls below peak.
    if (config_.capture_mode) {
        smoothed = std::max(smoothed, high_water_mark_);
        high_water_mark_ = smoothed;
    }

    has_previous_smoothed_ = true;
    previous_smoothed_ = smoothed;
    return smoothed;
}

void SmartAntiBoostSmoother::reset() {
    history_.clear();
    has_previous_smoothed_ = false;
    previous_smoothed_ = 0.0;
    consecutive_invalid_count_ = 0;
    high_water_mark_ = 0.0;
}

}  // namespace evidence
}  // namespace aether
