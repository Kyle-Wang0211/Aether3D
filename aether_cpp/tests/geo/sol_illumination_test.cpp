// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/geo/sol_illumination.h"
#include "aether/geo/geo_constants.h"
#include "aether/core/status.h"

#include <cmath>
#include <cstdio>

int main() {
    int failed = 0;

    // Golden vectors: NOAA Solar Calculator reference values
    // All times are Unix timestamps (UTC)

    // Test 1: Summer solstice 2024 noon UTC at Greenwich (51.4769, -0.0005)
    // 2024-06-20 12:00:00 UTC = 1718884800
    {
        aether::geo::SolarPosition pos{};
        auto s = aether::geo::solar_position(1718884800.0, 51.4769, -0.0005, &pos);
        if (s != aether::core::Status::kOk) {
            std::fprintf(stderr, "solstice position failed\n"); ++failed;
        }
        // Elevation at summer solstice noon at 51.5°N should be ~62°
        if (std::fabs(pos.elevation_deg - 62.0) > 3.0) {
            std::fprintf(stderr, "solstice elevation: %.2f (expected ~62°)\n", pos.elevation_deg);
            ++failed;
        }
        // Declination near summer solstice should be ~23.4°
        if (std::fabs(pos.declination_deg - 23.4) > 1.0) {
            std::fprintf(stderr, "solstice declination: %.2f (expected ~23.4°)\n", pos.declination_deg);
            ++failed;
        }
    }

    // Test 2: Winter solstice 2024 noon UTC at Greenwich
    // 2024-12-21 12:00:00 UTC = 1734782400
    {
        aether::geo::SolarPosition pos{};
        aether::geo::solar_position(1734782400.0, 51.4769, -0.0005, &pos);
        // Elevation at winter solstice noon at 51.5°N should be ~15°
        if (std::fabs(pos.elevation_deg - 15.0) > 3.0) {
            std::fprintf(stderr, "winter solstice elevation: %.2f (expected ~15°)\n", pos.elevation_deg);
            ++failed;
        }
        // Declination near winter solstice should be ~-23.4°
        if (std::fabs(pos.declination_deg + 23.4) > 1.0) {
            std::fprintf(stderr, "winter declination: %.2f (expected ~-23.4°)\n", pos.declination_deg);
            ++failed;
        }
    }

    // Test 3: Equator at equinox noon
    // 2024-03-20 12:00:00 UTC = 1710936000
    {
        aether::geo::SolarPosition pos{};
        aether::geo::solar_position(1710936000.0, 0.0, 0.0, &pos);
        // At equinox, sun should be nearly overhead at equator noon
        if (pos.elevation_deg < 60.0) {
            std::fprintf(stderr, "equinox equator elevation: %.2f (expected >60°)\n", pos.elevation_deg);
            ++failed;
        }
    }

    // Test 4: Midnight → sun should be below horizon at mid-latitudes
    // 2024-06-20 00:00:00 UTC = 1718841600 at Greenwich
    {
        aether::geo::SolarPosition pos{};
        aether::geo::solar_position(1718841600.0, 51.4769, -0.0005, &pos);
        if (pos.elevation_deg > 5.0) {
            std::fprintf(stderr, "midnight elevation: %.2f (should be <5°)\n", pos.elevation_deg);
            ++failed;
        }
    }

    // Test 5: Day phase cascade
    {
        if (aether::geo::solar_day_phase(45.0) != aether::geo::DayPhase::kFullDay) {
            std::fprintf(stderr, "45° not FullDay\n"); ++failed;
        }
        if (aether::geo::solar_day_phase(5.0) != aether::geo::DayPhase::kGoldenHour) {
            std::fprintf(stderr, "5° not GoldenHour\n"); ++failed;
        }
        if (aether::geo::solar_day_phase(-3.0) != aether::geo::DayPhase::kCivilTwilight) {
            std::fprintf(stderr, "-3° not CivilTwilight\n"); ++failed;
        }
        if (aether::geo::solar_day_phase(-9.0) != aether::geo::DayPhase::kNauticalTwilight) {
            std::fprintf(stderr, "-9° not NauticalTwilight\n"); ++failed;
        }
        if (aether::geo::solar_day_phase(-15.0) != aether::geo::DayPhase::kAstronomicalTwilight) {
            std::fprintf(stderr, "-15° not AstronomicalTwilight\n"); ++failed;
        }
        if (aether::geo::solar_day_phase(-25.0) != aether::geo::DayPhase::kNight) {
            std::fprintf(stderr, "-25° not Night\n"); ++failed;
        }
    }

    // Test 6: Environment light
    {
        aether::geo::SolarPosition pos{};
        pos.elevation_deg = 45.0;
        pos.azimuth_deg = 180.0;
        aether::geo::SolarEnvironmentLight light{};
        auto s = aether::geo::solar_environment_light(pos, 51.5, -0.1, &light);
        if (s != aether::core::Status::kOk) {
            std::fprintf(stderr, "env light failed\n"); ++failed;
        }
        if (light.sun_intensity <= 0.0f) {
            std::fprintf(stderr, "env light: zero intensity at 45° elevation\n"); ++failed;
        }
        if (light.phase != aether::geo::DayPhase::kFullDay) {
            std::fprintf(stderr, "env light: wrong phase at 45°\n"); ++failed;
        }
        // SH coefficients should be non-zero
        bool all_zero = true;
        for (int i = 0; i < 9; ++i) {
            if (std::fabs(light.sh_coeffs[i]) > 1e-6f) all_zero = false;
        }
        if (all_zero) {
            std::fprintf(stderr, "env light: all SH coefficients zero\n"); ++failed;
        }
    }

    // Test 7: Night environment light
    {
        aether::geo::SolarPosition pos{};
        pos.elevation_deg = -30.0;
        pos.azimuth_deg = 0.0;
        aether::geo::SolarEnvironmentLight light{};
        aether::geo::solar_environment_light(pos, 0, 0, &light);
        if (light.sun_intensity > 0.01f) {
            std::fprintf(stderr, "night: sun_intensity=%.3f (should be ~0)\n", light.sun_intensity);
            ++failed;
        }
        if (light.phase != aether::geo::DayPhase::kNight) {
            std::fprintf(stderr, "night: wrong phase\n"); ++failed;
        }
    }

    // Test 8: Interpolation
    {
        aether::geo::SolarEnvironmentLight a{}, b{}, out{};
        a.sun_intensity = 0.0f;
        b.sun_intensity = 1.0f;
        a.phase = aether::geo::DayPhase::kNight;
        b.phase = aether::geo::DayPhase::kFullDay;

        aether::geo::solar_interpolate(a, b, 0.5f, &out);
        if (std::fabs(out.sun_intensity - 0.5f) > 0.01f) {
            std::fprintf(stderr, "interpolate: intensity=%.3f expected 0.5\n", out.sun_intensity);
            ++failed;
        }
    }

    // Test 9: Terminator
    {
        double lats[72], lons[72];
        auto s = aether::geo::solar_terminator(1718884800.0, lats, lons, 72);
        if (s != aether::core::Status::kOk) {
            std::fprintf(stderr, "terminator failed\n"); ++failed;
        }
        // All latitudes should be in [-90, 90]
        for (int i = 0; i < 72; ++i) {
            if (lats[i] < -90.0 || lats[i] > 90.0) {
                std::fprintf(stderr, "terminator lat[%d]=%.2f out of range\n", i, lats[i]);
                ++failed;
                break;
            }
        }
    }

    // Test 10: Null pointer
    {
        auto s = aether::geo::solar_position(0, 0, 0, nullptr);
        if (s != aether::core::Status::kInvalidArgument) {
            std::fprintf(stderr, "null ptr: expected kInvalidArgument\n"); ++failed;
        }
    }

    return failed;
}
