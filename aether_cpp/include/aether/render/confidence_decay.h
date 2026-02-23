// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_CPP_RENDER_CONFIDENCE_DECAY_H
#define AETHER_CPP_RENDER_CONFIDENCE_DECAY_H

#ifdef __cplusplus

#include "aether/core/status.h"
#include "aether/innovation/core_types.h"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>

namespace aether {
namespace render {

struct ConfidenceDecayConfig {
    float decay_per_frame{0.005f};
    float min_confidence{0.05f};
    float observation_boost{0.15f};
    float max_confidence{1.0f};
    std::uint32_t grace_frames{30u};

    // Peak retention floor: confidence never decays below this fraction of
    // its all-time peak.  Prevents previously well-observed Gaussians from
    // fading to near-invisible.  Default 0.6 means a Gaussian that reached
    // confidence=1.0 will never decay below 0.6.
    float peak_retention_floor{0.6f};

    // Weber-Fechner perceptual exponent for confidence → opacity mapping.
    // Stevens' power law: perceived brightness ~ luminance^0.43.
    // Using pow(confidence, exponent) instead of linear mapping ensures
    // perceptually uniform transitions — low-confidence Gaussians don't
    // appear to "suddenly vanish" as they would under linear mapping.
    float perceptual_exponent{0.43f};
};

// Map raw confidence to perceptually uniform opacity using Stevens' power law.
// Returns pow(clamp(confidence, 0, 1), config.perceptual_exponent).
inline float perceptual_opacity(float confidence, const ConfidenceDecayConfig& config) {
    const float c = std::max(0.0f, std::min(1.0f, confidence));
    if (c <= 0.0f) return 0.0f;
    return std::pow(c, config.perceptual_exponent);
}

core::Status decay_confidence(
    innovation::GaussianPrimitive* gaussians,
    std::size_t count,
    const bool* in_current_frustum,
    std::uint64_t current_frame,
    const ConfidenceDecayConfig& config = ConfidenceDecayConfig{});

}  // namespace render
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_CPP_RENDER_CONFIDENCE_DECAY_H
