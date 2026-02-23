// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/quality/motion_analyzer.h"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>

namespace aether {
namespace quality {

MotionAnalyzer::MotionAnalyzer(std::size_t max_history)
    : max_history_(std::max<std::size_t>(1u, max_history)) {}

void MotionAnalyzer::reset() {
    motion_history_.clear();
    signed_shift_history_.clear();
    previous_frame_.clear();
    previous_width_ = 0;
    previous_height_ = 0;
}

void MotionAnalyzer::append_history(double score, double signed_shift) {
    motion_history_.push_back(score);
    signed_shift_history_.push_back(signed_shift);

    while (motion_history_.size() > max_history_) {
        motion_history_.pop_front();
    }
    while (signed_shift_history_.size() > max_history_) {
        signed_shift_history_.pop_front();
    }
}

bool MotionAnalyzer::detect_fast_pan(double score, double signed_shift_x) {
    return std::fabs(signed_shift_x) >= 0.06 && score >= 0.15;
}

bool MotionAnalyzer::detect_hand_shake() const {
    if (signed_shift_history_.size() < 6u) {
        return false;
    }

    int sign_changes = 0;
    double energy = 0.0;

    const std::size_t begin = signed_shift_history_.size() - 6u;
    for (std::size_t i = begin; i + 1u < signed_shift_history_.size(); ++i) {
        if (signed_shift_history_[i] * signed_shift_history_[i + 1u] < 0.0) {
            ++sign_changes;
        }
    }
    for (std::size_t i = begin; i < signed_shift_history_.size(); ++i) {
        energy += signed_shift_history_[i] * signed_shift_history_[i];
    }

    const double rms = std::sqrt(energy / 6.0);
    return sign_changes >= 4 && rms >= 0.015;
}

MotionResult MotionAnalyzer::analyze_frame(
    const std::uint8_t* image,
    int width,
    int height) {
    MotionResult result{};

    if (image == nullptr || width <= 0 || height <= 0) {
        append_history(0.0, 0.0);
        previous_frame_.clear();
        previous_width_ = 0;
        previous_height_ = 0;
        return result;
    }

    const std::size_t pixel_count = static_cast<std::size_t>(width) * static_cast<std::size_t>(height);
    if (pixel_count == 0u) {
        append_history(0.0, 0.0);
        return result;
    }

    if (previous_frame_.size() != pixel_count || previous_width_ != width || previous_height_ != height) {
        previous_frame_.assign(image, image + pixel_count);
        previous_width_ = width;
        previous_height_ = height;
        append_history(0.0, 0.0);
        return result;
    }

    const int sample_stride = std::max(1, std::min(width, height) / 128);

    double absolute_diff_sum = 0.0;
    double sample_count = 0.0;

    double weighted_x_current = 0.0;
    double weighted_x_previous = 0.0;
    double weighted_current = 0.0;
    double weighted_previous = 0.0;

    for (int y = 0; y < height; y += sample_stride) {
        const int row_offset = y * width;
        for (int x = 0; x < width; x += sample_stride) {
            const int index = row_offset + x;
            const double current_luma = static_cast<double>(image[index]);
            const double previous_luma = static_cast<double>(previous_frame_[static_cast<std::size_t>(index)]);

            absolute_diff_sum += std::fabs(current_luma - previous_luma);
            sample_count += 1.0;

            weighted_x_current += current_luma * static_cast<double>(x);
            weighted_x_previous += previous_luma * static_cast<double>(x);
            weighted_current += current_luma;
            weighted_previous += previous_luma;
        }
    }

    const double normalized_diff = sample_count > 0.0 ? (absolute_diff_sum / (sample_count * 255.0)) : 0.0;
    const double centroid_x_current = weighted_current > 0.0 ? (weighted_x_current / weighted_current)
                                                             : (static_cast<double>(width) * 0.5);
    const double centroid_x_previous = weighted_previous > 0.0 ? (weighted_x_previous / weighted_previous)
                                                               : (static_cast<double>(width) * 0.5);
    const double signed_shift_x = (centroid_x_current - centroid_x_previous) /
        std::max(1.0, static_cast<double>(width));
    const double shift_magnitude = std::fabs(signed_shift_x);

    const double score = std::min(1.0, normalized_diff * 4.0 + shift_magnitude * 2.5);

    append_history(score, signed_shift_x);
    previous_frame_.assign(image, image + pixel_count);

    result.score = score;
    result.is_fast_pan = detect_fast_pan(score, signed_shift_x);
    result.is_hand_shake = detect_hand_shake();
    return result;
}

MotionMetric MotionAnalyzer::analyze_quality(int quality_level) const {
    MotionMetric out{};

    double baseline = 0.0;
    if (!motion_history_.empty()) {
        for (double v : motion_history_) {
            baseline += v;
        }
        baseline /= static_cast<double>(motion_history_.size());
    }

    double quality_multiplier = 1.0;
    double confidence = 0.85;

    if (quality_level == 1) {
        quality_multiplier = 1.1;
        confidence = 0.70;
    } else if (quality_level == 2) {
        quality_multiplier = 1.2;
        confidence = 0.55;
    }

    out.value = std::min(1.0, baseline * quality_multiplier);
    out.confidence = confidence;

    if (!std::isfinite(out.value)) {
        out.value = 0.0;
        out.confidence = 0.0;
    }
    return out;
}

}  // namespace quality
}  // namespace aether
