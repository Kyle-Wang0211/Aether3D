// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_QUALITY_PHOTOMETRIC_CHECKER_H
#define AETHER_QUALITY_PHOTOMETRIC_CHECKER_H

#ifdef __cplusplus

#include <cstddef>
#include <deque>

namespace aether {
namespace quality {

struct LabColor {
    double l{0.0};
    double a{0.0};
    double b{0.0};
};

struct PhotometricResult {
    double luminance_variance{0.0};
    double lab_variance{0.0};
    double exposure_consistency{1.0};
    bool is_consistent{true};
    double confidence{0.0};
};

class PhotometricChecker {
public:
    explicit PhotometricChecker(std::size_t window_size = 10u);

    void reset();
    void update(double luminance, double exposure, const LabColor& lab);

    PhotometricResult check(
        double max_luminance_variance,
        double max_lab_variance,
        double min_exposure_consistency) const;

    static double ciede2000(const LabColor& lab1, const LabColor& lab2);

private:
    std::size_t window_size_;
    std::deque<double> luminance_history_;
    std::deque<double> exposure_history_;
    std::deque<LabColor> lab_history_;

    template <typename T>
    void append_capped(std::deque<T>* values, const T& v) {
        values->push_back(v);
        while (values->size() > window_size_) {
            values->pop_front();
        }
    }

    static double variance(const std::deque<double>& values);
    static double consistency_ratio(const std::deque<double>& values);
    static double lab_variance(const std::deque<LabColor>& values);
};

}  // namespace quality
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_QUALITY_PHOTOMETRIC_CHECKER_H
