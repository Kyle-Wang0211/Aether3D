// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_CPP_RENDER_FLIP_ANIMATION_H
#define AETHER_CPP_RENDER_FLIP_ANIMATION_H

#ifdef __cplusplus

#include "aether/innovation/core_types.h"

#include <cstddef>

namespace aether {
namespace render {

struct Quaternion {
    float x{0.0f};
    float y{0.0f};
    float z{0.0f};
    float w{1.0f};
};

struct FlipAnimationState {
    float start_time_s{0.0f};
    float flip_angle{0.0f};
    innovation::Float3 flip_axis_origin{};
    innovation::Float3 flip_axis_direction{0.0f, 1.0f, 0.0f};
    float ripple_amplitude{0.0f};
    Quaternion rotation{};
    innovation::Float3 rotated_normal{0.0f, 0.0f, 1.0f};
};

struct FlipEasingConfig {
    float duration_s{0.5f};
    float cp1x{0.34f};
    float cp1y{1.56f};
    float cp2x{0.64f};
    float cp2y{1.0f};
    float stagger_delay_s{0.03f};
    int max_concurrent{20};
};

float flip_easing(float t, const FlipEasingConfig& config);
Quaternion quat_from_axis_angle(const innovation::Float3& axis, float angle);
innovation::Float3 rotate_by_quat(const innovation::Float3& v, const Quaternion& q);

void compute_flip_states(
    const FlipAnimationState* active_flips,
    std::size_t flip_count,
    float current_time,
    const FlipEasingConfig& config,
    const innovation::Float3* rest_normals,
    FlipAnimationState* out_states);

}  // namespace render
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_CPP_RENDER_FLIP_ANIMATION_H
