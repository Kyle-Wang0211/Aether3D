// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_GEO_SPOOF_DETECTOR_H
#define AETHER_GEO_SPOOF_DETECTOR_H

#include "aether/core/status.h"

#include <cstdint>

namespace aether {
namespace geo {

/// GPS fix with sensor accompaniment for spoof detection.
struct GeoFix {
    double lat{0};
    double lon{0};
    double altitude_m{0};
    double timestamp_s{0};
    float speed_ms{0};               // Platform-reported speed
    float imu_displacement_m{0};     // IMU dead-reckoned displacement since last fix
    float baro_altitude_m{0};        // Barometer altitude
    float cnr_db_hz{0};              // Carrier-to-noise ratio (C/N₀)
    float carrier_phase_vel_ms{0};   // Carrier phase velocity
    std::uint32_t satellite_count{0};
};

/// Per-layer detection result.
struct LayerResult {
    float mass_spoof{0};     // D-S mass for "spoofed"
    float mass_genuine{0};   // D-S mass for "genuine"
    float mass_unknown{0};   // D-S mass for "unknown"
};

/// Overall spoof detection result.
struct SpoofResult {
    float plausibility_score{1.0f};   // 0 = certainly spoofed, 1 = certainly genuine
    bool is_spoofed{false};           // True if plausibility < 0.5
    LayerResult layers[5]{};          // Per-layer results
    float fused_mass_spoof{0};
    float fused_mass_genuine{0};
};

/// Opaque spoof detector handle.
struct SpoofDetector;

/// Create / destroy.
SpoofDetector* spoof_detector_create();
void spoof_detector_destroy(SpoofDetector* detector);

/// Process a new GPS fix through the 5-layer detector.
core::Status spoof_detector_process(SpoofDetector* detector,
                                    const GeoFix& fix,
                                    SpoofResult* out_result);

/// Reset detector state (e.g., after user teleport).
void spoof_detector_reset(SpoofDetector* detector);

/// Get the number of fixes in the history buffer.
std::uint32_t spoof_detector_history_count(const SpoofDetector* detector);

}  // namespace geo
}  // namespace aether

#endif  // AETHER_GEO_SPOOF_DETECTOR_H
