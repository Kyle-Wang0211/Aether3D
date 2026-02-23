// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/render/two_pass_culler.h"

#include <cstdio>
#include <vector>

int main() {
    int failed = 0;
    using namespace aether::render;

    TwoPassRuntime tier_a_runtime{};
    tier_a_runtime.platform = RuntimePlatform::kAndroid;
    tier_a_runtime.backend = GraphicsBackend::kVulkan;
    tier_a_runtime.caps.mesh_shader_supported = true;
    tier_a_runtime.caps.gpu_hzb_supported = true;
    if (select_two_pass_tier(tier_a_runtime) != TwoPassTier::kTierA) {
        std::fprintf(stderr, "tier selection should pick Tier-A\n");
        failed++;
    }
    if (!has_three_end_fallback(tier_a_runtime)) {
        std::fprintf(stderr, "android vulkan should provide fallback path\n");
        failed++;
    }

    TwoPassRuntime invalid_ios_runtime{};
    invalid_ios_runtime.platform = RuntimePlatform::kIOS;
    invalid_ios_runtime.backend = GraphicsBackend::kVulkan;
    if (has_three_end_fallback(invalid_ios_runtime)) {
        std::fprintf(stderr, "iOS Vulkan should be rejected as unsupported backend pair\n");
        failed++;
    }
    if (select_two_pass_tier(invalid_ios_runtime) != TwoPassTier::kTierC) {
        std::fprintf(stderr, "unsupported platform/backend pair should degrade to Tier-C\n");
        failed++;
    }

    TwoPassRuntime tier_c_runtime{};
    tier_c_runtime.platform = RuntimePlatform::kIOS;
    tier_c_runtime.backend = GraphicsBackend::kMetal;
    tier_c_runtime.caps.mesh_shader_supported = false;
    tier_c_runtime.caps.gpu_hzb_supported = false;
    if (select_two_pass_tier(tier_c_runtime) != TwoPassTier::kTierC) {
        std::fprintf(stderr, "tier selection should pick Tier-C without GPU HZB\n");
        failed++;
    }

    std::vector<Meshlet> meshlets(2u);
    meshlets[0].bounds.min_x = -0.2f;
    meshlets[0].bounds.min_y = -0.2f;
    meshlets[0].bounds.min_z = 0.2f;
    meshlets[0].bounds.max_x = 0.2f;
    meshlets[0].bounds.max_y = 0.2f;
    meshlets[0].bounds.max_z = 0.9f;

    meshlets[1].bounds.min_x = -0.2f;
    meshlets[1].bounds.min_y = -0.2f;
    meshlets[1].bounds.min_z = 0.5f;
    meshlets[1].bounds.max_x = 0.2f;
    meshlets[1].bounds.max_y = 0.2f;
    meshlets[1].bounds.max_z = 0.6f;

    const float view[16] = {
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    };
    const float proj[16] = {
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    };

    std::vector<float> previous_hiz(8u * 8u, 0.4f);
    HiZFrameInput frame_hiz{};
    frame_hiz.depth = previous_hiz.data();
    frame_hiz.resolution = 8u;

    TwoPassCullerConfig cfg{};
    cfg.enable_two_pass = true;
    cfg.hi_z_resolution = 8u;
    cfg.pass2_retry_threshold = 0.05f;

    TwoPassCullerResult result{};
    const aether::core::Status status = cull_meshlets_two_pass(
        meshlets.data(),
        meshlets.size(),
        view,
        proj,
        frame_hiz,
        tier_a_runtime,
        cfg,
        &result);
    if (status != aether::core::Status::kOk) {
        std::fprintf(stderr, "two-pass culling failed on valid input\n");
        return 1;
    }
    if (!result.stats.pass2_executed) {
        std::fprintf(stderr, "pass2 should execute when reject ratio exceeds threshold\n");
        failed++;
    }
    if (result.stats.pass1_rejected == 0u) {
        std::fprintf(stderr, "pass1 should reject at least one meshlet with stale depth\n");
        failed++;
    }
    if (result.stats.pass2_recovered == 0u) {
        std::fprintf(stderr, "pass2 should recover at least one conservatively rejected meshlet\n");
        failed++;
    }
    if (result.visible_meshlets.size() != 2u) {
        std::fprintf(stderr, "both meshlets should be visible after pass2 recovery\n");
        failed++;
    }

    TwoPassCullerResult invalid_runtime_result{};
    const aether::core::Status invalid_runtime_status = cull_meshlets_two_pass(
        meshlets.data(),
        meshlets.size(),
        view,
        proj,
        frame_hiz,
        invalid_ios_runtime,
        cfg,
        &invalid_runtime_result);
    if (invalid_runtime_status != aether::core::Status::kInvalidArgument) {
        std::fprintf(stderr, "invalid platform/backend pair must fail fast\n");
        failed++;
    }

    TwoPassCullerResult tier_c_result{};
    const aether::core::Status tier_c_status = cull_meshlets_two_pass(
        meshlets.data(),
        meshlets.size(),
        view,
        proj,
        frame_hiz,
        tier_c_runtime,
        cfg,
        &tier_c_result);
    if (tier_c_status != aether::core::Status::kOk) {
        std::fprintf(stderr, "tier-c culling should still succeed via CPU fallback\n");
        failed++;
    }
    if (tier_c_result.stats.pass2_executed) {
        std::fprintf(stderr, "tier-c fallback should not run pass2 GPU path\n");
        failed++;
    }

    return failed;
}
