// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/geo/geo_privacy.h"
#include "aether/geo/geo_constants.h"
#include "aether/geo/haversine.h"
#include "aether/core/status.h"

#include <cmath>
#include <cstdio>
#include <cstring>

int main() {
    int failed = 0;

    std::uint8_t seed[32]{};
    // Use a fixed seed for determinism
    for (int i = 0; i < 32; ++i) seed[i] = static_cast<std::uint8_t>(i + 42);

    // Test 1: Basic privatization
    {
        aether::geo::PrivatizedLocation out{};
        auto s = aether::geo::privatize_location(51.5074, -0.1278,
                                                  aether::geo::GEO_PRIVACY_DEFAULT_EPSILON,
                                                  seed, &out);
        if (s != aether::core::Status::kOk) {
            std::fprintf(stderr, "privatize failed\n"); ++failed;
        }
        // Output should be different from input
        double d = aether::geo::distance_haversine(51.5074, -0.1278, out.lat, out.lon);
        // With default epsilon (~200m radius), noise should typically be < 2000m
        if (d > 20000.0) {
            std::fprintf(stderr, "privatize displacement too large: %.0f m\n", d);
            ++failed;
        }
        // Should not be exactly the same
        if (std::fabs(out.lat - 51.5074) < 1e-10 && std::fabs(out.lon + 0.1278) < 1e-10) {
            std::fprintf(stderr, "privatize: no noise applied\n");
            ++failed;
        }
    }

    // Test 2: Determinism — same seed gives same output
    {
        aether::geo::PrivatizedLocation out1{}, out2{};
        aether::geo::privatize_location(51.5074, -0.1278,
                                         aether::geo::GEO_PRIVACY_DEFAULT_EPSILON, seed, &out1);
        aether::geo::privatize_location(51.5074, -0.1278,
                                         aether::geo::GEO_PRIVACY_DEFAULT_EPSILON, seed, &out2);
        if (std::fabs(out1.lat - out2.lat) > 1e-15 || std::fabs(out1.lon - out2.lon) > 1e-15) {
            std::fprintf(stderr, "determinism: different outputs for same seed\n");
            ++failed;
        }
    }

    // Test 3: Different seeds give different output
    {
        std::uint8_t seed2[32]{};
        for (int i = 0; i < 32; ++i) seed2[i] = static_cast<std::uint8_t>(i + 99);

        aether::geo::PrivatizedLocation out1{}, out2{};
        aether::geo::privatize_location(51.5074, -0.1278,
                                         aether::geo::GEO_PRIVACY_DEFAULT_EPSILON, seed, &out1);
        aether::geo::privatize_location(51.5074, -0.1278,
                                         aether::geo::GEO_PRIVACY_DEFAULT_EPSILON, seed2, &out2);
        if (std::fabs(out1.lat - out2.lat) < 1e-10 && std::fabs(out1.lon - out2.lon) < 1e-10) {
            std::fprintf(stderr, "different seeds: same output\n");
            ++failed;
        }
    }

    // Test 4: Clamped epsilon range
    {
        aether::geo::PrivatizedLocation out{};
        // Epsilon below min → clamped
        aether::geo::privatize_location(0, 0, 0.0001, seed, &out);
        if (out.epsilon_used < aether::geo::GEO_PRIVACY_MIN_EPSILON) {
            std::fprintf(stderr, "epsilon not clamped to min\n"); ++failed;
        }
        // Epsilon above max → clamped
        aether::geo::privatize_location(0, 0, 1.0, seed, &out);
        if (out.epsilon_used > aether::geo::GEO_PRIVACY_MAX_EPSILON) {
            std::fprintf(stderr, "epsilon not clamped to max\n"); ++failed;
        }
    }

    // Test 5: Output stays in valid range
    {
        aether::geo::PrivatizedLocation out{};
        // Near poles
        aether::geo::privatize_location(89.99, 179.99, 0.01, seed, &out);
        if (out.lat < -90.0 || out.lat > 90.0) {
            std::fprintf(stderr, "lat out of range: %.6f\n", out.lat); ++failed;
        }
    }

    // Test 6: Adaptive epsilon
    {
        double eps_sparse = aether::geo::adaptive_epsilon(0.005, 3, 10);
        double eps_dense = aether::geo::adaptive_epsilon(0.005, 100, 10);
        if (eps_sparse >= eps_dense) {
            std::fprintf(stderr, "adaptive: sparse eps (%.6f) should be < dense eps (%.6f)\n",
                         eps_sparse, eps_dense);
            ++failed;
        }
    }

    // Test 7: Temporal privacy guard
    {
        aether::geo::TemporalPrivacyConfig config{};
        config.base_epsilon = 0.005;
        config.segment_size = 4;
        config.sparse_threshold = 10;
        config.jitter_range = 0.5;

        auto* guard = aether::geo::temporal_privacy_create(config);
        if (!guard) {
            std::fprintf(stderr, "temporal_privacy_create null\n"); ++failed;
        } else {
            aether::geo::PrivatizedLocation out{};
            for (int i = 0; i < 10; ++i) {
                std::uint8_t s[32]{};
                for (int j = 0; j < 32; ++j) s[j] = static_cast<std::uint8_t>(i * 32 + j);
                auto status = aether::geo::temporal_privacy_process(
                    guard, 51.5, -0.13, static_cast<std::uint32_t>(i), 50, s, &out);
                if (status != aether::core::Status::kOk) {
                    std::fprintf(stderr, "temporal_privacy_process[%d] failed\n", i);
                    ++failed;
                }
            }
            aether::geo::temporal_privacy_destroy(guard);
        }
    }

    // Test 8: Null pointer checks
    {
        auto s = aether::geo::privatize_location(0, 0, 0.005, seed, nullptr);
        if (s != aether::core::Status::kInvalidArgument) {
            std::fprintf(stderr, "null out: expected kInvalidArgument\n"); ++failed;
        }
        s = aether::geo::privatize_location(0, 0, 0.005, nullptr, nullptr);
        if (s != aether::core::Status::kInvalidArgument) {
            std::fprintf(stderr, "null seed: expected kInvalidArgument\n"); ++failed;
        }
    }

    return failed;
}
