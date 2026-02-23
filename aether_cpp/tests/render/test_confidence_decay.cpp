// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/render/confidence_decay.h"
#include "aether/innovation/core_types.h"

#include <cmath>
#include <cstdio>
#include <vector>

namespace {

[[maybe_unused]] bool approx(float a, float b, float eps = 1e-5f) {
    return std::fabs(a - b) <= eps;
}

}  // namespace

int main() {
    int failed = 0;
    using namespace aether::render;
    using namespace aether::innovation;

    // -- Test 1: Decay with all gaussians in frustum (observed) should boost. --
    {
        GaussianPrimitive g{};
        g.id = 1;
        g.confidence = 0.5f;
        g.frame_last_seen = 0;

        bool in_frustum = true;
        ConfidenceDecayConfig config{};
        config.observation_boost = 0.15f;
        config.max_confidence = 1.0f;

        auto st = decay_confidence(&g, 1, &in_frustum, 100, config);
        if (st != aether::core::Status::kOk) {
            std::fprintf(stderr, "decay_confidence returned error\n");
            failed++;
        }
        // Should have boosted confidence.
        if (g.confidence <= 0.5f) {
            std::fprintf(stderr,
                         "confidence should increase when in frustum, got %f\n",
                         g.confidence);
            failed++;
        }
    }

    // -- Test 2: Decay with gaussians NOT in frustum should reduce confidence. --
    {
        GaussianPrimitive g{};
        g.id = 2;
        g.confidence = 0.8f;
        g.frame_last_seen = 0;

        bool in_frustum = false;
        ConfidenceDecayConfig config{};
        config.decay_per_frame = 0.1f;
        config.min_confidence = 0.05f;
        config.grace_frames = 0;  // No grace period.

        auto st = decay_confidence(&g, 1, &in_frustum, 100, config);
        if (st != aether::core::Status::kOk) {
            std::fprintf(stderr, "decay_confidence returned error\n");
            failed++;
        }
        if (g.confidence >= 0.8f) {
            std::fprintf(stderr,
                         "confidence should decrease when not in frustum, got %f\n",
                         g.confidence);
            failed++;
        }
    }

    // -- Test 3: Confidence should never fall below min_confidence. --
    {
        GaussianPrimitive g{};
        g.id = 3;
        g.confidence = 0.06f;
        g.frame_last_seen = 0;

        bool in_frustum = false;
        ConfidenceDecayConfig config{};
        config.decay_per_frame = 0.5f;
        config.min_confidence = 0.05f;
        config.grace_frames = 0;

        // Apply many decays.
        for (int i = 1; i <= 20; ++i) {
            decay_confidence(&g, 1, &in_frustum, static_cast<uint64_t>(i), config);
        }

        if (g.confidence < config.min_confidence) {
            std::fprintf(stderr,
                         "confidence %f fell below min_confidence %f\n",
                         g.confidence, config.min_confidence);
            failed++;
        }
    }

    // -- Test 4: Confidence should never exceed max_confidence. --
    {
        GaussianPrimitive g{};
        g.id = 4;
        g.confidence = 0.95f;
        g.frame_last_seen = 0;

        bool in_frustum = true;
        ConfidenceDecayConfig config{};
        config.observation_boost = 0.5f;
        config.max_confidence = 1.0f;

        for (int i = 1; i <= 20; ++i) {
            decay_confidence(&g, 1, &in_frustum, static_cast<uint64_t>(i), config);
        }

        if (g.confidence > config.max_confidence) {
            std::fprintf(stderr,
                         "confidence %f exceeded max_confidence %f\n",
                         g.confidence, config.max_confidence);
            failed++;
        }
    }

    // -- Test 5: Grace period should protect recently-seen gaussians. --
    {
        GaussianPrimitive g{};
        g.id = 5;
        g.confidence = 0.9f;
        g.frame_last_seen = 95;

        bool in_frustum = false;
        ConfidenceDecayConfig config{};
        config.decay_per_frame = 0.1f;
        config.min_confidence = 0.05f;
        config.grace_frames = 30;  // Grace for 30 frames.

        // Current frame is 100, last seen at 95. Within grace period.
        auto st = decay_confidence(&g, 1, &in_frustum, 100, config);
        if (st != aether::core::Status::kOk) {
            std::fprintf(stderr, "decay_confidence returned error in grace test\n");
            failed++;
        }
        // Within grace: confidence should not decay (or decay minimally).
        if (g.confidence < 0.85f) {
            std::fprintf(stderr,
                         "within grace period, confidence should be preserved, got %f\n",
                         g.confidence);
            failed++;
        }
    }

    // -- Test 6: Batch decay with multiple gaussians. --
    {
        std::vector<GaussianPrimitive> gs(4);
        bool in_frustum[4]{};

        for (int i = 0; i < 4; ++i) {
            gs[i].id = static_cast<GaussianId>(10 + i);
            gs[i].confidence = 0.7f;
            gs[i].frame_last_seen = 0;
            in_frustum[i] = (i % 2 == 0);  // Even indices in frustum.
        }

        ConfidenceDecayConfig config{};
        config.grace_frames = 0;

        auto st = decay_confidence(gs.data(), gs.size(), in_frustum, 50, config);
        if (st != aether::core::Status::kOk) {
            std::fprintf(stderr, "batch decay_confidence returned error\n");
            failed++;
        }

        // Gaussians in frustum (index 0, 2) should have higher confidence
        // than those not in frustum (index 1, 3).
        if (gs[0].confidence <= gs[1].confidence) {
            std::fprintf(stderr,
                         "in-frustum gaussian should have higher confidence "
                         "than out-of-frustum: %f vs %f\n",
                         gs[0].confidence, gs[1].confidence);
            failed++;
        }
    }

    // -- Test 7: Zero count should be a no-op. --
    {
        auto st = decay_confidence(nullptr, 0, nullptr, 100, ConfidenceDecayConfig{});
        if (st != aether::core::Status::kOk) {
            std::fprintf(stderr,
                         "decay_confidence with count=0 should return ok\n");
            failed++;
        }
    }

    // -- Test 8: Default config values are sane. --
    {
        ConfidenceDecayConfig config{};
        if (config.decay_per_frame <= 0.0f) {
            std::fprintf(stderr,
                         "default decay_per_frame should be positive: %f\n",
                         config.decay_per_frame);
            failed++;
        }
        if (config.min_confidence < 0.0f || config.min_confidence >= 1.0f) {
            std::fprintf(stderr,
                         "default min_confidence out of range: %f\n",
                         config.min_confidence);
            failed++;
        }
        if (config.max_confidence <= 0.0f) {
            std::fprintf(stderr,
                         "default max_confidence should be positive: %f\n",
                         config.max_confidence);
            failed++;
        }
    }

    return failed;
}
