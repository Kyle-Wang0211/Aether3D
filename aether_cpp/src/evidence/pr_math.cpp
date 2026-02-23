// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/evidence/pr_math.h"

#include <cmath>
#include <limits>

namespace aether {
namespace evidence {

// ═══════════════════════════════════════════════════════════════════════
// StableLogistic
// ═══════════════════════════════════════════════════════════════════════

double StableLogistic::exp_safe(double x) noexcept {
    // Clamp to [-80, 80] to prevent overflow (exp(80) ~ 5.5e34, well within double)
    if (x > 80.0) x = 80.0;
    if (x < -80.0) x = -80.0;
    return std::exp(x);
}

double StableLogistic::sigmoid(double x) noexcept {
    // Handle non-finite inputs deterministically
    if (std::isnan(x)) return 0.5;
    if (std::isinf(x)) return x > 0.0 ? 1.0 : 0.0;

    // Clamp to prevent overflow
    if (x > 80.0) x = 80.0;
    if (x < -80.0) x = -80.0;

    // Piecewise formula for numerical stability:
    // For x >= 0: 1 / (1 + exp(-x))  -- exp(-x) in (0, 1], no overflow
    // For x < 0:  exp(x) / (1 + exp(x)) -- exp(x) in (0, 1), no overflow
    if (x >= 0.0) {
        const double e = std::exp(-x);
        return 1.0 / (1.0 + e);
    } else {
        const double e = std::exp(x);
        return e / (1.0 + e);
    }
}

double StableLogistic::log_sigmoid(double x) noexcept {
    // log(σ(x)) = -log(1 + exp(-x)) = -softplus(-x)
    // For x >= 0: -log(1 + exp(-x)), exp(-x) is small, stable
    // For x < 0: x - log(1 + exp(x)), avoids log(0)
    if (!std::isfinite(x)) {
        if (x != x) return -std::numeric_limits<double>::infinity(); // NaN
        return x > 0.0 ? 0.0 : -std::numeric_limits<double>::infinity();
    }
    if (x >= 0.0) {
        double em = std::exp(-x);
        return -std::log1p(em); // log1p for precision when em is small
    } else {
        double ep = std::exp(x);
        return x - std::log1p(ep); // x + log(σ(x)/exp(x))
    }
}

double StableLogistic::log_complement_sigmoid(double x) noexcept {
    // log(1 - σ(x)) = log(σ(-x)) = log_sigmoid(-x)
    return log_sigmoid(-x);
}

// ═══════════════════════════════════════════════════════════════════════
// PRMath
// ═══════════════════════════════════════════════════════════════════════

double PRMath::sigmoid(double x) noexcept {
    return StableLogistic::sigmoid(x);
}

double PRMath::log_sigmoid(double x) noexcept {
    return StableLogistic::log_sigmoid(x);
}

double PRMath::log_complement_sigmoid(double x) noexcept {
    return StableLogistic::log_complement_sigmoid(x);
}

double PRMath::softplus(double x) noexcept {
    // softplus(x) = log(1 + exp(x))
    // For x > 20: return x (exp(x) dominates, log(exp(x)) = x)
    // For x < -20: return exp(x) (log(1+tiny) ≈ tiny)
    // Otherwise: log1p(exp(x))
    if (x > 20.0) return x;
    if (x < -20.0) return std::exp(x);
    return std::log1p(std::exp(x));
}

double PRMath::sigmoid01_from_threshold(double value, double threshold,
                                         double transition_width) noexcept {
    if (!is_usable(value) || !is_usable(threshold)) return 0.5;
    if (!is_usable(transition_width) || transition_width <= 0.0) {
        // Hard step
        return value >= threshold ? 1.0 : 0.0;
    }
    // Map to sigmoid: when value == threshold -> input is 0 -> sigmoid returns 0.5
    const double scaled = (value - threshold) / transition_width;
    return StableLogistic::sigmoid(scaled);
}

double PRMath::sigmoid_inverted01_from_threshold(double value, double threshold,
                                                   double transition_width) noexcept {
    return 1.0 - sigmoid01_from_threshold(value, threshold, transition_width);
}

double PRMath::exp_safe(double x) noexcept {
    return StableLogistic::exp_safe(x);
}

double PRMath::atan2_safe(double y, double x) noexcept {
    if (std::isnan(y) || std::isnan(x)) return 0.0;
    if (std::isinf(y) || std::isinf(x)) return 0.0;
    return std::atan2(y, x);
}

double PRMath::asin_safe(double x) noexcept {
    if (std::isnan(x)) return 0.0;
    // Clamp to valid domain
    if (x > 1.0) x = 1.0;
    if (x < -1.0) x = -1.0;
    return std::asin(x);
}

double PRMath::sqrt_safe(double x) noexcept {
    if (std::isnan(x) || x < 0.0) return 0.0;
    return std::sqrt(x);
}

double PRMath::clamp01(double x) noexcept {
    if (std::isnan(x)) return 0.0;
    if (x < 0.0) return 0.0;
    if (x > 1.0) return 1.0;
    return x;
}

double PRMath::clamp(double x, double lo, double hi) noexcept {
    if (std::isnan(x)) return lo;
    if (x < lo) return lo;
    if (x > hi) return hi;
    return x;
}

bool PRMath::is_usable(double x) noexcept {
    return std::isfinite(x);
}

// ═══════════════════════════════════════════════════════════════════════
// QuantizerQ01
// ═══════════════════════════════════════════════════════════════════════

int64_t QuantizerQ01::quantize(double value) noexcept {
    // Clamp to valid range (defensive)
    double clamped = value;
    if (clamped < 0.0) clamped = 0.0;
    if (clamped > 1.0) clamped = 1.0;
    // Round half away from zero (deterministic, matches Swift .toNearestOrAwayFromZero)
    return static_cast<int64_t>(std::round(clamped * kScale));
}

double QuantizerQ01::dequantize(int64_t q) noexcept {
    return static_cast<double>(q) / kScale;
}

bool QuantizerQ01::are_close(int64_t a, int64_t b, int64_t tolerance) noexcept {
    int64_t diff = a - b;
    if (diff < 0) diff = -diff;
    return diff <= tolerance;
}

}  // namespace evidence
}  // namespace aether
