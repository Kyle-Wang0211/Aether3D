// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/geo/spoof_detector.h"
#include "aether/core/status.h"

#include <cmath>
#include <cstdio>

int main() {
    int failed = 0;

    // Test 1: Create / destroy
    {
        auto* det = aether::geo::spoof_detector_create();
        if (!det) { std::fprintf(stderr, "spoof_detector_create null\n"); ++failed; }
        else {
            if (aether::geo::spoof_detector_history_count(det) != 0) {
                std::fprintf(stderr, "new detector history != 0\n"); ++failed;
            }
            aether::geo::spoof_detector_destroy(det);
        }
    }

    // Test 2: Clean trajectory (walking in London)
    {
        auto* det = aether::geo::spoof_detector_create();
        aether::geo::SpoofResult result{};

        // Simulate 5 fixes ~ 1 second apart, ~1.5 m/s walking
        for (int i = 0; i < 5; ++i) {
            aether::geo::GeoFix fix{};
            fix.lat = 51.5074 + i * 0.000015;
            fix.lon = -0.1278 + i * 0.000015;
            fix.altitude_m = 30.0;
            fix.baro_altitude_m = 30.5f;
            fix.timestamp_s = 1700000000.0 + i;
            fix.speed_ms = 1.5f;
            fix.imu_displacement_m = 1.5f;
            fix.cnr_db_hz = 35.0f;
            fix.satellite_count = 12;

            auto s = aether::geo::spoof_detector_process(det, fix, &result);
            if (s != aether::core::Status::kOk) {
                std::fprintf(stderr, "clean fix[%d] failed\n", i); ++failed;
            }
        }

        // Clean trajectory should have high plausibility
        if (result.plausibility_score < 0.5f) {
            std::fprintf(stderr, "clean trajectory scored %.3f (should be > 0.5)\n",
                         result.plausibility_score);
            ++failed;
        }
        if (result.is_spoofed) {
            std::fprintf(stderr, "clean trajectory flagged as spoofed\n"); ++failed;
        }

        if (aether::geo::spoof_detector_history_count(det) != 5) {
            std::fprintf(stderr, "history count %u, expected 5\n",
                         aether::geo::spoof_detector_history_count(det));
            ++failed;
        }

        aether::geo::spoof_detector_destroy(det);
    }

    // Test 3: Teleport attack (jump from London to Tokyo in 1 second)
    {
        auto* det = aether::geo::spoof_detector_create();
        aether::geo::SpoofResult result{};

        // First fix: London
        aether::geo::GeoFix fix1{};
        fix1.lat = 51.5074; fix1.lon = -0.1278;
        fix1.altitude_m = 30.0; fix1.baro_altitude_m = 30.0f;
        fix1.timestamp_s = 1700000000.0;
        fix1.speed_ms = 0.0f; fix1.imu_displacement_m = 0.0f;
        fix1.cnr_db_hz = 35.0f; fix1.satellite_count = 12;
        aether::geo::spoof_detector_process(det, fix1, &result);

        // Second fix: London (establish baseline)
        aether::geo::GeoFix fix2{};
        fix2.lat = 51.5075; fix2.lon = -0.1277;
        fix2.altitude_m = 30.0; fix2.baro_altitude_m = 30.0f;
        fix2.timestamp_s = 1700000001.0;
        fix2.speed_ms = 1.0f; fix2.imu_displacement_m = 1.0f;
        fix2.cnr_db_hz = 35.0f; fix2.satellite_count = 12;
        aether::geo::spoof_detector_process(det, fix2, &result);

        // Third fix: TELEPORT to Tokyo
        aether::geo::GeoFix fix3{};
        fix3.lat = 35.6762; fix3.lon = 139.6503;
        fix3.altitude_m = 30.0; fix3.baro_altitude_m = 30.0f;
        fix3.timestamp_s = 1700000002.0;
        fix3.speed_ms = 0.0f; fix3.imu_displacement_m = 2.0f;
        fix3.cnr_db_hz = 35.0f; fix3.satellite_count = 12;
        aether::geo::spoof_detector_process(det, fix3, &result);

        // Should be detected as spoofed
        if (!result.is_spoofed) {
            std::fprintf(stderr, "teleport NOT detected, score=%.3f\n",
                         result.plausibility_score);
            ++failed;
        }

        aether::geo::spoof_detector_destroy(det);
    }

    // Test 4: IMU mismatch
    {
        auto* det = aether::geo::spoof_detector_create();
        aether::geo::SpoofResult result{};

        aether::geo::GeoFix fix1{};
        fix1.lat = 51.5074; fix1.lon = -0.1278;
        fix1.altitude_m = 30.0; fix1.baro_altitude_m = 30.0f;
        fix1.timestamp_s = 1700000000.0;
        fix1.speed_ms = 0.0f; fix1.imu_displacement_m = 0.0f;
        fix1.cnr_db_hz = 35.0f; fix1.satellite_count = 12;
        aether::geo::spoof_detector_process(det, fix1, &result);

        // GPS says 100m movement, IMU says 1m
        aether::geo::GeoFix fix2{};
        fix2.lat = 51.508; fix2.lon = -0.127;
        fix2.altitude_m = 30.0; fix2.baro_altitude_m = 30.0f;
        fix2.timestamp_s = 1700000010.0;
        fix2.speed_ms = 10.0f; fix2.imu_displacement_m = 1.0f;
        fix2.cnr_db_hz = 35.0f; fix2.satellite_count = 12;
        aether::geo::spoof_detector_process(det, fix2, &result);

        // IMU layer should show concern
        if (result.layers[2].mass_spoof < 0.3f) {
            std::fprintf(stderr, "IMU mismatch: mass_spoof=%.3f too low\n",
                         result.layers[2].mass_spoof);
            ++failed;
        }

        aether::geo::spoof_detector_destroy(det);
    }

    // Test 5: Reset
    {
        auto* det = aether::geo::spoof_detector_create();
        aether::geo::SpoofResult result{};
        aether::geo::GeoFix fix{};
        fix.lat = 0; fix.lon = 0; fix.timestamp_s = 1;
        fix.satellite_count = 10; fix.cnr_db_hz = 30;
        aether::geo::spoof_detector_process(det, fix, &result);
        aether::geo::spoof_detector_reset(det);
        if (aether::geo::spoof_detector_history_count(det) != 0) {
            std::fprintf(stderr, "reset: history not cleared\n"); ++failed;
        }
        aether::geo::spoof_detector_destroy(det);
    }

    // Test 6: Low satellite count + CNR jump → suspicious
    {
        auto* det = aether::geo::spoof_detector_create();
        aether::geo::SpoofResult result{};

        aether::geo::GeoFix fix1{};
        fix1.lat = 51.5; fix1.lon = -0.1;
        fix1.altitude_m = 30; fix1.baro_altitude_m = 30;
        fix1.timestamp_s = 1; fix1.cnr_db_hz = 35.0f;
        fix1.satellite_count = 10;
        aether::geo::spoof_detector_process(det, fix1, &result);

        aether::geo::GeoFix fix2{};
        fix2.lat = 51.5001; fix2.lon = -0.0999;
        fix2.altitude_m = 30; fix2.baro_altitude_m = 30;
        fix2.timestamp_s = 2; fix2.cnr_db_hz = 50.0f;  // Big CNR jump
        fix2.satellite_count = 2;  // Low satellites
        fix2.imu_displacement_m = 10.0f;
        aether::geo::spoof_detector_process(det, fix2, &result);

        if (result.layers[4].mass_spoof < 0.5f) {
            std::fprintf(stderr, "signal layer: mass_spoof=%.3f too low\n",
                         result.layers[4].mass_spoof);
            ++failed;
        }

        aether::geo::spoof_detector_destroy(det);
    }

    return failed;
}
