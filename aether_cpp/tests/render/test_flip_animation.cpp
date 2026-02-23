// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/render/flip_animation.h"

#include <cmath>
#include <cstdio>

int main() {
    int failed = 0;

    const aether::render::FlipEasingConfig cfg{};
    const float y0 = aether::render::flip_easing(0.0f, cfg);
    const float y1 = aether::render::flip_easing(1.0f, cfg);
    if (!(std::fabs(y0) < 1e-6f && std::fabs(y1 - 1.0f) < 1e-4f)) {
        std::fprintf(stderr, "flip_easing boundary mismatch\n");
        failed++;
    }

    const auto q = aether::render::quat_from_axis_angle(aether::innovation::make_float3(0.0f, 1.0f, 0.0f), 3.1415926f);
    const auto v = aether::render::rotate_by_quat(aether::innovation::make_float3(1.0f, 0.0f, 0.0f), q);
    if (!(v.x < -0.9f)) {
        std::fprintf(stderr, "rotate_by_quat mismatch\n");
        failed++;
    }

    aether::render::FlipAnimationState in{};
    in.start_time_s = 0.0f;
    in.flip_axis_direction = aether::innovation::make_float3(0.0f, 1.0f, 0.0f);
    const aether::innovation::Float3 rest[1] = {aether::innovation::make_float3(0.0f, 0.0f, 1.0f)};
    aether::render::FlipAnimationState out[1]{};
    aether::render::compute_flip_states(&in, 1u, 0.25f, cfg, rest, out);
    if (!(out[0].flip_angle > 0.0f && out[0].flip_angle <= 3.142f)) {
        std::fprintf(stderr, "compute_flip_states angle mismatch\n");
        failed++;
    }

    return failed;
}
