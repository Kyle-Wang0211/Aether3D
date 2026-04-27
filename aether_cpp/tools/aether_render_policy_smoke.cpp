// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/pocketworld/render_policy.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>

namespace {

void require(bool condition, const char* message) {
    if (!condition) {
        std::fprintf(stderr, "FAIL: %s\n", message);
        std::exit(1);
    }
}

}  // namespace

int main() {
    AetherRenderPolicyDecisionC mac{};
    aether_render_policy_choose(
        1,
        "Mac15,12",
        14,
        4,
        3024,
        1964,
        1,
        1,
        &mac
    );
    require(mac.tier == 0, "Mac15 should be flagship");
    require(mac.preferred_surface == 1, "flagship should prefer RGBA16F render surface");
    require(mac.wcg_supported == 1, "flagship should enable WCG render path");
    require(mac.edr_supported == 1, "flagship with EDR headroom should enable EDR");
    require(mac.metalfx_supported == 1, "macOS 13+ flagship should enable MetalFX");
    require(mac.drs_enabled == 0, "Batch 2 production policy should keep DRS staged");
    require(mac.base_render_w == 256 && mac.base_render_h == 256, "base render size should remain 256");

    AetherRenderPolicyDecisionC old_mac{};
    aether_render_policy_choose(
        1,
        "MacBookPro15,1",
        12,
        7,
        256,
        256,
        0,
        0,
        &old_mac
    );
    require(old_mac.tier == 2, "older Mac should be mid tier");
    require(old_mac.preferred_surface == 0, "mid tier should prefer BGRA8");
    require(old_mac.metalfx_supported == 0, "MetalFX runtime unavailable should disable MetalFX");
    require(old_mac.drs_enabled == 0, "256x256 staged app target should keep DRS disabled");

    AetherRenderPolicyDecisionC iphone{};
    aether_render_policy_choose(
        2,
        "iPhone15,2",
        16,
        0,
        2556,
        1179,
        1,
        1,
        &iphone
    );
    require(iphone.tier == 0, "iPhone 14 Pro should be flagship");
    require(iphone.metalfx_supported == 1, "iPhone 14 Pro runtime facts should allow MetalFX");

    AetherDrsController* drs = aether_drs_create();
    require(drs != nullptr, "DRS create should succeed");
    uint32_t w = 0;
    uint32_t h = 0;
    aether_drs_render_size_for(drs, 255, 255, &w, &h);
    require(w == 255 && h == 255, "disabled DRS should preserve native size");
    require(std::fabs(aether_drs_current_scale(drs) - 1.0f) < 0.0001f,
            "initial DRS scale should be 1.0");

    aether_drs_set_enabled(drs, 1);
    for (int i = 0; i < 4; ++i) {
        aether_drs_on_frame_done(drs, 40.0f);
    }
    require(std::fabs(aether_drs_current_scale(drs) - 1.0f) < 0.0001f,
            "DRS should wait for 5 samples");
    aether_drs_on_frame_done(drs, 40.0f);
    require(aether_drs_current_scale(drs) < 1.0f, "DRS should decay after sustained slow frames");
    aether_drs_render_size_for(drs, 256, 256, &w, &h);
    require((w % 8u) == 0u && (h % 8u) == 0u, "DRS render size should align to 8");
    require(w < 256 && h < 256, "DRS slow frames should reduce render size");

    for (int i = 0; i < 60; ++i) {
        aether_drs_on_frame_done(drs, 8.0f);
    }
    require(aether_drs_current_scale(drs) > 0.95f, "DRS should recover under fast frames");
    aether_drs_destroy(drs);

    std::puts("PASS aether_render_policy_smoke");
    return 0;
}
