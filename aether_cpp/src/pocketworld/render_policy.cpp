// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/pocketworld/render_policy.h"

#include <algorithm>
#include <cstring>
#include <new>

namespace aether::pocketworld {

constexpr float DrsController::kTargetMs;
constexpr float DrsController::kMinScale;
constexpr float DrsController::kMaxScale;
constexpr float DrsController::kDecayRate;
constexpr float DrsController::kRecoveryRate;
constexpr float DrsController::kHysteresisHigh;
constexpr float DrsController::kHysteresisLow;

namespace {

bool contains(const char* haystack, const char* needle) {
    if (haystack == nullptr || needle == nullptr) {
        return false;
    }
    return std::strstr(haystack, needle) != nullptr;
}

DeviceTier tier_for_macos_model(const char* model) {
    if (contains(model, "Mac15") || contains(model, "Mac16")) {
        return DeviceTier::kFlagship;
    }
    if (contains(model, "Mac14") || contains(model, "MacBookPro18")) {
        return DeviceTier::kHigh;
    }
    return DeviceTier::kMid;
}

DeviceTier tier_for_ios_model(const char* model) {
    // iPhone15,2 / iPhone15,3 = iPhone 14 Pro / Pro Max. Newer Pro devices
    // stay flagship until a more granular Phase 7 performance table lands.
    if (contains(model, "iPhone15,") ||
        contains(model, "iPhone16,") ||
        contains(model, "iPhone17,") ||
        contains(model, "iPad14,") ||
        contains(model, "iPad15,")) {
        return DeviceTier::kFlagship;
    }
    if (contains(model, "iPhone14,") ||
        contains(model, "iPad13,")) {
        return DeviceTier::kHigh;
    }
    return DeviceTier::kMid;
}

bool is_high_or_flagship(DeviceTier tier) {
    return tier == DeviceTier::kFlagship || tier == DeviceTier::kHigh;
}

}  // namespace

RenderPolicyDecision choose_render_policy(const PlatformCapabilities& caps) {
    RenderPolicyDecision decision;
    decision.target_fps = 60;
    decision.base_render_w = 256;
    decision.base_render_h = 256;

    switch (caps.platform) {
    case PolicyPlatform::kMacOS:
        decision.tier = tier_for_macos_model(caps.hardware_model);
        break;
    case PolicyPlatform::kIOS:
        decision.tier = tier_for_ios_model(caps.hardware_model);
        break;
    case PolicyPlatform::kAndroid:
        decision.tier = DeviceTier::kAndroidHigh;
        break;
    case PolicyPlatform::kHarmonyOS:
        decision.tier = DeviceTier::kAndroidHigh;
        break;
    case PolicyPlatform::kWeb:
        decision.tier = DeviceTier::kWeb;
        break;
    case PolicyPlatform::kUnknown:
    default:
        decision.tier = DeviceTier::kUnknown;
        break;
    }

    decision.preferred_surface = is_high_or_flagship(decision.tier)
        ? SurfacePreference::kRGBA16Float
        : SurfacePreference::kBGRA8;
    decision.wcg_supported = decision.preferred_surface == SurfacePreference::kRGBA16Float;
    decision.edr_supported = caps.supports_edr && is_high_or_flagship(decision.tier);
    decision.metalfx_supported = caps.metalfx_runtime_available &&
        is_high_or_flagship(decision.tier) &&
        (caps.platform == PolicyPlatform::kMacOS || caps.platform == PolicyPlatform::kIOS);

    // Batch 2 keeps the production Flutter texture at 256x256 for smoothness.
    // The DRS algorithm is shared and wired, but the policy leaves it staged
    // until Phase 6.4d.3 opens a larger render/display split.
    (void)caps.native_display_w;
    (void)caps.native_display_h;
    decision.drs_enabled = false;

    return decision;
}

void DrsController::set_enabled(bool enabled) {
    if (enabled_ == enabled) {
        return;
    }
    enabled_ = enabled;
    reset();
}

void DrsController::reset() {
    std::fill(std::begin(recent_), std::end(recent_), 0.0f);
    idx_ = 0;
    filled_ = 0;
    current_scale_ = 1.0f;
}

void DrsController::on_frame_done(float frame_ms) {
    if (!enabled_) {
        return;
    }
    recent_[idx_] = frame_ms;
    idx_ = (idx_ + 1) % kRollingWindow;
    if (filled_ < kRollingWindow) {
        ++filled_;
    }
    if (filled_ < 5) {
        return;
    }

    float sum = 0.0f;
    for (int i = 0; i < filled_; ++i) {
        sum += recent_[i];
    }
    const float avg = sum / static_cast<float>(filled_);
    if (avg > kTargetMs * kHysteresisHigh) {
        current_scale_ = std::max(kMinScale, current_scale_ - kDecayRate);
    } else if (avg < kTargetMs * kHysteresisLow && current_scale_ < kMaxScale) {
        current_scale_ = std::min(kMaxScale, current_scale_ + kRecoveryRate);
    }
}

void DrsController::render_size_for(uint32_t native_w,
                                    uint32_t native_h,
                                    uint32_t* out_w,
                                    uint32_t* out_h) const {
    if (out_w == nullptr || out_h == nullptr) {
        return;
    }
    if (!enabled_) {
        *out_w = native_w;
        *out_h = native_h;
        return;
    }
    uint32_t w = static_cast<uint32_t>(static_cast<float>(native_w) * current_scale_);
    uint32_t h = static_cast<uint32_t>(static_cast<float>(native_h) * current_scale_);
    w = std::max(8u, (w + 7u) & ~7u);
    h = std::max(8u, (h + 7u) & ~7u);
    *out_w = w;
    *out_h = h;
}

}  // namespace aether::pocketworld

struct AetherDrsController {
    aether::pocketworld::DrsController impl;
};

extern "C" {

void aether_render_policy_choose(uint8_t platform,
                                 const char* hardware_model,
                                 uint32_t os_major,
                                 uint32_t os_minor,
                                 uint32_t native_display_w,
                                 uint32_t native_display_h,
                                 uint8_t supports_edr,
                                 uint8_t metalfx_runtime_available,
                                 AetherRenderPolicyDecisionC* out_decision) {
    (void)os_major;
    (void)os_minor;
    if (out_decision == nullptr) {
        return;
    }

    const aether::pocketworld::PlatformCapabilities caps{
        static_cast<aether::pocketworld::PolicyPlatform>(platform),
        hardware_model,
        os_major,
        os_minor,
        native_display_w,
        native_display_h,
        supports_edr != 0,
        metalfx_runtime_available != 0,
    };
    const auto decision = aether::pocketworld::choose_render_policy(caps);
    out_decision->tier = static_cast<uint8_t>(decision.tier);
    out_decision->preferred_surface = static_cast<uint8_t>(decision.preferred_surface);
    out_decision->wcg_supported = decision.wcg_supported ? 1u : 0u;
    out_decision->edr_supported = decision.edr_supported ? 1u : 0u;
    out_decision->metalfx_supported = decision.metalfx_supported ? 1u : 0u;
    out_decision->drs_enabled = decision.drs_enabled ? 1u : 0u;
    out_decision->target_fps = decision.target_fps;
    out_decision->reserved = 0;
    out_decision->base_render_w = decision.base_render_w;
    out_decision->base_render_h = decision.base_render_h;
}

AetherDrsController* aether_drs_create(void) {
    return new (std::nothrow) AetherDrsController();
}

void aether_drs_destroy(AetherDrsController* controller) {
    delete controller;
}

void aether_drs_reset(AetherDrsController* controller) {
    if (controller == nullptr) {
        return;
    }
    controller->impl.reset();
}

void aether_drs_set_enabled(AetherDrsController* controller, uint8_t enabled) {
    if (controller == nullptr) {
        return;
    }
    controller->impl.set_enabled(enabled != 0);
}

uint8_t aether_drs_enabled(AetherDrsController* controller) {
    if (controller == nullptr) {
        return 0;
    }
    return controller->impl.enabled() ? 1u : 0u;
}

void aether_drs_on_frame_done(AetherDrsController* controller, float frame_ms) {
    if (controller == nullptr) {
        return;
    }
    controller->impl.on_frame_done(frame_ms);
}

void aether_drs_render_size_for(AetherDrsController* controller,
                                uint32_t native_w,
                                uint32_t native_h,
                                uint32_t* out_w,
                                uint32_t* out_h) {
    if (controller == nullptr) {
        if (out_w != nullptr) {
            *out_w = native_w;
        }
        if (out_h != nullptr) {
            *out_h = native_h;
        }
        return;
    }
    controller->impl.render_size_for(native_w, native_h, out_w, out_h);
}

float aether_drs_current_scale(AetherDrsController* controller) {
    if (controller == nullptr) {
        return 1.0f;
    }
    return controller->impl.current_scale();
}

}  // extern "C"
