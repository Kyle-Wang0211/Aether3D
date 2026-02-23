// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/evidence/pr_math.h"

#include <cmath>
#include <cstdio>
#include <initializer_list>
#include <limits>

namespace {

bool approx(double a, double b, double eps = 1e-12) {
    return std::fabs(a - b) < eps;
}

}  // namespace

int main() {
    int failed = 0;
    using namespace aether::evidence;

    // -- StableLogistic::sigmoid --

    // sigmoid(0) = 0.5 exactly
    if (!approx(StableLogistic::sigmoid(0.0), 0.5)) {
        std::fprintf(stderr, "sigmoid(0) != 0.5: got %.17g\n", StableLogistic::sigmoid(0.0));
        ++failed;
    }

    // Symmetry: sigmoid(-x) = 1 - sigmoid(x)
    for (double x : {0.1, 1.0, 5.0, 20.0, 79.0}) {
        double s_pos = StableLogistic::sigmoid(x);
        double s_neg = StableLogistic::sigmoid(-x);
        if (!approx(s_pos + s_neg, 1.0, 1e-14)) {
            std::fprintf(stderr, "sigmoid symmetry broken at x=%.1f: sum=%.17g\n", x, s_pos + s_neg);
            ++failed;
        }
    }

    // Monotonicity: sigmoid(x) < sigmoid(x + 0.01) for all x
    for (double x = -79.0; x < 79.0; x += 0.5) {
        if (StableLogistic::sigmoid(x) > StableLogistic::sigmoid(x + 0.01)) {
            std::fprintf(stderr, "sigmoid not monotone at x=%.1f\n", x);
            ++failed;
            break;
        }
    }

    // NaN -> 0.5
    if (!approx(StableLogistic::sigmoid(std::numeric_limits<double>::quiet_NaN()), 0.5)) {
        std::fprintf(stderr, "sigmoid(NaN) != 0.5\n");
        ++failed;
    }

    // +Inf -> 1.0
    if (!approx(StableLogistic::sigmoid(std::numeric_limits<double>::infinity()), 1.0)) {
        std::fprintf(stderr, "sigmoid(+Inf) != 1.0\n");
        ++failed;
    }

    // -Inf -> 0.0
    if (!approx(StableLogistic::sigmoid(-std::numeric_limits<double>::infinity()), 0.0)) {
        std::fprintf(stderr, "sigmoid(-Inf) != 0.0\n");
        ++failed;
    }

    // Range check: sigmoid output always in (0, 1) for moderate inputs.
    // For |x| > ~36, double-precision rounding can push sigmoid to exactly 0 or 1,
    // so we only enforce strict (0, 1) for |x| <= 36.
    for (double x = -36.0; x <= 36.0; x += 1.0) {
        double s = StableLogistic::sigmoid(x);
        if (s <= 0.0 || s >= 1.0) {
            std::fprintf(stderr, "sigmoid(%.1f) out of (0,1): %.17g\n", x, s);
            ++failed;
            break;
        }
    }

    // -- PRMath::sigmoid01_from_threshold --

    // At threshold, output should be 0.5
    if (!approx(PRMath::sigmoid01_from_threshold(0.5, 0.5, 0.1), 0.5)) {
        std::fprintf(stderr, "sigmoid01_from_threshold at threshold != 0.5\n");
        ++failed;
    }

    // Far above threshold -> 1.0
    double above = PRMath::sigmoid01_from_threshold(10.0, 0.5, 0.1);
    if (above < 0.99) {
        std::fprintf(stderr, "sigmoid01_from_threshold far above < 0.99: %.6f\n", above);
        ++failed;
    }

    // Far below threshold -> 0.0
    double below = PRMath::sigmoid01_from_threshold(-10.0, 0.5, 0.1);
    if (below > 0.01) {
        std::fprintf(stderr, "sigmoid01_from_threshold far below > 0.01: %.6f\n", below);
        ++failed;
    }

    // -- PRMath safe functions --

    if (!approx(PRMath::atan2_safe(0.0, 1.0), 0.0)) {
        std::fprintf(stderr, "atan2_safe(0,1) != 0\n");
        ++failed;
    }

    if (PRMath::atan2_safe(std::numeric_limits<double>::quiet_NaN(), 1.0) != 0.0) {
        std::fprintf(stderr, "atan2_safe(NaN,1) != 0\n");
        ++failed;
    }

    if (!approx(PRMath::asin_safe(1.5), PRMath::asin_safe(1.0))) {
        std::fprintf(stderr, "asin_safe(1.5) not clamped to asin(1.0)\n");
        ++failed;
    }

    if (PRMath::sqrt_safe(-1.0) != 0.0) {
        std::fprintf(stderr, "sqrt_safe(-1) != 0\n");
        ++failed;
    }

    if (!approx(PRMath::clamp01(1.5), 1.0)) {
        std::fprintf(stderr, "clamp01(1.5) != 1.0\n");
        ++failed;
    }

    if (!approx(PRMath::clamp01(-0.5), 0.0)) {
        std::fprintf(stderr, "clamp01(-0.5) != 0.0\n");
        ++failed;
    }

    if (!PRMath::is_usable(42.0)) {
        std::fprintf(stderr, "is_usable(42) should be true\n");
        ++failed;
    }

    if (PRMath::is_usable(std::numeric_limits<double>::quiet_NaN())) {
        std::fprintf(stderr, "is_usable(NaN) should be false\n");
        ++failed;
    }

    // -- StableLogistic::log_sigmoid --

    // log_sigmoid(0) = -log(2) ≈ -0.693147
    {
        double ls0 = StableLogistic::log_sigmoid(0.0);
        double expected = -std::log(2.0);
        if (!approx(ls0, expected, 1e-14)) {
            std::fprintf(stderr, "log_sigmoid(0) != -log(2): got %.17g, expected %.17g\n", ls0, expected);
            ++failed;
        }
    }

    // log_sigmoid(100) should be approximately -exp(-100), NOT exactly 0.0
    {
        double ls100 = StableLogistic::log_sigmoid(100.0);
        double expected = -std::exp(-100.0);
        if (ls100 == 0.0) {
            std::fprintf(stderr, "log_sigmoid(100) is exactly 0.0 — precision lost!\n");
            ++failed;
        }
        if (!approx(ls100, expected, 1e-50)) {
            std::fprintf(stderr, "log_sigmoid(100) != -exp(-100): got %.17g, expected %.17g\n", ls100, expected);
            ++failed;
        }
    }

    // log_sigmoid(-100) should be approximately -100 (linear region)
    {
        double lsn100 = StableLogistic::log_sigmoid(-100.0);
        if (!approx(lsn100, -100.0, 1e-10)) {
            std::fprintf(stderr, "log_sigmoid(-100) != -100: got %.17g\n", lsn100);
            ++failed;
        }
    }

    // log_sigmoid + log_complement_sigmoid relationship:
    // log_complement_sigmoid(x) = log_sigmoid(-x) by definition
    // Also verify: log_sigmoid(x) + log_complement_sigmoid(x) = log(σ(x) * (1-σ(x)))
    for (double x : {-50.0, -10.0, -1.0, 0.0, 1.0, 10.0, 50.0}) {
        double ls = StableLogistic::log_sigmoid(x);
        double lcs = StableLogistic::log_complement_sigmoid(x);
        // log_complement_sigmoid(x) = log_sigmoid(-x)
        double ls_neg = StableLogistic::log_sigmoid(-x);
        if (!approx(lcs, ls_neg, 1e-14)) {
            std::fprintf(stderr, "log_complement_sigmoid(%.1f) != log_sigmoid(%.1f): got %.17g vs %.17g\n",
                         x, -x, lcs, ls_neg);
            ++failed;
        }
        // The sum log(σ(x)) + log(1-σ(x)) should be negative for all finite x
        double sum = ls + lcs;
        if (sum > 0.0) {
            std::fprintf(stderr, "log_sigmoid(%.1f) + log_complement_sigmoid(%.1f) > 0: %.17g\n",
                         x, x, sum);
            ++failed;
        }
    }

    // NaN handling for log_sigmoid: should return -infinity
    {
        double ls_nan = StableLogistic::log_sigmoid(std::numeric_limits<double>::quiet_NaN());
        if (!std::isinf(ls_nan) || ls_nan > 0.0) {
            std::fprintf(stderr, "log_sigmoid(NaN) should be -inf: got %.17g\n", ls_nan);
            ++failed;
        }
    }

    // +Inf -> 0.0
    {
        double ls_inf = StableLogistic::log_sigmoid(std::numeric_limits<double>::infinity());
        if (ls_inf != 0.0) {
            std::fprintf(stderr, "log_sigmoid(+Inf) should be 0.0: got %.17g\n", ls_inf);
            ++failed;
        }
    }

    // -Inf -> -Inf
    {
        double ls_ninf = StableLogistic::log_sigmoid(-std::numeric_limits<double>::infinity());
        if (!std::isinf(ls_ninf) || ls_ninf > 0.0) {
            std::fprintf(stderr, "log_sigmoid(-Inf) should be -inf: got %.17g\n", ls_ninf);
            ++failed;
        }
    }

    // Precision preservation: log_sigmoid must preserve MORE precision bits than log(sigmoid(x))
    // For large x, log(sigmoid(x)) loses all precision because sigmoid(x) rounds to 1.0
    {
        double x_large = 50.0;
        double naive = std::log(StableLogistic::sigmoid(x_large));
        double stable = StableLogistic::log_sigmoid(x_large);
        // naive will be exactly 0.0 because sigmoid(50) rounds to 1.0 in double
        // stable should be approximately -exp(-50) ≈ -1.93e-22
        if (naive != 0.0) {
            // If naive is not 0.0, the test assumption is wrong for this platform,
            // but stable should still be more accurate
            std::fprintf(stderr, "NOTE: std::log(sigmoid(50)) = %.17g (expected 0.0)\n", naive);
        }
        if (stable == 0.0) {
            std::fprintf(stderr, "log_sigmoid(50) lost precision — got exactly 0.0\n");
            ++failed;
        }
        // For negative extreme: log(sigmoid(-50)) vs log_sigmoid(-50)
        double naive_neg = std::log(StableLogistic::sigmoid(-50.0));
        double stable_neg = StableLogistic::log_sigmoid(-50.0);
        // stable_neg should be approximately -50.0
        double err_stable = std::fabs(stable_neg - (-50.0));
        double err_naive = std::fabs(naive_neg - (-50.0));
        // stable should be at least as good or better than naive
        if (err_stable > err_naive + 1e-10) {
            std::fprintf(stderr, "log_sigmoid(-50) less precise than naive: stable_err=%.6g naive_err=%.6g\n",
                         err_stable, err_naive);
            ++failed;
        }
    }

    // Monotonicity of log_sigmoid
    for (double x = -99.0; x < 99.0; x += 1.0) {
        if (StableLogistic::log_sigmoid(x) > StableLogistic::log_sigmoid(x + 0.01)) {
            std::fprintf(stderr, "log_sigmoid not monotone at x=%.1f\n", x);
            ++failed;
            break;
        }
    }

    // log_sigmoid always returns <= 0 for finite inputs
    for (double x : {-100.0, -10.0, 0.0, 10.0, 100.0}) {
        double ls = StableLogistic::log_sigmoid(x);
        if (ls > 0.0) {
            std::fprintf(stderr, "log_sigmoid(%.1f) > 0: %.17g\n", x, ls);
            ++failed;
        }
    }

    // -- PRMath::softplus --

    // softplus(0) = log(2) ≈ 0.693147
    {
        double sp0 = PRMath::softplus(0.0);
        double expected = std::log(2.0);
        if (!approx(sp0, expected, 1e-14)) {
            std::fprintf(stderr, "softplus(0) != log(2): got %.17g, expected %.17g\n", sp0, expected);
            ++failed;
        }
    }

    // softplus(100) ≈ 100.0
    {
        double sp100 = PRMath::softplus(100.0);
        if (!approx(sp100, 100.0, 1e-6)) {
            std::fprintf(stderr, "softplus(100) != 100: got %.17g\n", sp100);
            ++failed;
        }
    }

    // softplus(-100) ≈ exp(-100) ≈ 3.72e-44
    {
        double spn100 = PRMath::softplus(-100.0);
        double expected = std::exp(-100.0);
        if (!approx(spn100, expected, 1e-50)) {
            std::fprintf(stderr, "softplus(-100) != exp(-100): got %.17g, expected %.17g\n", spn100, expected);
            ++failed;
        }
    }

    // softplus is always positive
    for (double x : {-100.0, -10.0, 0.0, 10.0, 100.0}) {
        double sp = PRMath::softplus(x);
        if (sp <= 0.0) {
            std::fprintf(stderr, "softplus(%.1f) <= 0: %.17g\n", x, sp);
            ++failed;
        }
    }

    // softplus monotonicity
    for (double x = -99.0; x < 99.0; x += 1.0) {
        if (PRMath::softplus(x) > PRMath::softplus(x + 0.01)) {
            std::fprintf(stderr, "softplus not monotone at x=%.1f\n", x);
            ++failed;
            break;
        }
    }

    // Relationship: log_sigmoid(x) = -softplus(-x)
    for (double x : {-50.0, -10.0, -1.0, 0.0, 1.0, 10.0, 50.0}) {
        double ls = PRMath::log_sigmoid(x);
        double sp = PRMath::softplus(-x);
        if (!approx(ls, -sp, 1e-14)) {
            std::fprintf(stderr, "log_sigmoid(%.1f) != -softplus(%.1f): got %.17g vs %.17g\n",
                         x, -x, ls, -sp);
            ++failed;
        }
    }

    // -- QuantizerQ01 --

    // Roundtrip
    double test_val = 0.123456789012;
    int64_t q = QuantizerQ01::quantize(test_val);
    double recovered = QuantizerQ01::dequantize(q);
    if (!approx(test_val, recovered, 1e-12)) {
        std::fprintf(stderr, "QuantizerQ01 roundtrip: input=%.15g recovered=%.15g\n", test_val, recovered);
        ++failed;
    }

    // Boundary: quantize(0) = 0, quantize(1) = 10^12
    if (QuantizerQ01::quantize(0.0) != 0) {
        std::fprintf(stderr, "QuantizerQ01::quantize(0) != 0\n");
        ++failed;
    }
    if (QuantizerQ01::quantize(1.0) != QuantizerQ01::kScaleInt64) {
        std::fprintf(stderr, "QuantizerQ01::quantize(1) != kScaleInt64\n");
        ++failed;
    }

    // Clamping
    if (QuantizerQ01::quantize(-0.5) != 0) {
        std::fprintf(stderr, "QuantizerQ01::quantize(-0.5) should clamp to 0\n");
        ++failed;
    }
    if (QuantizerQ01::quantize(1.5) != QuantizerQ01::kScaleInt64) {
        std::fprintf(stderr, "QuantizerQ01::quantize(1.5) should clamp to kScaleInt64\n");
        ++failed;
    }

    // are_close
    if (!QuantizerQ01::are_close(100, 101, 1)) {
        std::fprintf(stderr, "are_close(100, 101, 1) should be true\n");
        ++failed;
    }
    if (QuantizerQ01::are_close(100, 103, 1)) {
        std::fprintf(stderr, "are_close(100, 103, 1) should be false\n");
        ++failed;
    }

    std::fprintf(stdout, "pr_math_test: %d failures\n", failed);
    return failed;
}
