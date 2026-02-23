// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/render/flip_animation.h"

#include "aether/core/numeric_guard.h"

#include <algorithm>
#include <cmath>

namespace aether {
namespace render {
namespace {

constexpr float kPi = 3.14159265358979323846f;

inline float clamp01(float v) {
    return std::max(0.0f, std::min(1.0f, v));
}

inline float bezier_1d(float t, float p1, float p2) {
    const float u = 1.0f - t;
    return 3.0f * u * u * t * p1 + 3.0f * u * t * t * p2 + t * t * t;
}

inline innovation::Float3 normalize3(const innovation::Float3& v, const innovation::Float3& fallback) {
    const float len = std::sqrt(v.x * v.x + v.y * v.y + v.z * v.z);
    if (len <= 1e-8f) {
        return fallback;
    }
    return innovation::make_float3(v.x / len, v.y / len, v.z / len);
}

Quaternion normalize_q(const Quaternion& q) {
    const float len = std::sqrt(q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w);
    if (len <= 1e-8f) {
        return Quaternion{};
    }
    Quaternion out{};
    out.x = q.x / len;
    out.y = q.y / len;
    out.z = q.z / len;
    out.w = q.w / len;
    return out;
}

}  // namespace

float flip_easing(float t, const FlipEasingConfig& config) {
    const float tt = clamp01(t);
    return bezier_1d(tt, config.cp1y, config.cp2y);
}

Quaternion quat_from_axis_angle(const innovation::Float3& axis, float angle) {
    const innovation::Float3 n = normalize3(axis, innovation::make_float3(0.0f, 1.0f, 0.0f));
    const float half = 0.5f * angle;
    const float sin_half = std::sin(half);
    Quaternion q{};
    q.x = n.x * sin_half;
    q.y = n.y * sin_half;
    q.z = n.z * sin_half;
    q.w = std::cos(half);
    return q;
}

innovation::Float3 rotate_by_quat(const innovation::Float3& v, const Quaternion& qin) {
    const float norm_sq = qin.x * qin.x + qin.y * qin.y + qin.z * qin.z + qin.w * qin.w;
    const Quaternion q = (norm_sq > 1e-8f && std::fabs(norm_sq - 1.0f) < 1e-3f)
        ? qin
        : normalize_q(qin);
    const innovation::Float3 u = innovation::make_float3(q.x, q.y, q.z);
    const float s = q.w;

    const innovation::Float3 uv = innovation::cross(u, v);
    const innovation::Float3 uuv = innovation::cross(u, uv);
    return innovation::add(
        innovation::add(v, innovation::mul(uv, 2.0f * s)),
        innovation::mul(uuv, 2.0f));
}

void compute_flip_states(
    const FlipAnimationState* active_flips,
    std::size_t flip_count,
    float current_time,
    const FlipEasingConfig& config,
    const innovation::Float3* rest_normals,
    FlipAnimationState* out_states) {
    if (active_flips == nullptr || out_states == nullptr || flip_count == 0u) {
        return;
    }

    const float duration = std::max(1e-4f, config.duration_s);
    for (std::size_t i = 0u; i < flip_count; ++i) {
        const FlipAnimationState& in = active_flips[i];
        FlipAnimationState out = in;

        const float t = (current_time - in.start_time_s) / duration;
        const float eased = flip_easing(t, config);
        const float clamped = std::max(0.0f, std::min(1.08f, eased));
        out.flip_angle = std::max(0.0f, std::min(kPi, clamped * kPi));
        out.rotation = quat_from_axis_angle(in.flip_axis_direction, out.flip_angle);

        const innovation::Float3 base = (rest_normals != nullptr)
            ? rest_normals[i]
            : innovation::make_float3(0.0f, 0.0f, 1.0f);
        out.rotated_normal = normalize3(
            rotate_by_quat(base, out.rotation),
            innovation::make_float3(0.0f, 0.0f, 1.0f));

        out_states[i] = out;
    }

    // C01 NumericGuard: guard output states at API boundary
    core::guard_finite_vector(
        reinterpret_cast<float*>(out_states),
        flip_count * (sizeof(FlipAnimationState) / sizeof(float)));
}

}  // namespace render
}  // namespace aether
