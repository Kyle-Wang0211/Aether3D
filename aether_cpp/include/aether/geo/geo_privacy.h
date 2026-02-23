// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_GEO_GEO_PRIVACY_H
#define AETHER_GEO_GEO_PRIVACY_H

#include "aether/core/status.h"

#include <cstddef>
#include <cstdint>

namespace aether {
namespace geo {

/// Output of the planar Laplace mechanism.
struct PrivatizedLocation {
    double lat{0};
    double lon{0};
    double epsilon_used{0};
};

/// Apply planar Laplace geo-indistinguishability noise.
/// seed: deterministic PRNG seed (sha256-based).
core::Status privatize_location(double lat_deg, double lon_deg,
                                double epsilon,
                                const std::uint8_t seed[32],
                                PrivatizedLocation* out);

/// Density-adaptive epsilon: adjusts epsilon based on local density.
/// Returns the adapted epsilon in [GEO_PRIVACY_MIN_EPSILON, GEO_PRIVACY_MAX_EPSILON].
double adaptive_epsilon(double base_epsilon,
                        std::uint32_t local_density_count,
                        std::uint32_t sparse_threshold);

/// AetherTemporalPrivacyGuard: 3-layer privacy for temporal streams.
struct TemporalPrivacyConfig {
    double base_epsilon{0.005};
    std::uint32_t segment_size{8};        // Reports per correlated noise block
    std::uint32_t sparse_threshold{10};   // Below → sparse protection mode
    double jitter_range{0.5};             // ±50% report interval jitter
};

struct TemporalPrivacyGuard;

TemporalPrivacyGuard* temporal_privacy_create(const TemporalPrivacyConfig& config);
void temporal_privacy_destroy(TemporalPrivacyGuard* guard);

/// Process a location report through the 3-layer guard.
/// report_index: sequential report counter within current segment.
core::Status temporal_privacy_process(TemporalPrivacyGuard* guard,
                                      double lat_deg, double lon_deg,
                                      std::uint32_t report_index,
                                      std::uint32_t local_density,
                                      const std::uint8_t seed[32],
                                      PrivatizedLocation* out);

}  // namespace geo
}  // namespace aether

#endif  // AETHER_GEO_GEO_PRIVACY_H
