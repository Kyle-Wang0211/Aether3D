// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_QUALITY_IMAGE_METRICS_H
#define AETHER_QUALITY_IMAGE_METRICS_H

#ifdef __cplusplus

#include "aether/core/status.h"

#include <cstdint>

namespace aether {
namespace quality {

aether::core::Status laplacian_variance(
    const std::uint8_t* bytes,
    int width,
    int height,
    int row_bytes,
    double* out_variance);

aether::core::Status tenengrad_metric_for_quality(
    int quality_level,
    double tenengrad_threshold,
    double* out_value,
    double* out_confidence,
    double* out_roi_coverage,
    bool* out_skipped);

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
    bool* out_skipped);

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
    bool* out_skipped);

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
    bool* out_skipped);

}  // namespace quality
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_QUALITY_IMAGE_METRICS_H
