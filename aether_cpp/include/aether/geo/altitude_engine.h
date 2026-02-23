// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_GEO_ALTITUDE_ENGINE_H
#define AETHER_GEO_ALTITUDE_ENGINE_H

#include "aether/core/status.h"

#include <cstddef>
#include <cstdint>

namespace aether {
namespace geo {

/// 5-state EKF state: [h, v_h, b_baro, b_gnss, sigma_vio]
struct AltitudeState {
    double h;               // Fused altitude (m)
    double v_h;             // Vertical velocity (m/s)
    double b_baro;          // Barometer bias (m)
    double b_gnss;          // GNSS bias (m)
    double sigma_vio;       // VIO drift estimate (m)
    double P[25];           // 5x5 covariance matrix (row-major)
    double iaqs_q_scale;    // IAQS adaptive Q scale factor
    int32_t floor_level;    // Detected floor level
    double confidence;      // Fusion confidence [0,1]
    uint64_t frame_counter; // Number of predict/update cycles
};

struct AltitudeMeasurement {
    double gnss_alt_m;
    double baro_alt_m;
    double vio_delta_h;
    double dt_s;
    double geoid_undulation_m;
};

struct AltitudeEngine;

/// Create a new altitude engine instance.
AltitudeEngine* altitude_engine_create();

/// Destroy an altitude engine instance.
void altitude_engine_destroy(AltitudeEngine* engine);

/// EKF predict step.
core::Status altitude_engine_predict(AltitudeEngine* engine, double dt_s);

/// EKF update step with sensor measurements.
core::Status altitude_engine_update(AltitudeEngine* engine,
                                    const AltitudeMeasurement& meas);

/// Get the current state (read-only).
const AltitudeState* altitude_engine_state(const AltitudeEngine* engine);

/// Reset the engine to initial state.
void altitude_engine_reset(AltitudeEngine* engine);

}  // namespace geo
}  // namespace aether

#endif  // AETHER_GEO_ALTITUDE_ENGINE_H
