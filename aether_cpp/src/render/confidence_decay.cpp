// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/render/confidence_decay.h"

#include "aether/core/numeric_guard.h"

#include <algorithm>

namespace aether {
namespace render {

core::Status decay_confidence(
    innovation::GaussianPrimitive* gaussians,
    std::size_t count,
    const bool* in_current_frustum,
    std::uint64_t current_frame,
    const ConfidenceDecayConfig& config) {
    if (gaussians == nullptr && count > 0u) {
        return core::Status::kInvalidArgument;
    }
    if (config.decay_per_frame < 0.0f || config.observation_boost < 0.0f ||
        config.min_confidence < 0.0f || config.max_confidence < config.min_confidence) {
        return core::Status::kInvalidArgument;
    }

    const float retention = std::max(0.0f, std::min(1.0f, config.peak_retention_floor));

    for (std::size_t i = 0u; i < count; ++i) {
        innovation::GaussianPrimitive& g = gaussians[i];
        const bool observed = (in_current_frustum == nullptr) ? true : in_current_frustum[i];
        const bool frame_valid = g.frame_last_seen <= current_frame;
        const std::uint64_t unseen = frame_valid ? (current_frame - g.frame_last_seen) : 0u;
        const bool should_decay =
            (!observed) && frame_valid && (unseen > static_cast<std::uint64_t>(config.grace_frames));
        const float delta_up = observed ? config.observation_boost : 0.0f;
        const float delta_down = should_decay ? config.decay_per_frame : 0.0f;
        const float next_conf = g.confidence + delta_up - delta_down;

        // Track per-Gaussian peak confidence.
        g.peak_confidence = std::max(g.peak_confidence, g.confidence);

        // Peak retention floor: confidence never decays below this fraction
        // of the Gaussian's own historical peak.  A Gaussian that once
        // reached confidence=0.9 will never drop below 0.9*0.6=0.54.
        // This prevents well-observed regions from fading to invisible.
        const float peak_floor = retention * g.peak_confidence;
        const float effective_min = std::max(config.min_confidence, peak_floor);
        g.confidence = std::max(effective_min, std::min(config.max_confidence, next_conf));
        g.frame_last_seen = observed ? current_frame : g.frame_last_seen;
    }

    return core::Status::kOk;
}

}  // namespace render
}  // namespace aether
