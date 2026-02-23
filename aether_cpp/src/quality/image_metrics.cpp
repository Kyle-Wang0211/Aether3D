// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/quality/image_metrics.h"

#include <algorithm>
#include <cmath>
#include <cstdint>

namespace aether {
namespace quality {

aether::core::Status laplacian_variance(
    const std::uint8_t* bytes,
    int width,
    int height,
    int row_bytes,
    double* out_variance) {
    if (out_variance == nullptr) {
        return aether::core::Status::kInvalidArgument;
    }
    *out_variance = 0.0;

    if (bytes == nullptr || width < 3 || height < 3 || row_bytes < width) {
        return aether::core::Status::kInvalidArgument;
    }

    // Welford online variance: single-pass, O(1) memory
    std::size_t n = 0;
    double mean = 0.0;
    double m2 = 0.0;

    for (int y = 1; y < height - 1; ++y) {
        for (int x = 1; x < width - 1; ++x) {
            const int base = y * row_bytes + x;
            const double v = static_cast<double>(bytes[base - row_bytes]) +
                static_cast<double>(bytes[base - 1]) -
                4.0 * static_cast<double>(bytes[base]) +
                static_cast<double>(bytes[base + 1]) +
                static_cast<double>(bytes[base + row_bytes]);
            ++n;
            const double delta = v - mean;
            mean += delta / static_cast<double>(n);
            const double delta2 = v - mean;
            m2 += delta * delta2;
        }
    }

    if (n == 0) {
        return aether::core::Status::kOk;
    }

    *out_variance = m2 / static_cast<double>(n);
    if (!std::isfinite(*out_variance) || *out_variance < 0.0) {
        *out_variance = 0.0;
    }
    return aether::core::Status::kOk;
}

aether::core::Status tenengrad_metric_for_quality(
    int quality_level,
    double tenengrad_threshold,
    double* out_value,
    double* out_confidence,
    double* out_roi_coverage,
    bool* out_skipped) {
    return tenengrad_metric_from_image(
        nullptr,
        0,
        0,
        0,
        quality_level,
        tenengrad_threshold,
        out_value,
        out_confidence,
        out_roi_coverage,
        out_skipped);
}

aether::core::Status tenengrad_metric_from_image(
    const std::uint8_t* bytes,
    int width,
    int height,
    int row_bytes,
    int quality_level,
    double tenengrad_threshold,
    double* out_value,
    double* out_confidence,
    double* out_roi_coverage,
    bool* out_skipped) {
    if (out_value == nullptr || out_confidence == nullptr || out_roi_coverage == nullptr || out_skipped == nullptr) {
        return aether::core::Status::kInvalidArgument;
    }
    if (!std::isfinite(tenengrad_threshold) || tenengrad_threshold < 0.0) {
        return aether::core::Status::kInvalidArgument;
    }

    *out_value = 0.0;
    *out_confidence = 0.0;
    *out_roi_coverage = 0.0;
    *out_skipped = false;

    if (quality_level >= 2) {
        *out_skipped = true;
        return aether::core::Status::kOk;
    }

    // Legacy fallback path when no image is provided.
    if (bytes == nullptr || width < 3 || height < 3 || row_bytes < width) {
        if (quality_level == 1) {
            *out_value = tenengrad_threshold * 0.94;
            *out_confidence = 0.85;
            *out_roi_coverage = 0.5;
        } else {
            *out_value = tenengrad_threshold * 1.12;
            *out_confidence = 0.95;
            *out_roi_coverage = 1.0;
        }
        if (!std::isfinite(*out_value)) {
            *out_value = 0.0;
            *out_confidence = 0.0;
            *out_roi_coverage = 0.0;
        }
        return aether::core::Status::kOk;
    }

    const int stride = quality_level == 1 ? 2 : 1;
    double sum_energy = 0.0;
    std::size_t sample_count = 0u;
    for (int y = 1; y < height - 1; y += stride) {
        for (int x = 1; x < width - 1; x += stride) {
            const int idx00 = (y - 1) * row_bytes + (x - 1);
            const int idx01 = (y - 1) * row_bytes + x;
            const int idx02 = (y - 1) * row_bytes + (x + 1);
            const int idx10 = y * row_bytes + (x - 1);
            const int idx12 = y * row_bytes + (x + 1);
            const int idx20 = (y + 1) * row_bytes + (x - 1);
            const int idx21 = (y + 1) * row_bytes + x;
            const int idx22 = (y + 1) * row_bytes + (x + 1);

            const double gx =
                -static_cast<double>(bytes[idx00]) + static_cast<double>(bytes[idx02]) +
                -2.0 * static_cast<double>(bytes[idx10]) + 2.0 * static_cast<double>(bytes[idx12]) +
                -static_cast<double>(bytes[idx20]) + static_cast<double>(bytes[idx22]);
            const double gy =
                -static_cast<double>(bytes[idx00]) - 2.0 * static_cast<double>(bytes[idx01]) - static_cast<double>(bytes[idx02]) +
                static_cast<double>(bytes[idx20]) + 2.0 * static_cast<double>(bytes[idx21]) + static_cast<double>(bytes[idx22]);
            sum_energy += gx * gx + gy * gy;
            sample_count += 1u;
        }
    }

    if (sample_count == 0u) {
        *out_skipped = true;
        return aether::core::Status::kOk;
    }

    const double score = sum_energy / static_cast<double>(sample_count);
    *out_value = score;
    *out_roi_coverage = quality_level == 1
        ? 0.25
        : static_cast<double>(sample_count) /
            static_cast<double>((width - 2) * (height - 2));

    if (tenengrad_threshold <= 1e-9) {
        *out_confidence = 1.0;
    } else {
        const double ratio = score / tenengrad_threshold;
        *out_confidence = std::clamp(0.5 + 0.25 * ratio, 0.0, 1.0);
    }

    if (!std::isfinite(*out_value)) {
        *out_value = 0.0;
        *out_confidence = 0.0;
        *out_roi_coverage = 0.0;
    }
    return aether::core::Status::kOk;
}

}  // namespace quality
}  // namespace aether
