// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_POCKETWORLD_RENDER_POLICY_H
#define AETHER_POCKETWORLD_RENDER_POLICY_H

#include <stdint.h>

// Phase 6.4x portability boundary:
// Platform code (Swift/Kotlin/Web) may probe platform facts such as model
// identifier, OS version, and EDR availability. Policy decisions derived from
// those facts live here so DRS/tier behavior remains reusable across ports.

#ifdef __cplusplus
namespace aether::pocketworld {

enum class PolicyPlatform : uint8_t {
    kUnknown = 0,
    kMacOS = 1,
    kIOS = 2,
    kAndroid = 3,
    kHarmonyOS = 4,
    kWeb = 5,
};

enum class DeviceTier : uint8_t {
    kFlagship = 0,
    kHigh = 1,
    kMid = 2,
    kAndroidHigh = 3,
    kAndroidLow = 4,
    kWeb = 5,
    kUnknown = 6,
};

enum class SurfacePreference : uint8_t {
    kBGRA8 = 0,
    kRGBA16Float = 1,
};

struct PlatformCapabilities {
    PolicyPlatform platform = PolicyPlatform::kUnknown;
    const char* hardware_model = nullptr;
    uint32_t os_major = 0;
    uint32_t os_minor = 0;
    uint32_t native_display_w = 0;
    uint32_t native_display_h = 0;
    bool supports_edr = false;
    bool metalfx_runtime_available = false;
};

struct RenderPolicyDecision {
    DeviceTier tier = DeviceTier::kUnknown;
    SurfacePreference preferred_surface = SurfacePreference::kBGRA8;
    bool wcg_supported = false;
    bool edr_supported = false;
    bool metalfx_supported = false;
    bool drs_enabled = false;
    uint8_t target_fps = 60;
    uint32_t base_render_w = 256;
    uint32_t base_render_h = 256;
};

RenderPolicyDecision choose_render_policy(const PlatformCapabilities& caps);

class DrsController {
public:
    void set_enabled(bool enabled);
    bool enabled() const { return enabled_; }

    void reset();
    void on_frame_done(float frame_ms);
    void render_size_for(uint32_t native_w,
                         uint32_t native_h,
                         uint32_t* out_w,
                         uint32_t* out_h) const;
    float current_scale() const { return current_scale_; }

private:
    static constexpr int kRollingWindow = 30;
    static constexpr float kTargetMs = 16.6f;
    static constexpr float kMinScale = 0.5f;
    static constexpr float kMaxScale = 1.0f;
    static constexpr float kDecayRate = 0.05f;
    static constexpr float kRecoveryRate = 0.02f;
    static constexpr float kHysteresisHigh = 1.1f;
    static constexpr float kHysteresisLow = 0.9f;

    float recent_[kRollingWindow] = {};
    int idx_ = 0;
    int filled_ = 0;
    float current_scale_ = 1.0f;
    bool enabled_ = false;
};

}  // namespace aether::pocketworld
#endif  // __cplusplus

#ifdef __cplusplus
extern "C" {
#endif

typedef struct AetherDrsController AetherDrsController;

typedef struct AetherRenderPolicyDecisionC {
    uint8_t tier;
    uint8_t preferred_surface;
    uint8_t wcg_supported;
    uint8_t edr_supported;
    uint8_t metalfx_supported;
    uint8_t drs_enabled;
    uint8_t target_fps;
    uint8_t reserved;
    uint32_t base_render_w;
    uint32_t base_render_h;
} AetherRenderPolicyDecisionC;

void aether_render_policy_choose(
    uint8_t platform,
    const char* hardware_model,
    uint32_t os_major,
    uint32_t os_minor,
    uint32_t native_display_w,
    uint32_t native_display_h,
    uint8_t supports_edr,
    uint8_t metalfx_runtime_available,
    AetherRenderPolicyDecisionC* out_decision
);

AetherDrsController* aether_drs_create(void);
void aether_drs_destroy(AetherDrsController* controller);
void aether_drs_reset(AetherDrsController* controller);
void aether_drs_set_enabled(AetherDrsController* controller, uint8_t enabled);
uint8_t aether_drs_enabled(AetherDrsController* controller);
void aether_drs_on_frame_done(AetherDrsController* controller, float frame_ms);
void aether_drs_render_size_for(
    AetherDrsController* controller,
    uint32_t native_w,
    uint32_t native_h,
    uint32_t* out_w,
    uint32_t* out_h
);
float aether_drs_current_scale(AetherDrsController* controller);

#ifdef __cplusplus
}
#endif

#endif  // AETHER_POCKETWORLD_RENDER_POLICY_H
