// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_RENDER_COLOR_CORRECTION_H
#define AETHER_RENDER_COLOR_CORRECTION_H

#ifdef __cplusplus

#include "aether/core/status.h"

#include <cstddef>
#include <cstdint>

namespace aether {
namespace render {

enum class ColorCorrectionMode : std::int32_t {
    kGrayWorld = 0,
    kGrayWorldWithExposure = 1,
};

struct ColorCorrectionConfig {
    ColorCorrectionMode mode{ColorCorrectionMode::kGrayWorldWithExposure};
    float min_gain{0.5f};
    float max_gain{2.0f};
    float min_exposure_ratio{0.5f};
    float max_exposure_ratio{2.0f};
};

struct ColorCorrectionState {
    bool has_reference{false};
    float reference_luminance{0.0f};
};

struct ColorCorrectionStats {
    float gain_r{1.0f};
    float gain_g{1.0f};
    float gain_b{1.0f};
    float exposure_ratio{1.0f};
};

core::Status color_correct_rgb8(
    const std::uint8_t* image_in,
    int width,
    int height,
    int row_bytes,
    const ColorCorrectionConfig& config,
    ColorCorrectionState* state,
    std::uint8_t* image_out,
    ColorCorrectionStats* out_stats);

}  // namespace render
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_RENDER_COLOR_CORRECTION_H
