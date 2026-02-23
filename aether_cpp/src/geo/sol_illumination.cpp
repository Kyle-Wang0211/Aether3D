// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/geo/sol_illumination.h"
#include "aether/geo/geo_constants.h"
#include "aether/core/numeric_guard.h"

#include <cmath>

namespace aether {
namespace geo {

// ---------------------------------------------------------------------------
// Simplified PSA (Plataforma Solar de Almería) algorithm
// Reference: Blanco-Muriel et al., Solar Energy 70 (2001) 431–441
// ---------------------------------------------------------------------------

static constexpr double kPi = 3.14159265358979323846;
static constexpr double kTwoPi = 2.0 * kPi;

// Julian day from Unix timestamp
static double unix_to_jd(double timestamp_utc) {
    return timestamp_utc / 86400.0 + 2440587.5;
}

// Julian century from J2000.0
static double jd_to_jc(double jd) {
    return (jd - 2451545.0) / 36525.0;
}

core::Status solar_position(double timestamp_utc,
                            double lat_deg, double lon_deg,
                            SolarPosition* out) {
    if (!out) return core::Status::kInvalidArgument;

    const double jd = unix_to_jd(timestamp_utc);
    const double T = jd_to_jc(jd);

    // Mean longitude (degrees)
    double L0 = 280.46646 + 36000.76983 * T + 0.0003032 * T * T;
    L0 = std::fmod(L0, 360.0);
    if (L0 < 0) L0 += 360.0;

    // Mean anomaly (degrees)
    double M = 357.52911 + 35999.05029 * T - 0.0001537 * T * T;
    M = std::fmod(M, 360.0);
    if (M < 0) M += 360.0;
    double M_rad = M * DEG_TO_RAD;

    // Equation of center (degrees)
    double C = (1.914602 - 0.004817 * T - 0.000014 * T * T) * std::sin(M_rad)
             + (0.019993 - 0.000101 * T) * std::sin(2.0 * M_rad)
             + 0.000289 * std::sin(3.0 * M_rad);

    // Sun's true longitude
    double sun_lon = L0 + C;

    // Obliquity of ecliptic
    double obliquity = SOL_OBLIQUITY_J2000 - 0.013004167 * T;
    double obliquity_rad = obliquity * DEG_TO_RAD;

    // Right ascension and declination
    double sun_lon_rad = sun_lon * DEG_TO_RAD;
    double sin_dec = std::sin(obliquity_rad) * std::sin(sun_lon_rad);
    double declination = std::asin(sin_dec) * RAD_TO_DEG;

    double ra = std::atan2(std::cos(obliquity_rad) * std::sin(sun_lon_rad),
                           std::cos(sun_lon_rad)) * RAD_TO_DEG;
    if (ra < 0) ra += 360.0;

    // Greenwich Mean Sidereal Time
    double gmst = 280.46061837 + 360.98564736629 * (jd - 2451545.0)
                + 0.000387933 * T * T;
    gmst = std::fmod(gmst, 360.0);
    if (gmst < 0) gmst += 360.0;

    // Hour angle
    double ha = gmst + lon_deg - ra;
    ha = std::fmod(ha, 360.0);
    if (ha < 0) ha += 360.0;
    if (ha > 180.0) ha -= 360.0;

    // Horizontal coordinates
    double lat_rad = lat_deg * DEG_TO_RAD;
    double dec_rad = declination * DEG_TO_RAD;
    double ha_rad = ha * DEG_TO_RAD;

    double sin_elev = std::sin(lat_rad) * std::sin(dec_rad) +
                      std::cos(lat_rad) * std::cos(dec_rad) * std::cos(ha_rad);
    double elevation = std::asin(sin_elev) * RAD_TO_DEG;

    double cos_az = (std::sin(dec_rad) - std::sin(lat_rad) * sin_elev) /
                    (std::cos(lat_rad) * std::cos(elevation * DEG_TO_RAD));
    // Clamp for numerical safety
    if (cos_az > 1.0) cos_az = 1.0;
    if (cos_az < -1.0) cos_az = -1.0;
    double azimuth = std::acos(cos_az) * RAD_TO_DEG;
    if (ha > 0) azimuth = 360.0 - azimuth;

    out->azimuth_deg = azimuth;
    out->elevation_deg = elevation;
    out->declination_deg = declination;
    out->hour_angle_deg = ha;
    return core::Status::kOk;
}

DayPhase solar_day_phase(double elevation_deg) {
    if (elevation_deg >= SOL_FULL_DAY_ELEVATION_DEG) return DayPhase::kFullDay;
    if (elevation_deg >= 0.0) return DayPhase::kGoldenHour;
    if (elevation_deg >= SOL_CIVIL_TWILIGHT_DEG) return DayPhase::kCivilTwilight;
    if (elevation_deg >= SOL_NAUTICAL_TWILIGHT_DEG) return DayPhase::kNauticalTwilight;
    if (elevation_deg >= SOL_ASTRONOMICAL_TWILIGHT_DEG) return DayPhase::kAstronomicalTwilight;
    return DayPhase::kNight;
}

core::Status solar_environment_light(const SolarPosition& pos,
                                     double /*lat_deg*/, double /*lon_deg*/,
                                     SolarEnvironmentLight* out) {
    if (!out) return core::Status::kInvalidArgument;

    out->phase = solar_day_phase(pos.elevation_deg);

    // Sun direction in local ENU → convert to simplified direction
    double az_rad = pos.azimuth_deg * DEG_TO_RAD;
    double el_rad = pos.elevation_deg * DEG_TO_RAD;
    out->sun_direction[0] = static_cast<float>(std::sin(az_rad) * std::cos(el_rad));
    out->sun_direction[1] = static_cast<float>(std::sin(el_rad));
    out->sun_direction[2] = static_cast<float>(std::cos(az_rad) * std::cos(el_rad));

    // Intensity based on phase
    float intensity = 0.0f;
    float ambient = static_cast<float>(SOL_NIGHT_AMBIENT_MIN);

    switch (out->phase) {
        case DayPhase::kFullDay:
            intensity = 1.0f;
            ambient = static_cast<float>(SOL_DAY_AMBIENT_RATIO);
            break;
        case DayPhase::kGoldenHour: {
            float t = static_cast<float>(pos.elevation_deg / SOL_FULL_DAY_ELEVATION_DEG);
            intensity = 0.3f + 0.7f * t;
            ambient = static_cast<float>(SOL_NIGHT_AMBIENT_MIN +
                (SOL_DAY_AMBIENT_RATIO - SOL_NIGHT_AMBIENT_MIN) * t);
            break;
        }
        case DayPhase::kCivilTwilight: {
            float t = static_cast<float>((pos.elevation_deg - SOL_CIVIL_TWILIGHT_DEG) / 6.0);
            intensity = 0.1f + 0.2f * t;
            ambient = static_cast<float>(SOL_NIGHT_AMBIENT_MIN + 0.1 * t);
            break;
        }
        case DayPhase::kNauticalTwilight:
            intensity = 0.02f;
            ambient = static_cast<float>(SOL_NIGHT_AMBIENT_MIN + 0.02);
            break;
        case DayPhase::kAstronomicalTwilight:
            intensity = 0.005f;
            ambient = static_cast<float>(SOL_NIGHT_AMBIENT_MIN + 0.005);
            break;
        case DayPhase::kNight:
            intensity = 0.0f;
            break;
    }

    out->sun_intensity = intensity;
    out->ambient_intensity = ambient;

    // Sun color: warm at golden hour, neutral at noon
    if (out->phase == DayPhase::kGoldenHour) {
        float t = static_cast<float>(pos.elevation_deg / SOL_FULL_DAY_ELEVATION_DEG);
        out->sun_color[0] = 1.0f;
        out->sun_color[1] = 0.85f + 0.15f * t;
        out->sun_color[2] = 0.6f + 0.4f * t;
    } else {
        out->sun_color[0] = 1.0f;
        out->sun_color[1] = 0.98f;
        out->sun_color[2] = 0.95f;
    }

    // SH coefficients: band 0 = ambient, bands 1-2 = directional
    // Band 0: Y_00 = 1/(2*sqrt(pi))
    float y00 = 0.2820947917738781f;  // 1/(2*sqrt(pi))
    out->sh_coeffs[0] = ambient * y00;

    // Band 1: directional (Y_1,-1, Y_1,0, Y_1,1)
    float y1_scale = 0.4886025119029199f; // sqrt(3)/(2*sqrt(pi))
    out->sh_coeffs[1] = intensity * out->sun_direction[1] * y1_scale;
    out->sh_coeffs[2] = intensity * out->sun_direction[2] * y1_scale;
    out->sh_coeffs[3] = intensity * out->sun_direction[0] * y1_scale;

    // Band 2 (simplified — just directional dominance)
    float y2_scale = 0.3153915652525200f;
    float dx = out->sun_direction[0], dy = out->sun_direction[1], dz = out->sun_direction[2];
    out->sh_coeffs[4] = intensity * dx * dz * y2_scale;
    out->sh_coeffs[5] = intensity * dy * dz * y2_scale;
    out->sh_coeffs[6] = intensity * (3.0f * dy * dy - 1.0f) * y2_scale * 0.5f;
    out->sh_coeffs[7] = intensity * dx * dy * y2_scale;
    out->sh_coeffs[8] = intensity * (dx * dx - dz * dz) * y2_scale * 0.5f;

    // NumericGuard on all float outputs
    core::guard_finite_vector(out->sh_coeffs, 9);
    core::guard_finite_vector(out->sun_direction, 3);
    core::guard_finite_vector(out->sun_color, 3);
    core::guard_finite_scalar(&out->sun_intensity);
    core::guard_finite_scalar(&out->ambient_intensity);

    return core::Status::kOk;
}

core::Status solar_terminator(double timestamp_utc,
                              double* out_lats, double* out_lons,
                              std::uint32_t step_count) {
    if (!out_lats || !out_lons || step_count == 0) {
        return core::Status::kInvalidArgument;
    }

    // Compute subsolar point
    SolarPosition pos{};
    solar_position(timestamp_utc, 0.0, 0.0, &pos);

    double subsolar_lat = pos.declination_deg;

    // Subsolar longitude ≈ -(hour_angle at lon=0)
    const double jd = unix_to_jd(timestamp_utc);
    double gmst = 280.46061837 + 360.98564736629 * (jd - 2451545.0);
    gmst = std::fmod(gmst, 360.0);

    double subsolar_lat_rad = subsolar_lat * DEG_TO_RAD;

    // Terminator = great circle 90° from subsolar point
    for (std::uint32_t i = 0; i < step_count; ++i) {
        double angle = (static_cast<double>(i) / step_count) * kTwoPi;
        // Point on the terminator circle
        double lat = std::asin(std::cos(subsolar_lat_rad) * std::sin(angle));
        double lon = std::atan2(std::cos(angle),
                                -std::sin(subsolar_lat_rad) * std::sin(angle));
        // Adjust for subsolar longitude
        lon += gmst * DEG_TO_RAD;

        out_lats[i] = lat * RAD_TO_DEG;
        out_lons[i] = std::fmod(lon * RAD_TO_DEG + 540.0, 360.0) - 180.0;
    }

    return core::Status::kOk;
}

void solar_interpolate(const SolarEnvironmentLight& from,
                       const SolarEnvironmentLight& to,
                       float t,
                       SolarEnvironmentLight* out) {
    if (!out) return;
    float s = 1.0f - t;

    for (int i = 0; i < 9; ++i) {
        out->sh_coeffs[i] = s * from.sh_coeffs[i] + t * to.sh_coeffs[i];
    }
    for (int i = 0; i < 3; ++i) {
        out->sun_direction[i] = s * from.sun_direction[i] + t * to.sun_direction[i];
        out->sun_color[i] = s * from.sun_color[i] + t * to.sun_color[i];
    }
    out->sun_intensity = s * from.sun_intensity + t * to.sun_intensity;
    out->ambient_intensity = s * from.ambient_intensity + t * to.ambient_intensity;
    out->phase = (t < 0.5f) ? from.phase : to.phase;

    // Normalize sun direction
    float len = std::sqrt(out->sun_direction[0] * out->sun_direction[0] +
                          out->sun_direction[1] * out->sun_direction[1] +
                          out->sun_direction[2] * out->sun_direction[2]);
    if (len > 1e-6f) {
        out->sun_direction[0] /= len;
        out->sun_direction[1] /= len;
        out->sun_direction[2] /= len;
    }
}

}  // namespace geo
}  // namespace aether
