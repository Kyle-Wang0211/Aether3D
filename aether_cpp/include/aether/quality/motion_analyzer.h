// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_QUALITY_MOTION_ANALYZER_H
#define AETHER_QUALITY_MOTION_ANALYZER_H

#ifdef __cplusplus

#include "aether/core/status.h"

#include <cstddef>
#include <cstdint>
#include <deque>
#include <vector>

namespace aether {
namespace quality {

struct MotionResult {
    double score{0.0};
    bool is_fast_pan{false};
    bool is_hand_shake{false};
};

struct MotionMetric {
    double value{0.0};
    double confidence{0.0};
};

class MotionAnalyzer {
public:
    explicit MotionAnalyzer(std::size_t max_history = 50u);

    void reset();

    MotionResult analyze_frame(
        const std::uint8_t* image,
        int width,
        int height);

    MotionMetric analyze_quality(int quality_level) const;

private:
    std::size_t max_history_;
    std::deque<double> motion_history_;
    std::deque<double> signed_shift_history_;
    std::vector<std::uint8_t> previous_frame_;
    int previous_width_{0};
    int previous_height_{0};

    void append_history(double score, double signed_shift);
    static bool detect_fast_pan(double score, double signed_shift_x);
    bool detect_hand_shake() const;
};

}  // namespace quality
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_QUALITY_MOTION_ANALYZER_H
