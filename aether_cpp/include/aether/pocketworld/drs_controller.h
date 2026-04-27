// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_CPP_POCKETWORLD_DRS_CONTROLLER_H
#define AETHER_CPP_POCKETWORLD_DRS_CONTROLLER_H

#include <algorithm>
#include <array>
#include <cstdint>

namespace aether::pocketworld {

class DrsController {
public:
    void on_frame_done(float frame_ms) {
        recent_[idx_] = frame_ms;
        idx_ = (idx_ + 1) % kRollingWindow;
        if (filled_ < kRollingWindow) ++filled_;
        if (filled_ < 5) return;

        float sum = 0.0f;
        for (int i = 0; i < filled_; ++i) sum += recent_[i];
        const float avg = sum / static_cast<float>(filled_);

        if (avg > kTargetMs * kHysteresisHigh) {
            current_scale_ = std::max(kMinScale, current_scale_ - kDecayRate);
        } else if (avg < kTargetMs * kHysteresisLow && current_scale_ < kMaxScale) {
            current_scale_ = std::min(kMaxScale, current_scale_ + kRecoveryRate);
        }
    }

    void render_size_for(std::uint32_t native_w,
                         std::uint32_t native_h,
                         std::uint32_t* out_w,
                         std::uint32_t* out_h) const {
        if (!out_w || !out_h) return;
        *out_w = static_cast<std::uint32_t>(static_cast<float>(native_w) * current_scale_);
        *out_h = static_cast<std::uint32_t>(static_cast<float>(native_h) * current_scale_);
        *out_w = std::max<std::uint32_t>(8u, (*out_w + 7u) & ~7u);
        *out_h = std::max<std::uint32_t>(8u, (*out_h + 7u) & ~7u);
    }

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

    std::array<float, kRollingWindow> recent_{};
    int idx_ = 0;
    int filled_ = 0;
    float current_scale_ = 1.0f;
};

}  // namespace aether::pocketworld

#endif  // AETHER_CPP_POCKETWORLD_DRS_CONTROLLER_H
