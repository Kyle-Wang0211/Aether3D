// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_PIPELINE_RUNTIME_TSDF_GAUSSIAN_AUGMENTATION_H
#define AETHER_PIPELINE_RUNTIME_TSDF_GAUSSIAN_AUGMENTATION_H

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <unordered_set>
#include <vector>

#include "aether/splat/packed_splats.h"
#include "aether/tsdf/tsdf_volume.h"

namespace aether {
namespace pipeline {
namespace runtime_tsdf_gaussian_augmentation {

inline constexpr std::size_t kGaussianBucketCapacity = 2000000u;
inline constexpr std::size_t kGaussianRefillRate = 500000u;

struct ColorFrameView {
    const std::uint8_t* rgba{nullptr};
    std::uint32_t width{0};
    std::uint32_t height{0};
    float transform[16]{};
    float intrinsics[9]{};
};

struct State {
    std::unordered_set<std::int64_t> assigned_blocks;
    std::size_t gaussian_bucket_tokens{0};
    std::chrono::steady_clock::time_point gaussian_bucket_last_refill{};
    bool gaussian_bucket_initialized{false};
    std::size_t total_created_gaussians{0};
};

struct Result {
    std::vector<splat::GaussianParams> gaussians;
    std::size_t seeded_blocks{0};
    std::size_t blocks_checked{0};
    std::size_t blocks_rejected_surface{0};
    std::size_t blocks_rejected_weight{0};
    std::size_t sampled_colors{0};
    std::size_t fallback_colors{0};
};

bool should_run_runtime_tsdf_gaussian_augmentation(
    bool capture_sparse_dense_map,
    bool imported_video_runtime_tsdf_augmentation) noexcept;

std::size_t assigned_block_count(
    const State& state) noexcept;

Result build_runtime_tsdf_gaussian_seeds(
    State& state,
    const std::vector<tsdf::BlockQualitySample>& samples,
    const ColorFrameView& current_color_frame,
    const std::vector<ColorFrameView>& keyframes,
    float cam_x,
    float cam_y,
    float cam_z,
    bool strict_preview_color,
    std::chrono::steady_clock::time_point now) noexcept;

}  // namespace runtime_tsdf_gaussian_augmentation
}  // namespace pipeline
}  // namespace aether

#endif  // AETHER_PIPELINE_RUNTIME_TSDF_GAUSSIAN_AUGMENTATION_H
