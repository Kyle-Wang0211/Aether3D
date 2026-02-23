// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_EVIDENCE_SMART_ANTI_BOOST_SMOOTHER_H
#define AETHER_EVIDENCE_SMART_ANTI_BOOST_SMOOTHER_H

#include <algorithm>
#include <cstddef>
#include <vector>

namespace aether {
namespace evidence {

struct SmartSmootherConfig {
    std::size_t window_size{8};
    double jitter_band{0.02};
    double anti_boost_factor{0.5};
    double normal_improve_factor{1.0};
    double degrade_factor{0.8};
    int max_consecutive_invalid{3};
    double worst_case_fallback{0.0};
};

class SmartAntiBoostSmoother {
public:
    explicit SmartAntiBoostSmoother(const SmartSmootherConfig& config = {})
        : config_(config) {}

    double update(double raw_value) {
        if (raw_value != raw_value) {  // NaN check
            ++consecutive_invalid_;
            if (consecutive_invalid_ >= config_.max_consecutive_invalid) {
                smoothed_ = config_.worst_case_fallback;
            }
            return smoothed_;
        }
        consecutive_invalid_ = 0;

        history_.push_back(raw_value);
        if (history_.size() > config_.window_size) {
            history_.erase(history_.begin());
        }

        // Compute windowed median
        std::vector<double> sorted = history_;
        std::sort(sorted.begin(), sorted.end());
        const double median = sorted[sorted.size() / 2];

        const double delta = raw_value - smoothed_;
        const double jitter = config_.jitter_band;

        if (delta > jitter) {
            // Improving: apply normal factor
            smoothed_ += delta * config_.normal_improve_factor;
        } else if (delta < -jitter) {
            // Degrading: apply degrade factor with anti-boost
            const double boost_penalty = (smoothed_ > median + jitter)
                ? config_.anti_boost_factor : 1.0;
            smoothed_ += delta * config_.degrade_factor * boost_penalty;
        }
        // Within jitter band: no change

        smoothed_ = std::max(0.0, std::min(1.0, smoothed_));
        return smoothed_;
    }

    double value() const { return smoothed_; }

    void reset() {
        smoothed_ = 0.0;
        consecutive_invalid_ = 0;
        history_.clear();
    }

private:
    SmartSmootherConfig config_{};
    double smoothed_{0.0};
    int consecutive_invalid_{0};
    std::vector<double> history_{};
};

}  // namespace evidence
}  // namespace aether

#endif  // AETHER_EVIDENCE_SMART_ANTI_BOOST_SMOOTHER_H
