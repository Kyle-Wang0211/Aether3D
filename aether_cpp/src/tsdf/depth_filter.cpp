// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/tsdf/depth_filter.h"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>

namespace aether {
namespace tsdf {
namespace {

inline float clamp_float(float value, float low, float high) {
    return std::max(low, std::min(high, value));
}

[[maybe_unused]] inline float sqr(float x) {
    return x * x;
}

}  // namespace

DepthFilter::DepthFilter(int width, int height, const DepthFilterConfig& config)
    : width_(width), height_(height), config_(config) {
    const std::size_t count = (width_ > 0 && height_ > 0)
        ? static_cast<std::size_t>(width_) * static_cast<std::size_t>(height_)
        : 0u;
    bilateral_buffer_.assign(count, 0.0f);
    for (auto& buf : history_) {
        buf.assign(count, std::numeric_limits<float>::quiet_NaN());
    }
}

bool DepthFilter::is_valid(float d) const {
    return std::isfinite(d) &&
        d >= config_.min_valid_depth &&
        d <= config_.max_valid_depth;
}

void DepthFilter::reset() {
    history_count_ = 0u;
    history_head_ = 0u;
    for (auto& buf : history_) {
        std::fill(buf.begin(), buf.end(), std::numeric_limits<float>::quiet_NaN());
    }
    feedback_ = FusionFeedback{};
}

core::Status DepthFilter::apply_fusion_feedback(const FusionFeedback& feedback) {
    if (!std::isfinite(feedback.voxel_weight_median) ||
        !std::isfinite(feedback.sdf_variance_p95) ||
        !std::isfinite(feedback.ghosting_score)) {
        return core::Status::kInvalidArgument;
    }
    feedback_ = feedback;
    return core::Status::kOk;
}

core::Status DepthFilter::run(
    const float* depth_in,
    const std::uint8_t* confidence_in,
    float angular_velocity,
    float* depth_out,
    DepthFilterQuality* out_quality) {
    if (depth_in == nullptr || depth_out == nullptr || out_quality == nullptr ||
        width_ <= 0 || height_ <= 0) {
        return core::Status::kInvalidArgument;
    }

    const int radius = std::max(0, config_.kernel_radius);
    const float sigma_spatial = std::max(1e-4f, config_.sigma_spatial);
    const float sigma_range = std::max(1e-5f, config_.sigma_range);
    const float inv_two_sigma_spatial2 = 0.5f / (sigma_spatial * sigma_spatial);
    const float inv_two_sigma_range2 = 0.5f / (sigma_range * sigma_range);
    const std::size_t count =
        static_cast<std::size_t>(width_) * static_cast<std::size_t>(height_);

    // 1) Edge-aware bilateral denoise.
    for (int y = 0; y < height_; ++y) {
        for (int x = 0; x < width_; ++x) {
            const std::size_t idx =
                static_cast<std::size_t>(y) * static_cast<std::size_t>(width_) +
                static_cast<std::size_t>(x);
            const float center = depth_in[idx];
            if (!is_valid(center)) {
                bilateral_buffer_[idx] = std::numeric_limits<float>::quiet_NaN();
                continue;
            }

            float weight_sum = 0.0f;
            float weighted_depth = 0.0f;
            for (int oy = -radius; oy <= radius; ++oy) {
                const int sy = y + oy;
                if (sy < 0 || sy >= height_) {
                    continue;
                }
                for (int ox = -radius; ox <= radius; ++ox) {
                    const int sx = x + ox;
                    if (sx < 0 || sx >= width_) {
                        continue;
                    }
                    const std::size_t sidx =
                        static_cast<std::size_t>(sy) * static_cast<std::size_t>(width_) +
                        static_cast<std::size_t>(sx);
                    const float sample = depth_in[sidx];
                    if (!is_valid(sample)) {
                        continue;
                    }
                    const float ds2 = static_cast<float>(ox * ox + oy * oy);
                    const float dd = sample - center;
                    float w = std::exp(-ds2 * inv_two_sigma_spatial2) *
                        std::exp(-(dd * dd) * inv_two_sigma_range2);
                    if (confidence_in != nullptr) {
                        const float c = clamp_float(
                            static_cast<float>(confidence_in[sidx]) / 2.0f,
                            0.0f,
                            1.0f);
                        w *= (0.3f + 0.7f * c);
                    }
                    weighted_depth += sample * w;
                    weight_sum += w;
                }
            }
            bilateral_buffer_[idx] = (weight_sum > 1e-6f)
                ? (weighted_depth / weight_sum)
                : center;
        }
    }

    // 2) Small-radius hole fill to reduce sparse invalid islands.
    const int fill_radius = std::max(0, config_.max_fill_radius);
    for (int y = 0; y < height_; ++y) {
        for (int x = 0; x < width_; ++x) {
            const std::size_t idx =
                static_cast<std::size_t>(y) * static_cast<std::size_t>(width_) +
                static_cast<std::size_t>(x);
            if (std::isfinite(bilateral_buffer_[idx])) {
                continue;
            }
            float acc = 0.0f;
            int n = 0;
            for (int oy = -fill_radius; oy <= fill_radius; ++oy) {
                const int sy = y + oy;
                if (sy < 0 || sy >= height_) {
                    continue;
                }
                for (int ox = -fill_radius; ox <= fill_radius; ++ox) {
                    const int sx = x + ox;
                    if (sx < 0 || sx >= width_) {
                        continue;
                    }
                    const std::size_t sidx =
                        static_cast<std::size_t>(sy) * static_cast<std::size_t>(width_) +
                        static_cast<std::size_t>(sx);
                    const float v = bilateral_buffer_[sidx];
                    if (std::isfinite(v)) {
                        acc += v;
                        ++n;
                    }
                }
            }
            if (n > 0) {
                bilateral_buffer_[idx] = acc / static_cast<float>(n);
            }
        }
    }

    // 3) Temporal stabilize with motion-aware blending.
    const float motion = clamp_float(std::fabs(angular_velocity), 0.0f, 10.0f);
    const float motion_factor = clamp_float(1.0f - motion / 10.0f, 0.1f, 1.0f);
    const float ghost_penalty = clamp_float(feedback_.ghosting_score, 0.0f, 1.0f);
    const float temporal_alpha = clamp_float(0.25f + 0.45f * motion_factor - 0.20f * ghost_penalty, 0.05f, 0.85f);

    std::size_t valid_count = 0u;
    double residual_sum = 0.0;
    for (std::size_t i = 0u; i < count; ++i) {
        const float curr = bilateral_buffer_[i];
        if (!std::isfinite(curr)) {
            depth_out[i] = std::numeric_limits<float>::quiet_NaN();
            continue;
        }

        float hist_sum = 0.0f;
        int hist_n = 0;
        for (std::size_t h = 0u; h < history_count_; ++h) {
            const float hv = history_[h][i];
            if (std::isfinite(hv)) {
                hist_sum += hv;
                ++hist_n;
            }
        }
        const float hist_mean = (hist_n > 0) ? (hist_sum / static_cast<float>(hist_n)) : curr;
        const float fused = curr * (1.0f - temporal_alpha) + hist_mean * temporal_alpha;
        depth_out[i] = fused;

        if (is_valid(depth_in[i])) {
            residual_sum += std::fabs(static_cast<double>(fused - depth_in[i]));
        }
        ++valid_count;
    }

    // 4) Update temporal ring-buffer.
    history_[history_head_] = bilateral_buffer_;
    history_head_ = (history_head_ + 1u) % 3u;
    history_count_ = std::min<std::size_t>(3u, history_count_ + 1u);

    out_quality->valid_ratio = (count > 0u)
        ? static_cast<float>(valid_count) / static_cast<float>(count)
        : 0.0f;
    out_quality->noise_residual = (valid_count > 0u)
        ? static_cast<float>(residual_sum / static_cast<double>(valid_count))
        : 0.0f;
    out_quality->edge_risk_score = clamp_float(
        0.5f * (1.0f - out_quality->valid_ratio) +
        0.3f * clamp_float(std::fabs(angular_velocity) / 8.0f, 0.0f, 1.0f) +
        0.2f * clamp_float(feedback_.sdf_variance_p95, 0.0f, 1.0f),
        0.0f,
        1.0f);

    return core::Status::kOk;
}

}  // namespace tsdf
}  // namespace aether
