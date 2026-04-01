// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// student_t_primitive.h — Student-t splatting primitive (SSS, CVPR 2025).
// Heavy-tailed alternative to Gaussian: alpha = opacity × (1 + power/nu)^(-(nu+1)/2)
// where nu is the degrees-of-freedom parameter (nu > 2).
// Achieves 82% fewer primitives at same quality vs standard Gaussian.
// Reference: "Student-t Splatting" — CVPR 2025 Best Paper Honorable Mention

#ifndef AETHER_TRAINING_STUDENT_T_PRIMITIVE_H
#define AETHER_TRAINING_STUDENT_T_PRIMITIVE_H

#ifdef __cplusplus

#include <algorithm>
#include <cmath>
#include <cstdint>

namespace aether {
namespace training {

// ═══════════════════════════════════════════════════════════════════════
// Student-t Primitive: 15 parameters per splat
// ═══════════════════════════════════════════════════════════════════════
// Standard Gaussian: 14 params [pos(3), color(3), opacity(1), scale(3), rot(4)]
// Student-t adds:    15 params [pos(3), color(3), opacity(1), scale(3), rot(4), log_nu(1)]
// nu = exp(log_nu) + 2.0  (ensures nu > 2 for finite variance)

constexpr std::size_t kStudentTParamsPerPrimitive = 15;

/// Compute Student-t alpha from Mahalanobis distance and nu.
/// Replaces the Gaussian exp(power) with (1 + power/nu)^(-(nu+1)/2).
/// @param power     Mahalanobis distance (negative, from conic evaluation)
/// @param opacity   Base opacity (after sigmoid)
/// @param nu        Degrees of freedom (> 2)
/// @return Alpha value for compositing [0, 1)
inline float student_t_alpha(float power, float opacity, float nu) noexcept {
    // Guard: power should be <= 0 for valid primitives
    if (power > 0.0f || power < -100.0f) return 0.0f;
    if (nu <= 2.0f) nu = 2.001f;  // Safety: ensure defined variance

    // alpha = opacity × (1 + |power| / nu)^(-(nu+1)/2)
    float ratio = 1.0f + (-power) / nu;  // ratio ≥ 1 since power ≤ 0
    float exponent = -(nu + 1.0f) / 2.0f;
    float t_val = std::pow(ratio, exponent);

    return std::clamp(opacity * t_val, 0.0f, 0.99f);
}

/// Compute d(alpha)/d(power) for Student-t backward pass.
/// d/d_power = opacity × (-(nu+1)/(2×nu)) × (1 + |power|/nu)^(-(nu+3)/2)
inline float student_t_dalpha_dpower(float power, float opacity, float nu) noexcept {
    if (power > 0.0f || power < -100.0f) return 0.0f;
    if (nu <= 2.0f) nu = 2.001f;

    float abs_power = -power;
    float ratio = 1.0f + abs_power / nu;
    float exponent = -(nu + 3.0f) / 2.0f;
    float coeff = -(nu + 1.0f) / (2.0f * nu);

    // The derivative includes a negative sign from chain rule (d|power|/dpower = -1)
    // so overall: d(alpha)/d(power) = opacity × (nu+1)/(2nu) × ratio^(-(nu+3)/2)
    return opacity * (-coeff) * std::pow(ratio, exponent);
}

/// Compute d(alpha)/d(nu) for Student-t backward pass.
/// This gradient allows the network to learn the optimal tail heaviness.
inline float student_t_dalpha_dnu(float power, float opacity, float nu) noexcept {
    if (power > 0.0f || power < -100.0f) return 0.0f;
    if (nu <= 2.0f) nu = 2.001f;

    float abs_power = -power;
    float ratio = 1.0f + abs_power / nu;
    float log_ratio = std::log(ratio);
    float exponent = -(nu + 1.0f) / 2.0f;
    float base_val = std::pow(ratio, exponent);

    // d(alpha)/d(nu) = opacity × d/d(nu)[ ratio^(exponent) ]
    // Using: d/dnu[a^b] = a^b × (b'×ln(a) + b×a'/a)
    // where a = ratio = 1 + |p|/nu, b = -(nu+1)/2
    // a' = d/dnu(1 + |p|/nu) = -|p|/nu²
    // b' = d/dnu(-(nu+1)/2) = -1/2
    float a_prime = -abs_power / (nu * nu);
    float b_prime = -0.5f;

    float dval = base_val * (b_prime * log_ratio + exponent * a_prime / ratio);
    return opacity * dval;
}

/// Convert log_nu parameter to actual nu value.
/// nu = exp(log_nu) + 2.0  (ensures nu > 2)
inline float log_nu_to_nu(float log_nu) noexcept {
    return std::exp(std::clamp(log_nu, -5.0f, 5.0f)) + 2.0f;
}

/// Gradient of nu w.r.t. log_nu (for chain rule).
/// d(nu)/d(log_nu) = exp(log_nu) = nu - 2
inline float dnu_dlog_nu(float log_nu) noexcept {
    return std::exp(std::clamp(log_nu, -5.0f, 5.0f));
}

}  // namespace training
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_TRAINING_STUDENT_T_PRIMITIVE_H
