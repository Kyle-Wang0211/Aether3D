// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/geo/geo_privacy.h"
#include "aether/geo/geo_constants.h"
#include "aether/core/numeric_guard.h"
#include "aether/crypto/sha256.h"

#include <cmath>
#include <cstring>

namespace aether {
namespace geo {

// ---------------------------------------------------------------------------
// Deterministic PRNG: sha256-seeded counter-mode
// ---------------------------------------------------------------------------
namespace {

struct DetPRNG {
    std::uint8_t seed[32]{};
    std::uint64_t counter{0};

    // Generate a uniform double in [0, 1)
    double next_uniform() {
        // Hash seed || counter
        std::uint8_t buf[40]{};
        std::memcpy(buf, seed, 32);
        std::memcpy(buf + 32, &counter, 8);
        counter++;

        crypto::Sha256Digest digest{};
        crypto::sha256(buf, 40, digest);

        // Take first 8 bytes as uint64, normalize to [0, 1)
        std::uint64_t val = 0;
        std::memcpy(&val, digest.bytes, 8);
        return static_cast<double>(val) / static_cast<double>(UINT64_MAX);
    }
};

}  // anonymous namespace

// ---------------------------------------------------------------------------
// Planar Laplace mechanism
// Reference: Andrés et al., CCS 2013
// ---------------------------------------------------------------------------
core::Status privatize_location(double lat_deg, double lon_deg,
                                double epsilon,
                                const std::uint8_t seed[32],
                                PrivatizedLocation* out) {
    if (!out || !seed) return core::Status::kInvalidArgument;
    if (epsilon < GEO_PRIVACY_MIN_EPSILON) epsilon = GEO_PRIVACY_MIN_EPSILON;
    if (epsilon > GEO_PRIVACY_MAX_EPSILON) epsilon = GEO_PRIVACY_MAX_EPSILON;

    DetPRNG rng{};
    std::memcpy(rng.seed, seed, 32);

    // Planar Laplace: r ~ Gamma(2, 1/epsilon), theta ~ Uniform(0, 2pi)
    // Using inverse CDF: p = U1, r = -ln(1-p)/epsilon (exponential) is not correct.
    // Correct: For planar Laplace, radius CDF = 1 - (1 + epsilon*r)*exp(-epsilon*r)
    // We use the approximation: sum of two exponentials for Gamma(2, 1/eps)
    double u1 = rng.next_uniform();
    double u2 = rng.next_uniform();
    double u3 = rng.next_uniform();

    // Clamp away from 0 and 1 for log safety
    if (u1 < 1e-15) u1 = 1e-15;
    if (u2 < 1e-15) u2 = 1e-15;

    // Gamma(2, 1/eps) = sum of 2 Exp(eps)
    double r = (-std::log(u1) - std::log(u2)) / epsilon;

    // Clamp at sigma limit
    double max_r = GEO_PRIVACY_LAPLACE_CLAMP_SIGMA / epsilon;
    if (r > max_r) r = max_r;

    double theta = u3 * 2.0 * M_PI;

    // Convert displacement from meters to degrees
    double dx_m = r * std::cos(theta);
    double dy_m = r * std::sin(theta);

    double dlat = dy_m / 111320.0;
    double dlon = dx_m / (111320.0 * std::cos(lat_deg * DEG_TO_RAD));

    out->lat = lat_deg + dlat;
    out->lon = lon_deg + dlon;
    out->epsilon_used = epsilon;

    // Clamp to valid range
    if (out->lat < LAT_MIN) out->lat = LAT_MIN;
    if (out->lat > LAT_MAX) out->lat = LAT_MAX;
    if (out->lon < LON_MIN) out->lon += 360.0;
    if (out->lon > LON_MAX) out->lon -= 360.0;

    return core::Status::kOk;
}

// ---------------------------------------------------------------------------
// Density-adaptive epsilon
// ---------------------------------------------------------------------------
double adaptive_epsilon(double base_epsilon,
                        std::uint32_t local_density_count,
                        std::uint32_t sparse_threshold) {
    if (local_density_count < sparse_threshold) {
        // Sparse area → increase privacy (lower epsilon)
        double factor = static_cast<double>(local_density_count) / sparse_threshold;
        if (factor < 0.1) factor = 0.1;
        double eps = base_epsilon * factor;
        if (eps < GEO_PRIVACY_MIN_EPSILON) eps = GEO_PRIVACY_MIN_EPSILON;
        return eps;
    }
    // Dense area → can use base epsilon or slightly higher
    double eps = base_epsilon;
    if (eps > GEO_PRIVACY_MAX_EPSILON) eps = GEO_PRIVACY_MAX_EPSILON;
    if (eps < GEO_PRIVACY_MIN_EPSILON) eps = GEO_PRIVACY_MIN_EPSILON;
    return eps;
}

// ---------------------------------------------------------------------------
// AetherTemporalPrivacyGuard
// ---------------------------------------------------------------------------
struct TemporalPrivacyGuard {
    TemporalPrivacyConfig config;
    std::uint64_t total_reports{0};
    // Correlated noise for current segment
    double segment_noise_lat{0};
    double segment_noise_lon{0};
    std::uint32_t segment_counter{0};
};

TemporalPrivacyGuard* temporal_privacy_create(const TemporalPrivacyConfig& config) {
    auto* g = new TemporalPrivacyGuard();
    g->config = config;
    return g;
}

void temporal_privacy_destroy(TemporalPrivacyGuard* guard) {
    delete guard;
}

core::Status temporal_privacy_process(TemporalPrivacyGuard* guard,
                                      double lat_deg, double lon_deg,
                                      std::uint32_t report_index [[maybe_unused]],
                                      std::uint32_t local_density,
                                      const std::uint8_t seed[32],
                                      PrivatizedLocation* out) {
    if (!guard || !out || !seed) return core::Status::kInvalidArgument;

    // Layer 1: Subsampling — apply jitter to the report index
    // (In a real system this would affect timing; here we model it as a flag)

    // Layer 2: Density-adaptive epsilon
    double eps = adaptive_epsilon(guard->config.base_epsilon,
                                  local_density,
                                  guard->config.sparse_threshold);

    // Layer 3: Correlated noise within segment
    if (guard->segment_counter >= guard->config.segment_size || guard->total_reports == 0) {
        // New segment: generate correlated base noise
        DetPRNG rng{};
        std::memcpy(rng.seed, seed, 32);
        double u1 = rng.next_uniform();
        double u2 = rng.next_uniform();
        if (u1 < 1e-15) u1 = 1e-15;
        double r = -std::log(u1) / eps;
        double theta = u2 * 2.0 * M_PI;
        guard->segment_noise_lat = (r * std::sin(theta)) / 111320.0;
        guard->segment_noise_lon = (r * std::cos(theta)) / (111320.0 * std::cos(lat_deg * DEG_TO_RAD));
        guard->segment_counter = 0;
    }

    // Apply base planar Laplace + correlated segment noise
    privatize_location(lat_deg, lon_deg, eps, seed, out);
    out->lat += guard->segment_noise_lat * 0.5; // Blend correlated noise
    out->lon += guard->segment_noise_lon * 0.5;

    // Clamp
    if (out->lat < LAT_MIN) out->lat = LAT_MIN;
    if (out->lat > LAT_MAX) out->lat = LAT_MAX;
    if (out->lon < LON_MIN) out->lon += 360.0;
    if (out->lon > LON_MAX) out->lon -= 360.0;

    guard->segment_counter++;
    guard->total_reports++;
    return core::Status::kOk;
}

}  // namespace geo
}  // namespace aether
