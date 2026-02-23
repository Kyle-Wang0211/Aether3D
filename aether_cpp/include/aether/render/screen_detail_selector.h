// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_CPP_RENDER_SCREEN_DETAIL_SELECTOR_H
#define AETHER_CPP_RENDER_SCREEN_DETAIL_SELECTOR_H

#ifdef __cplusplus

#include "aether/core/status.h"
#include "aether/innovation/core_types.h"

#include <cstddef>

namespace aether {
namespace render {

struct ScreenDetailConfig {
    float reference_screen_area{100.0f};
    float display_weight{0.3f};
};

float screen_detail_factor(
    float unit_area,
    float distance_to_camera,
    float focal_length,
    float display,
    const ScreenDetailConfig& config = ScreenDetailConfig{});

core::Status batch_screen_detail_factor(
    const innovation::ScaffoldUnit* units,
    std::size_t unit_count,
    const float* distances,
    const float* displays,
    float focal_length,
    const ScreenDetailConfig& config,
    float* out_detail_factors);

}  // namespace render
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_CPP_RENDER_SCREEN_DETAIL_SELECTOR_H
