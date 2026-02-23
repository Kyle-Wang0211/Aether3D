// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_TSDF_DEPTH_FILTER_H
#define AETHER_TSDF_DEPTH_FILTER_H

#ifdef __cplusplus

#include "aether/core/status.h"

#include <cstddef>
#include <cstdint>
#include <vector>

namespace aether {
namespace tsdf {

struct DepthFilterConfig {
    float sigma_spatial{1.6f};
    float sigma_range{0.025f};
    int kernel_radius{2};
    int max_fill_radius{3};
    float min_valid_depth{0.05f};
    float max_valid_depth{10.0f};
};

struct DepthFilterQuality {
    float noise_residual{0.0f};
    float valid_ratio{0.0f};
    float edge_risk_score{0.0f};
};

struct FusionFeedback {
    float voxel_weight_median{0.0f};
    float sdf_variance_p95{0.0f};
    float ghosting_score{0.0f};
};

class DepthFilter {
public:
    DepthFilter(int width, int height, const DepthFilterConfig& config = DepthFilterConfig{});

    core::Status run(
        const float* depth_in,
        const std::uint8_t* confidence_in,
        float angular_velocity,
        float* depth_out,
        DepthFilterQuality* out_quality);

    core::Status apply_fusion_feedback(const FusionFeedback& feedback);

    void reset();

private:
    int width_{0};
    int height_{0};
    DepthFilterConfig config_{};
    std::vector<float> bilateral_buffer_;
    std::vector<float> history_[3];
    std::size_t history_count_{0u};
    std::size_t history_head_{0u};
    FusionFeedback feedback_{};

    bool is_valid(float d) const;
};

}  // namespace tsdf
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_TSDF_DEPTH_FILTER_H
