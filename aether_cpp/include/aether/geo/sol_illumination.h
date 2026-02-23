// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_GEO_SOL_ILLUMINATION_H
#define AETHER_GEO_SOL_ILLUMINATION_H

#include "aether/core/status.h"

#include <cstdint>

namespace aether {
namespace geo {

/// Solar position in horizontal coordinates.
struct SolarPosition {
    double azimuth_deg{0};      // 0 = North, 90 = East
    double elevation_deg{0};    // >0 above horizon
    double declination_deg{0};
    double hour_angle_deg{0};
};

/// Day phase cascade: S0–S5.
enum class DayPhase : std::int32_t {
    kNight = 0,                  // S0: below astronomical twilight
    kAstronomicalTwilight = 1,   // S1: -18° to -12°
    kNauticalTwilight = 2,       // S2: -12° to -6°
    kCivilTwilight = 3,          // S3: -6° to 0°
    kGoldenHour = 4,             // S4: 0° to 10°
    kFullDay = 5,                // S5: above 10°
};

/// EnvironmentLight (SH band 0-2 coefficients for ambient + directional).
struct SolarEnvironmentLight {
    float sh_coeffs[9]{};       // SH bands 0-2 (9 coefficients)
    float sun_direction[3]{};   // Normalized sun direction (ECEF)
    float sun_color[3]{};       // Linear RGB sun color
    float sun_intensity{0};     // Direct intensity [0,1]
    float ambient_intensity{0}; // Ambient intensity
    DayPhase phase{DayPhase::kNight};
};

/// Compute solar position using Simplified PSA algorithm.
/// timestamp_utc: UNIX timestamp in seconds.
/// lat_deg, lon_deg: observer position.
core::Status solar_position(double timestamp_utc,
                            double lat_deg, double lon_deg,
                            SolarPosition* out);

/// Determine day phase from solar elevation.
DayPhase solar_day_phase(double elevation_deg);

/// Compute environment light from solar position.
core::Status solar_environment_light(const SolarPosition& pos,
                                     double lat_deg, double lon_deg,
                                     SolarEnvironmentLight* out);

/// Compute terminator circle (great circle where elevation = 0).
/// out_lats/out_lons: arrays of size SOL_TERMINATOR_STEPS.
core::Status solar_terminator(double timestamp_utc,
                              double* out_lats, double* out_lons,
                              std::uint32_t step_count);

/// Interpolate between two environment lights for smooth transitions.
void solar_interpolate(const SolarEnvironmentLight& from,
                       const SolarEnvironmentLight& to,
                       float t,
                       SolarEnvironmentLight* out);

}  // namespace geo
}  // namespace aether

#endif  // AETHER_GEO_SOL_ILLUMINATION_H
