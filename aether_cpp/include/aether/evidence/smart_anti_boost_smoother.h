// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_EVIDENCE_SMART_ANTI_BOOST_SMOOTHER_H
#define AETHER_EVIDENCE_SMART_ANTI_BOOST_SMOOTHER_H

#ifdef __cplusplus

#include <cstddef>
#include <vector>

namespace aether {
namespace evidence {

struct SmartSmootherConfig {
    std::size_t window_size{5u};
    double jitter_band{0.05};
    double anti_boost_factor{0.3};
    double normal_improve_factor{0.7};
    double degrade_factor{1.0};
    int max_consecutive_invalid{3};
    double worst_case_fallback{0.0};

    // Capture mode: when true, degrade_factor is forced to 0 and a high-water
    // mark ensures output never falls below previous peak.  Grounded in
    // Lyapunov stability — V(t) = (1-smoothed)^2 is monotone non-increasing.
    bool capture_mode{false};
};

class SmartAntiBoostSmoother {
public:
    explicit SmartAntiBoostSmoother(const SmartSmootherConfig& config);

    double add(double value);
    void reset();

private:
    double handle_invalid_input();
    double compute_median() const;
    double compute_smoothed(double new_value);

    SmartSmootherConfig config_{};
    std::vector<double> history_{};
    bool has_previous_smoothed_{false};
    double previous_smoothed_{0.0};
    int consecutive_invalid_count_{0};
    double high_water_mark_{0.0};
};

}  // namespace evidence
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_EVIDENCE_SMART_ANTI_BOOST_SMOOTHER_H
