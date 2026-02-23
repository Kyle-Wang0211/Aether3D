// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/render/screen_detail_selector.h"

#include "aether/core/numeric_guard.h"

#include <algorithm>

namespace aether {
namespace render {

float screen_detail_factor(
    float unit_area,
    float distance_to_camera,
    float focal_length,
    float display,
    const ScreenDetailConfig& config) {
    if (distance_to_camera <= 0.0f) {
        return 1.0f;
    }
    if (unit_area <= 0.0f) {
        return 0.0f;
    }
    if (focal_length <= 0.0f || config.reference_screen_area <= 0.0f) {
        return 0.0f;
    }

    const float area = unit_area * focal_length * focal_length /
        std::max(distance_to_camera * distance_to_camera, 1e-4f);
    // Use a sigmoid-like mapping: area_t = area / (area + ref) so that larger
    // screen-space area produces a higher but bounded factor.
    const float area_t = area / (area + config.reference_screen_area);
    const float display_t = std::max(0.0f, std::min(1.0f, display));
    const float weight = std::max(0.0f, std::min(1.0f, config.display_weight));
    const float detail = area_t * (1.0f - weight) + display_t * weight;
    return std::max(0.0f, std::min(1.0f, detail));
}

core::Status batch_screen_detail_factor(
    const innovation::ScaffoldUnit* units,
    std::size_t unit_count,
    const float* distances,
    const float* displays,
    float focal_length,
    const ScreenDetailConfig& config,
    float* out_detail_factors) {
    if (unit_count == 0u) {
        return core::Status::kOk;
    }
    if (units == nullptr || distances == nullptr ||
        out_detail_factors == nullptr || focal_length <= 0.0f) {
        return core::Status::kInvalidArgument;
    }

    for (std::size_t i = 0u; i < unit_count; ++i) {
        const float display = displays != nullptr ? displays[i] : units[i].confidence;
        out_detail_factors[i] = screen_detail_factor(
            std::max(0.0f, units[i].area),
            distances[i],
            focal_length,
            display,
            config);
    }

    // C01 NumericGuard: guard detail factor output at API boundary
    core::guard_finite_vector(out_detail_factors, unit_count);

    return core::Status::kOk;
}

}  // namespace render
}  // namespace aether
