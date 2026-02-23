// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_CPP_RENDER_FRUSTUM_CULLER_H
#define AETHER_CPP_RENDER_FRUSTUM_CULLER_H

#ifdef __cplusplus

#include "aether/core/status.h"
#include "aether/tsdf/block_index.h"

#include <cstddef>
#include <cstdint>
#include <vector>

namespace aether {
namespace render {

struct FrustumPlane {
    float a{0.0f};
    float b{0.0f};
    float c{0.0f};
    float d{0.0f};
};

enum class FrustumCullClassification : std::uint8_t {
    kVisible = 0u,
    kOccluded = 1u,
    kOutside = 2u,
};

struct FrustumCullConfig {
    bool enable_occlusion_test{true};
    std::uint32_t hi_z_resolution{32u};
    float block_padding{0.0f};
};

struct FrustumCullResult {
    std::vector<tsdf::BlockIndex> visible_blocks{};
    std::size_t total_blocks{0u};
    std::size_t visible_count{0u};
    std::size_t occluded_count{0u};
    std::size_t outside_count{0u};
};

void extract_frustum_planes(const float* view_projection_matrix, FrustumPlane planes[6]);

bool aabb_outside_frustum(
    const FrustumPlane planes[6],
    float min_x,
    float min_y,
    float min_z,
    float max_x,
    float max_y,
    float max_z);

core::Status cull_blocks(
    const tsdf::BlockIndex* blocks,
    std::size_t block_count,
    const float* block_voxel_sizes,
    const float* view_matrix,
    const float* projection_matrix,
    const FrustumCullConfig& config,
    FrustumCullResult* out_result);

}  // namespace render
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_CPP_RENDER_FRUSTUM_CULLER_H
