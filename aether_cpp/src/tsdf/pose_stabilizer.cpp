// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/tsdf/pose_stabilizer.h"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <limits>

namespace aether {
namespace tsdf {
namespace {

constexpr float kEps = 1e-6f;

struct Vec3 {
    float x{0.0f};
    float y{0.0f};
    float z{0.0f};
};

struct Quat {
    float w{1.0f};
    float x{0.0f};
    float y{0.0f};
    float z{0.0f};
};

bool finite(float v) {
    return std::isfinite(v);
}

bool finite_pose(const float* pose16) {
    if (pose16 == nullptr) {
        return false;
    }
    for (std::size_t i = 0u; i < 16u; ++i) {
        if (!finite(pose16[i])) {
            return false;
        }
    }
    return true;
}

Vec3 make_vec3(const float xyz[3]) {
    return Vec3{xyz[0], xyz[1], xyz[2]};
}

Vec3 make_vec3(const std::array<float, 3>& xyz) {
    return Vec3{xyz[0], xyz[1], xyz[2]};
}

std::array<float, 3> to_array(const Vec3& v) {
    return {v.x, v.y, v.z};
}

Vec3 add(const Vec3& a, const Vec3& b) {
    return Vec3{a.x + b.x, a.y + b.y, a.z + b.z};
}

Vec3 sub(const Vec3& a, const Vec3& b) {
    return Vec3{a.x - b.x, a.y - b.y, a.z - b.z};
}

Vec3 mul(const Vec3& v, float s) {
    return Vec3{v.x * s, v.y * s, v.z * s};
}

float dot(const Vec3& a, const Vec3& b) {
    return a.x * b.x + a.y * b.y + a.z * b.z;
}

float norm(const Vec3& v) {
    return std::sqrt(std::max(0.0f, dot(v, v)));
}

Vec3 normalized(const Vec3& v) {
    const float n = norm(v);
    if (n <= kEps) {
        return Vec3{1.0f, 0.0f, 0.0f};
    }
    return mul(v, 1.0f / n);
}

float clamp01(float v) {
    return std::max(0.0f, std::min(1.0f, v));
}

float clampf(float v, float lo, float hi) {
    return std::max(lo, std::min(hi, v));
}

Vec3 lerp(const Vec3& a, const Vec3& b, float t) {
    return add(mul(a, 1.0f - t), mul(b, t));
}

Quat quat_normalize(const Quat& q) {
    const float n = std::sqrt(std::max(kEps, q.w * q.w + q.x * q.x + q.y * q.y + q.z * q.z));
    const float inv = 1.0f / n;
    return Quat{q.w * inv, q.x * inv, q.y * inv, q.z * inv};
}

Quat quat_mul(const Quat& a, const Quat& b) {
    return Quat{
        a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
        a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
        a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
        a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w};
}

Quat quat_from_axis_angle(const Vec3& axis_in, float angle_rad) {
    const Vec3 axis = normalized(axis_in);
    const float half = 0.5f * angle_rad;
    const float s = std::sin(half);
    const float c = std::cos(half);
    return quat_normalize(Quat{c, axis.x * s, axis.y * s, axis.z * s});
}

Quat quat_slerp(Quat a, Quat b, float t) {
    a = quat_normalize(a);
    b = quat_normalize(b);
    float cos_theta = a.w * b.w + a.x * b.x + a.y * b.y + a.z * b.z;
    if (cos_theta < 0.0f) {
        cos_theta = -cos_theta;
        b.w = -b.w;
        b.x = -b.x;
        b.y = -b.y;
        b.z = -b.z;
    }

    if (cos_theta > 0.9995f) {
        const Quat blended{
            a.w + t * (b.w - a.w),
            a.x + t * (b.x - a.x),
            a.y + t * (b.y - a.y),
            a.z + t * (b.z - a.z)};
        return quat_normalize(blended);
    }

    const float theta = std::acos(clampf(cos_theta, -1.0f, 1.0f));
    const float sin_theta = std::sin(theta);
    if (sin_theta <= kEps) {
        return quat_normalize(a);
    }
    const float w0 = std::sin((1.0f - t) * theta) / sin_theta;
    const float w1 = std::sin(t * theta) / sin_theta;
    return quat_normalize(Quat{
        a.w * w0 + b.w * w1,
        a.x * w0 + b.x * w1,
        a.y * w0 + b.y * w1,
        a.z * w0 + b.z * w1});
}

Quat quat_from_pose_matrix(const float m[16]) {
    // Matrix is treated as column-major (translation in m[12..14]).
    // rXY means row X, col Y.
    const float r00 = m[0];
    const float r01 = m[4];
    const float r02 = m[8];
    const float r10 = m[1];
    const float r11 = m[5];
    const float r12 = m[9];
    const float r20 = m[2];
    const float r21 = m[6];
    const float r22 = m[10];

    const float trace = r00 + r11 + r22;
    Quat q{};
    if (trace > 0.0f) {
        const float s = std::sqrt(trace + 1.0f) * 2.0f;
        q.w = 0.25f * s;
        q.x = (r21 - r12) / s;
        q.y = (r02 - r20) / s;
        q.z = (r10 - r01) / s;
    } else if (r00 > r11 && r00 > r22) {
        const float s = std::sqrt(std::max(kEps, 1.0f + r00 - r11 - r22)) * 2.0f;
        q.w = (r21 - r12) / s;
        q.x = 0.25f * s;
        q.y = (r01 + r10) / s;
        q.z = (r02 + r20) / s;
    } else if (r11 > r22) {
        const float s = std::sqrt(std::max(kEps, 1.0f + r11 - r00 - r22)) * 2.0f;
        q.w = (r02 - r20) / s;
        q.x = (r01 + r10) / s;
        q.y = 0.25f * s;
        q.z = (r12 + r21) / s;
    } else {
        const float s = std::sqrt(std::max(kEps, 1.0f + r22 - r00 - r11)) * 2.0f;
        q.w = (r10 - r01) / s;
        q.x = (r02 + r20) / s;
        q.y = (r12 + r21) / s;
        q.z = 0.25f * s;
    }
    return quat_normalize(q);
}

void quat_to_pose_rotation(const Quat& q_in, float m[16]) {
    const Quat q = quat_normalize(q_in);

    const float xx = q.x * q.x;
    const float yy = q.y * q.y;
    const float zz = q.z * q.z;
    const float xy = q.x * q.y;
    const float xz = q.x * q.z;
    const float yz = q.y * q.z;
    const float wx = q.w * q.x;
    const float wy = q.w * q.y;
    const float wz = q.w * q.z;

    const float r00 = 1.0f - 2.0f * (yy + zz);
    const float r01 = 2.0f * (xy - wz);
    const float r02 = 2.0f * (xz + wy);

    const float r10 = 2.0f * (xy + wz);
    const float r11 = 1.0f - 2.0f * (xx + zz);
    const float r12 = 2.0f * (yz - wx);

    const float r20 = 2.0f * (xz - wy);
    const float r21 = 2.0f * (yz + wx);
    const float r22 = 1.0f - 2.0f * (xx + yy);

    // Column-major layout.
    m[0] = r00;
    m[1] = r10;
    m[2] = r20;
    m[3] = 0.0f;

    m[4] = r01;
    m[5] = r11;
    m[6] = r21;
    m[7] = 0.0f;

    m[8] = r02;
    m[9] = r12;
    m[10] = r22;
    m[11] = 0.0f;
}

Vec3 extract_position(const float pose16[16]) {
    return Vec3{pose16[12], pose16[13], pose16[14]};
}

void compose_pose_quat(const Quat& rotation, const Vec3& position, float out_pose16[16]) {
    quat_to_pose_rotation(rotation, out_pose16);
    out_pose16[12] = position.x;
    out_pose16[13] = position.y;
    out_pose16[14] = position.z;
    out_pose16[15] = 1.0f;
}

Quat integrate_gyro(const Quat& base, const Vec3& gyro_rad_s, float dt_s) {
    const float omega = norm(gyro_rad_s);
    if (omega <= kEps || dt_s <= kEps) {
        return quat_normalize(base);
    }
    const float angle = omega * dt_s;
    const Vec3 axis = mul(gyro_rad_s, 1.0f / omega);
    const Quat delta = quat_from_axis_angle(axis, angle);
    return quat_normalize(quat_mul(base, delta));
}

}  // namespace

PoseStabilizer::PoseStabilizer(const PoseStabilizerConfig& config)
    : config_(config) {
    if (!std::isfinite(config_.translation_alpha)) {
        config_.translation_alpha = 0.22f;
    }
    if (!std::isfinite(config_.rotation_alpha)) {
        config_.rotation_alpha = 0.18f;
    }
    if (!std::isfinite(config_.max_prediction_horizon_s) || config_.max_prediction_horizon_s <= 0.0f) {
        config_.max_prediction_horizon_s = 0.15f;
    }
    if (!std::isfinite(config_.bias_alpha) || config_.bias_alpha <= 0.0f) {
        config_.bias_alpha = 0.03f;
    }
    if (config_.init_frames == 0u) {
        config_.init_frames = 4u;
    }
    reset();
}

void PoseStabilizer::reset() {
    initialized_ = false;
    last_timestamp_ns_ = 0u;
    frame_count_ = 0u;
    pose_quality_ = 0.0f;
    filtered_position_ = {{0.0f, 0.0f, 0.0f}};
    filtered_rotation_ = {{1.0f, 0.0f, 0.0f, 0.0f}};
    linear_velocity_ = {{0.0f, 0.0f, 0.0f}};
    angular_velocity_ = {{0.0f, 0.0f, 0.0f}};
    gyro_bias_ = {{0.0f, 0.0f, 0.0f}};
    accel_bias_ = {{0.0f, 0.0f, 0.0f}};
}

core::Status PoseStabilizer::update(
    const float raw_pose_16[16],
    const float gyro_xyz[3],
    const float accel_xyz[3],
    std::uint64_t timestamp_ns,
    float out_stabilized_pose_16[16],
    float* out_pose_quality) {
    if (out_stabilized_pose_16 == nullptr || out_pose_quality == nullptr ||
        raw_pose_16 == nullptr || gyro_xyz == nullptr || accel_xyz == nullptr) {
        return core::Status::kInvalidArgument;
    }
    if (!finite_pose(raw_pose_16) ||
        !finite(gyro_xyz[0]) || !finite(gyro_xyz[1]) || !finite(gyro_xyz[2]) ||
        !finite(accel_xyz[0]) || !finite(accel_xyz[1]) || !finite(accel_xyz[2])) {
        return core::Status::kInvalidArgument;
    }

    const Vec3 raw_position = extract_position(raw_pose_16);
    const Quat raw_rotation = quat_from_pose_matrix(raw_pose_16);
    const Vec3 raw_gyro = make_vec3(gyro_xyz);
    const Vec3 raw_accel = make_vec3(accel_xyz);

    if (!initialized_) {
        filtered_position_ = to_array(raw_position);
        filtered_rotation_ = {{raw_rotation.w, raw_rotation.x, raw_rotation.y, raw_rotation.z}};
        linear_velocity_ = {{0.0f, 0.0f, 0.0f}};
        angular_velocity_ = {{raw_gyro.x, raw_gyro.y, raw_gyro.z}};
        last_timestamp_ns_ = timestamp_ns;
        frame_count_ = 1u;
        initialized_ = true;
        pose_quality_ = config_.fast_init ? 0.60f : 0.40f;
        compose_pose_quat(raw_rotation, raw_position, out_stabilized_pose_16);
        *out_pose_quality = pose_quality_;
        return core::Status::kOk;
    }

    float dt_s = 1.0f / 120.0f;
    if (timestamp_ns > last_timestamp_ns_) {
        const std::uint64_t dt_ns = timestamp_ns - last_timestamp_ns_;
        dt_s = static_cast<float>(static_cast<double>(dt_ns) * 1e-9);
    }
    dt_s = clampf(dt_s, 1.0f / 500.0f, config_.max_prediction_horizon_s);

    const float warmup_scale = config_.fast_init ? 1.0f : 0.5f;
    const float bias_alpha = clampf(config_.bias_alpha * warmup_scale, 0.001f, 0.25f);
    if (frame_count_ < config_.init_frames + 2u) {
        Vec3 gyro_bias = make_vec3(gyro_bias_);
        Vec3 accel_bias = make_vec3(accel_bias_);
        gyro_bias = lerp(gyro_bias, raw_gyro, bias_alpha);
        accel_bias = lerp(accel_bias, raw_accel, bias_alpha);
        gyro_bias_ = to_array(gyro_bias);
        accel_bias_ = to_array(accel_bias);
    }

    const Vec3 corrected_gyro = sub(raw_gyro, make_vec3(gyro_bias_));
    const Vec3 corrected_accel = sub(raw_accel, make_vec3(accel_bias_));

    const Vec3 prev_position = make_vec3(filtered_position_);
    const Quat prev_rotation{
        filtered_rotation_[0], filtered_rotation_[1], filtered_rotation_[2], filtered_rotation_[3]};

    const Quat predicted_rotation = integrate_gyro(prev_rotation, corrected_gyro, dt_s);
    const Vec3 predicted_position = add(
        prev_position,
        add(
            mul(make_vec3(linear_velocity_), dt_s),
            mul(corrected_accel, 0.5f * dt_s * dt_s * 0.1f)));

    const float gyro_mag = norm(corrected_gyro);
    float translation_blend = config_.translation_alpha / (1.0f + 0.75f * gyro_mag);
    float rotation_blend = config_.rotation_alpha / (1.0f + 0.55f * gyro_mag);
    if (config_.use_ieskf) {
        // Reserve a stable tuning branch for high-precision mode.
        translation_blend *= 0.85f;
        rotation_blend *= 0.85f;
    }
    translation_blend = clampf(translation_blend, 0.05f, 0.90f);
    rotation_blend = clampf(rotation_blend, 0.04f, 0.90f);

    const Vec3 fused_position = lerp(predicted_position, raw_position, translation_blend);
    const Quat fused_rotation = quat_slerp(predicted_rotation, raw_rotation, rotation_blend);

    const Vec3 velocity = mul(sub(fused_position, prev_position), 1.0f / std::max(dt_s, 1e-4f));
    linear_velocity_ = to_array(velocity);
    angular_velocity_ = to_array(corrected_gyro);
    filtered_position_ = to_array(fused_position);
    filtered_rotation_ = {{fused_rotation.w, fused_rotation.x, fused_rotation.y, fused_rotation.z}};
    last_timestamp_ns_ = timestamp_ns;
    frame_count_ += 1u;

    const float jitter = norm(sub(raw_position, fused_position));
    const float accel_mag = norm(corrected_accel);
    const float accel_penalty = clampf(std::fabs(accel_mag - 9.81f) / 9.81f, 0.0f, 1.0f);
    const float motion_penalty = clampf(gyro_mag / 2.5f, 0.0f, 1.0f);
    const float jitter_penalty = clampf(jitter / 0.02f, 0.0f, 1.0f);
    const float dt_penalty = (dt_s > (1.0f / 30.0f))
        ? clampf((dt_s - (1.0f / 30.0f)) / 0.05f, 0.0f, 1.0f)
        : 0.0f;

    float quality = 1.0f
        - (0.35f * motion_penalty)
        - (0.25f * accel_penalty)
        - (0.25f * jitter_penalty)
        - (0.15f * dt_penalty);
    quality = clamp01(quality);

    if (frame_count_ <= config_.init_frames) {
        const float progress = static_cast<float>(frame_count_) / static_cast<float>(config_.init_frames);
        quality *= (0.45f + 0.55f * clamp01(progress));
    }

    pose_quality_ = quality;
    compose_pose_quat(fused_rotation, fused_position, out_stabilized_pose_16);
    *out_pose_quality = pose_quality_;
    return core::Status::kOk;
}

core::Status PoseStabilizer::predict(
    std::uint64_t target_timestamp_ns,
    float out_predicted_pose_16[16]) const {
    if (out_predicted_pose_16 == nullptr || !initialized_) {
        return core::Status::kInvalidArgument;
    }

    float dt_s = 0.0f;
    if (target_timestamp_ns > last_timestamp_ns_) {
        const std::uint64_t dt_ns = target_timestamp_ns - last_timestamp_ns_;
        dt_s = static_cast<float>(static_cast<double>(dt_ns) * 1e-9);
    }
    dt_s = clampf(dt_s, 0.0f, config_.max_prediction_horizon_s);

    const Vec3 position = add(make_vec3(filtered_position_), mul(make_vec3(linear_velocity_), dt_s));
    const Quat rotation = integrate_gyro(
        Quat{filtered_rotation_[0], filtered_rotation_[1], filtered_rotation_[2], filtered_rotation_[3]},
        make_vec3(angular_velocity_),
        dt_s);
    compose_pose_quat(rotation, position, out_predicted_pose_16);
    return core::Status::kOk;
}

}  // namespace tsdf
}  // namespace aether
