// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/quality/photometric_checker.h"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <deque>

namespace aether {
namespace quality {

PhotometricChecker::PhotometricChecker(std::size_t window_size)
    : window_size_(std::max<std::size_t>(1u, window_size)) {}

void PhotometricChecker::reset() {
    luminance_history_.clear();
    exposure_history_.clear();
    lab_history_.clear();
}

void PhotometricChecker::update(double luminance, double exposure, const LabColor& lab) {
    append_capped(&luminance_history_, luminance);
    append_capped(&exposure_history_, exposure);
    append_capped(&lab_history_, lab);
}

double PhotometricChecker::variance(const std::deque<double>& values) {
    if (values.size() < 2u) {
        return 0.0;
    }
    double mean = 0.0;
    for (double v : values) {
        mean += v;
    }
    mean /= static_cast<double>(values.size());

    double sq_sum = 0.0;
    for (double v : values) {
        const double d = v - mean;
        sq_sum += d * d;
    }
    return sq_sum / static_cast<double>(values.size());
}

double PhotometricChecker::consistency_ratio(const std::deque<double>& values) {
    if (values.size() < 2u) {
        return 1.0;
    }
    const auto mm = std::minmax_element(values.begin(), values.end());
    const double min_v = *mm.first;
    const double max_v = *mm.second;
    if (max_v <= 0.0 || !std::isfinite(min_v) || !std::isfinite(max_v)) {
        return 1.0;
    }
    return min_v / max_v;
}

double PhotometricChecker::lab_variance(const std::deque<LabColor>& values) {
    if (values.size() < 2u) {
        return 0.0;
    }

    double mean_l = 0.0;
    double mean_a = 0.0;
    double mean_b = 0.0;
    for (const LabColor& v : values) {
        mean_l += v.l;
        mean_a += v.a;
        mean_b += v.b;
    }
    const double inv_n = 1.0 / static_cast<double>(values.size());
    mean_l *= inv_n;
    mean_a *= inv_n;
    mean_b *= inv_n;

    double delta_e_sum = 0.0;
    for (const LabColor& v : values) {
        const double dl = v.l - mean_l;
        const double da = v.a - mean_a;
        const double db = v.b - mean_b;
        delta_e_sum += std::sqrt(dl * dl + da * da + db * db);
    }
    return delta_e_sum * inv_n;
}

double PhotometricChecker::ciede2000(const LabColor& lab1, const LabColor& lab2) {
    // CIEDE2000 implementation following Sharma, Wu, Dalal (2005).
    constexpr double kPi = 3.14159265358979323846;

    const double L1 = lab1.l, a1 = lab1.a, b1 = lab1.b;
    const double L2 = lab2.l, a2 = lab2.a, b2 = lab2.b;

    const double C1_ab = std::sqrt(a1 * a1 + b1 * b1);
    const double C2_ab = std::sqrt(a2 * a2 + b2 * b2);
    const double C_ab_bar = (C1_ab + C2_ab) / 2.0;

    const double C_ab_bar_7 = std::pow(C_ab_bar, 7.0);
    const double G = 0.5 * (1.0 - std::sqrt(C_ab_bar_7 / (C_ab_bar_7 + std::pow(25.0, 7.0))));

    const double a1_prime = a1 * (1.0 + G);
    const double a2_prime = a2 * (1.0 + G);

    const double C1_prime = std::sqrt(a1_prime * a1_prime + b1 * b1);
    const double C2_prime = std::sqrt(a2_prime * a2_prime + b2 * b2);

    auto compute_h = [](double b_val, double a_prime) -> double {
        if (std::fabs(b_val) < 1e-14 && std::fabs(a_prime) < 1e-14) {
            return 0.0;
        }
        double h = std::atan2(b_val, a_prime) * 180.0 / 3.14159265358979323846;
        if (h < 0.0) h += 360.0;
        return h;
    };

    const double h1_prime = compute_h(b1, a1_prime);
    const double h2_prime = compute_h(b2, a2_prime);

    // Delta values
    const double dL_prime = L2 - L1;
    const double dC_prime = C2_prime - C1_prime;

    double dh_prime = 0.0;
    if (C1_prime * C2_prime < 1e-14) {
        dh_prime = 0.0;
    } else {
        double diff = h2_prime - h1_prime;
        if (diff > 180.0) diff -= 360.0;
        else if (diff < -180.0) diff += 360.0;
        dh_prime = diff;
    }

    const double dH_prime = 2.0 * std::sqrt(C1_prime * C2_prime) *
                            std::sin(dh_prime * kPi / 360.0);

    // Arithmetic means
    const double L_bar_prime = (L1 + L2) / 2.0;
    const double C_bar_prime = (C1_prime + C2_prime) / 2.0;

    double h_bar_prime = 0.0;
    if (C1_prime * C2_prime < 1e-14) {
        h_bar_prime = h1_prime + h2_prime;
    } else {
        if (std::fabs(h1_prime - h2_prime) <= 180.0) {
            h_bar_prime = (h1_prime + h2_prime) / 2.0;
        } else {
            if ((h1_prime + h2_prime) < 360.0) {
                h_bar_prime = (h1_prime + h2_prime + 360.0) / 2.0;
            } else {
                h_bar_prime = (h1_prime + h2_prime - 360.0) / 2.0;
            }
        }
    }

    const double T = 1.0
        - 0.17 * std::cos((h_bar_prime - 30.0) * kPi / 180.0)
        + 0.24 * std::cos((2.0 * h_bar_prime) * kPi / 180.0)
        + 0.32 * std::cos((3.0 * h_bar_prime + 6.0) * kPi / 180.0)
        - 0.20 * std::cos((4.0 * h_bar_prime - 63.0) * kPi / 180.0);

    const double L_bar_50 = L_bar_prime - 50.0;
    const double SL = 1.0 + 0.015 * (L_bar_50 * L_bar_50) /
                       std::sqrt(20.0 + L_bar_50 * L_bar_50);
    const double SC = 1.0 + 0.045 * C_bar_prime;
    const double SH = 1.0 + 0.015 * C_bar_prime * T;

    const double C_bar_prime_7 = std::pow(C_bar_prime, 7.0);
    const double RC = 2.0 * std::sqrt(C_bar_prime_7 / (C_bar_prime_7 + std::pow(25.0, 7.0)));

    const double theta_deg = 30.0 * std::exp(-((h_bar_prime - 275.0) / 25.0) *
                                               ((h_bar_prime - 275.0) / 25.0));
    const double RT = -std::sin(2.0 * theta_deg * kPi / 180.0) * RC;

    const double term_L = dL_prime / SL;
    const double term_C = dC_prime / SC;
    const double term_H = dH_prime / SH;

    const double dE = std::sqrt(term_L * term_L + term_C * term_C +
                                term_H * term_H + RT * term_C * term_H);
    return dE;
}

PhotometricResult PhotometricChecker::check(
    double max_luminance_variance,
    double max_lab_variance,
    double min_exposure_consistency) const {
    PhotometricResult out{};

    out.luminance_variance = variance(luminance_history_);
    out.lab_variance = lab_variance(lab_history_);
    out.exposure_consistency = consistency_ratio(exposure_history_);

    if (!std::isfinite(out.luminance_variance)) {
        out.luminance_variance = 0.0;
    }
    if (!std::isfinite(out.lab_variance)) {
        out.lab_variance = 0.0;
    }
    if (!std::isfinite(out.exposure_consistency)) {
        out.exposure_consistency = 1.0;
    }

    out.is_consistent =
        out.luminance_variance <= max_luminance_variance &&
        out.lab_variance <= max_lab_variance &&
        out.exposure_consistency >= min_exposure_consistency;

    out.confidence = std::min(1.0, static_cast<double>(luminance_history_.size()) / static_cast<double>(window_size_));
    return out;
}

}  // namespace quality
}  // namespace aether
