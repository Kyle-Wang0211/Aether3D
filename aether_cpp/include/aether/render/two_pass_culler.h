// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_CPP_RENDER_TWO_PASS_CULLER_H
#define AETHER_CPP_RENDER_TWO_PASS_CULLER_H

#ifdef __cplusplus

#include "aether/core/status.h"
#include "aether/render/meshlet_builder.h"
#include "aether/render/runtime_backend.h"

#include <cstddef>
#include <cstdint>
#include <vector>

namespace aether {
namespace render {

enum class TwoPassTier : std::uint8_t {
    kTierA = 0u,  // Mesh-shader + GPU HZB path available.
    kTierB = 1u,  // Non-mesh-shader but GPU HZB path available.
    kTierC = 2u,  // CPU HZB fallback only.
};

struct TwoPassFeatureCaps {
    bool mesh_shader_supported{false};
    bool gpu_hzb_supported{false};
    bool compute_supported{false};
};

struct TwoPassRuntime {
    RuntimePlatform platform{RuntimePlatform::kUnknown};
    GraphicsBackend backend{GraphicsBackend::kUnknown};
    TwoPassFeatureCaps caps{};
};

struct HiZFrameInput {
    const float* depth{nullptr};
    std::uint32_t resolution{0u};
};

struct TwoPassCullerConfig {
    bool enable_two_pass{true};
    std::uint32_t hi_z_resolution{32u};
    float pass2_retry_threshold{0.005f};
};

struct TwoPassCullerStats {
    TwoPassTier tier{TwoPassTier::kTierC};
    std::size_t total_meshlets{0u};
    std::size_t frustum_rejected{0u};
    std::size_t pass1_visible{0u};
    std::size_t pass1_rejected{0u};
    std::size_t pass2_recovered{0u};
    bool pass2_executed{false};
    float conservative_reject_ratio{0.0f};
};

struct TwoPassCullerResult {
    std::vector<std::uint32_t> visible_meshlets{};
    std::vector<std::uint32_t> pass1_rejected_meshlets{};
    TwoPassCullerStats stats{};
};

TwoPassTier select_two_pass_tier(const TwoPassRuntime& runtime);

bool has_three_end_fallback(const TwoPassRuntime& runtime);

core::Status cull_meshlets_two_pass(
    const Meshlet* meshlets,
    std::size_t meshlet_count,
    const float* view_matrix,
    const float* projection_matrix,
    const HiZFrameInput& previous_frame_hiz,
    const TwoPassRuntime& runtime,
    const TwoPassCullerConfig& config,
    TwoPassCullerResult* out_result);

}  // namespace render
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_CPP_RENDER_TWO_PASS_CULLER_H
