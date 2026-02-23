// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_EVIDENCE_PR_MATH_H
#define AETHER_EVIDENCE_PR_MATH_H

#include <cstdint>
#include <cmath>

namespace aether {
namespace evidence {

// ═══════════════════════════════════════════════════════════════════════
// StableLogistic: Piecewise sigmoid that avoids overflow for large |x|
// Port of Swift Core/Evidence/PRMath/StableLogistic.swift
// ═══════════════════════════════════════════════════════════════════════
// For x >= 0: σ(x) = 1 / (1 + exp(-x))
// For x < 0:  σ(x) = exp(x) / (1 + exp(x))
// Input clamped to [-80, 80] to prevent exp overflow.
// NaN → 0.5, +Inf → 1.0, -Inf → 0.0

struct StableLogistic {
    /// Piecewise-stable sigmoid. Numerically identical across platforms.
    static double sigmoid(double x) noexcept;

    /// Safe exp with clamping to [-80, 80].
    static double exp_safe(double x) noexcept;

    /// Log-sigmoid: log(σ(x)) = -log(1 + exp(-x))
    /// Numerically stable for all x. Preserves gradient information even for extreme values.
    /// For x >> 0: returns -exp(-x) (tiny negative, not exactly 0)
    /// For x << 0: returns x (linear, preserving gradient)
    static double log_sigmoid(double x) noexcept;

    /// Log-complement-sigmoid: log(1 - σ(x)) = -log(1 + exp(x))
    /// Stable for all x. Complements log_sigmoid.
    static double log_complement_sigmoid(double x) noexcept;
};

// ═══════════════════════════════════════════════════════════════════════
// PRMath: Mathematical utility facade
// Port of Swift Core/Evidence/PRMath/PRMath.swift
// ═══════════════════════════════════════════════════════════════════════

struct PRMath {
    /// Standard sigmoid using StableLogistic (canonical path).
    static double sigmoid(double x) noexcept;

    /// Sigmoid with threshold and transition width.
    /// Maps value near threshold to [0,1] with smooth transition.
    /// sigmoid01FromThreshold(threshold, threshold, width) = 0.5
    static double sigmoid01_from_threshold(double value, double threshold,
                                            double transition_width) noexcept;

    /// Inverted sigmoid for "lower is better" metrics.
    /// Returns 1.0 - sigmoid01_from_threshold(value, threshold, transition_width)
    static double sigmoid_inverted01_from_threshold(double value, double threshold,
                                                     double transition_width) noexcept;

    /// Log-sigmoid preserving gradient information in log space.
    static double log_sigmoid(double x) noexcept;

    /// Log of (1 - sigmoid(x)).
    static double log_complement_sigmoid(double x) noexcept;

    /// Safe log1p(exp(x)) — the "softplus" function.
    /// For x >> 0: returns x (avoids exp overflow)
    /// For x << 0: returns exp(x) (avoids log(1) = 0 loss)
    static double softplus(double x) noexcept;

    /// Safe exponential with clamping.
    static double exp_safe(double x) noexcept;

    /// Safe atan2 handling NaN/Inf inputs.
    static double atan2_safe(double y, double x) noexcept;

    /// Safe asin clamped to [-1, 1] domain.
    static double asin_safe(double x) noexcept;

    /// Safe sqrt returning 0 for negative inputs.
    static double sqrt_safe(double x) noexcept;

    /// Clamp value to [0, 1].
    static double clamp01(double x) noexcept;

    /// Clamp value to [lo, hi].
    static double clamp(double x, double lo, double hi) noexcept;

    /// Check if value is finite (not NaN, not Inf).
    static bool is_usable(double x) noexcept;
};

// ═══════════════════════════════════════════════════════════════════════
// QuantizerQ01: Type-safe [0,1] quantization
// Port of Swift Core/Evidence/PRMath/QuantizerQ01.swift
// ═══════════════════════════════════════════════════════════════════════

struct QuantizerQ01 {
    static constexpr double kScale = 1e12;
    static constexpr int64_t kScaleInt64 = 1'000'000'000'000LL;

    /// Quantize [0, 1] value to Int64. Clamps to valid range.
    static int64_t quantize(double value) noexcept;

    /// Dequantize Int64 back to Double.
    static double dequantize(int64_t q) noexcept;

    /// Check if two quantized values are within tolerance.
    static bool are_close(int64_t a, int64_t b, int64_t tolerance = 1) noexcept;
};

}  // namespace evidence
}  // namespace aether

#endif  // AETHER_EVIDENCE_PR_MATH_H
