// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/render/color_correction.h"

#include "aether/core/numeric_guard.h"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>

namespace aether {
namespace render {
namespace {

inline float clamp_float(float v, float lo, float hi) {
    return std::max(lo, std::min(hi, v));
}

inline std::uint8_t clamp_u8(float v) {
    const int iv = static_cast<int>(std::lround(v));
    return static_cast<std::uint8_t>(std::max(0, std::min(255, iv)));
}

}  // namespace

core::Status color_correct_rgb8(
    const std::uint8_t* image_in,
    int width,
    int height,
    int row_bytes,
    const ColorCorrectionConfig& config,
    ColorCorrectionState* state,
    std::uint8_t* image_out,
    ColorCorrectionStats* out_stats) {
    if (image_in == nullptr || image_out == nullptr || state == nullptr ||
        width <= 0 || height <= 0 || row_bytes < width * 3) {
        return core::Status::kInvalidArgument;
    }

    double sum_r = 0.0;
    double sum_g = 0.0;
    double sum_b = 0.0;
    double sum_luma = 0.0;

    for (int y = 0; y < height; ++y) {
        const std::uint8_t* row = image_in + static_cast<std::size_t>(y) * static_cast<std::size_t>(row_bytes);
        for (int x = 0; x < width; ++x) {
            const std::size_t p = static_cast<std::size_t>(x) * 3u;
            const float r = static_cast<float>(row[p + 0u]);
            const float g = static_cast<float>(row[p + 1u]);
            const float b = static_cast<float>(row[p + 2u]);
            sum_r += r;
            sum_g += g;
            sum_b += b;
            sum_luma += 0.299 * r + 0.587 * g + 0.114 * b;
        }
    }

    const double inv_n = 1.0 / static_cast<double>(width * height);
    const float avg_r = static_cast<float>(sum_r * inv_n);
    const float avg_g = static_cast<float>(sum_g * inv_n);
    const float avg_b = static_cast<float>(sum_b * inv_n);
    const float cur_luma = static_cast<float>(sum_luma * inv_n);

    const float gray = (avg_r + avg_g + avg_b) / 3.0f;
    const float gain_r = clamp_float(gray / std::max(1e-6f, avg_r), config.min_gain, config.max_gain);
    const float gain_g = clamp_float(gray / std::max(1e-6f, avg_g), config.min_gain, config.max_gain);
    const float gain_b = clamp_float(gray / std::max(1e-6f, avg_b), config.min_gain, config.max_gain);

    if (!state->has_reference) {
        state->reference_luminance = std::max(1e-6f, cur_luma);
        state->has_reference = true;
    }
    float exposure_ratio = 1.0f;
    if (config.mode == ColorCorrectionMode::kGrayWorldWithExposure) {
        exposure_ratio = state->reference_luminance / std::max(1e-6f, cur_luma);
        exposure_ratio = clamp_float(exposure_ratio, config.min_exposure_ratio, config.max_exposure_ratio);
    }

    for (int y = 0; y < height; ++y) {
        const std::uint8_t* src_row = image_in + static_cast<std::size_t>(y) * static_cast<std::size_t>(row_bytes);
        std::uint8_t* dst_row = image_out + static_cast<std::size_t>(y) * static_cast<std::size_t>(row_bytes);
        for (int x = 0; x < width; ++x) {
            const std::size_t p = static_cast<std::size_t>(x) * 3u;
            const float r = static_cast<float>(src_row[p + 0u]) * gain_r * exposure_ratio;
            const float g = static_cast<float>(src_row[p + 1u]) * gain_g * exposure_ratio;
            const float b = static_cast<float>(src_row[p + 2u]) * gain_b * exposure_ratio;
            dst_row[p + 0u] = clamp_u8(r);
            dst_row[p + 1u] = clamp_u8(g);
            dst_row[p + 2u] = clamp_u8(b);
        }
    }

    if (out_stats != nullptr) {
        out_stats->gain_r = gain_r;
        out_stats->gain_g = gain_g;
        out_stats->gain_b = gain_b;
        out_stats->exposure_ratio = exposure_ratio;

        // C01 NumericGuard: guard gain/exposure stats at API boundary
        core::guard_finite_scalar(&out_stats->gain_r);
        core::guard_finite_scalar(&out_stats->gain_g);
        core::guard_finite_scalar(&out_stats->gain_b);
        core::guard_finite_scalar(&out_stats->exposure_ratio);
    }

    return core::Status::kOk;
}

}  // namespace render
}  // namespace aether
