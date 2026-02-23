// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/geo/spoof_detector.h"
#include "aether/geo/geo_constants.h"
#include "aether/geo/haversine.h"

#include <cmath>
#include <cstring>
#include <vector>

namespace aether {
namespace geo {

// ---------------------------------------------------------------------------
// D-S mass fusion (local, lightweight version)
// ---------------------------------------------------------------------------
namespace {

struct DSMass {
    float spoof{0};
    float genuine{0};
    float unknown{1.0f};
};

DSMass dempster_combine(const DSMass& a, const DSMass& b) {
    float k = a.spoof * b.genuine + a.genuine * b.spoof;
    if (k >= 1.0f) {
        // Complete conflict → return equal split
        return {0.33f, 0.33f, 0.34f};
    }
    float norm = 1.0f / (1.0f - k);
    DSMass out{};
    out.spoof   = (a.spoof * b.spoof + a.spoof * b.unknown + a.unknown * b.spoof) * norm;
    out.genuine = (a.genuine * b.genuine + a.genuine * b.unknown + a.unknown * b.genuine) * norm;
    out.unknown = (a.unknown * b.unknown) * norm;
    return out;
}

}  // anonymous namespace

// ---------------------------------------------------------------------------
// FixedVec<GeoFix, 300> equivalent using bounded vector
// ---------------------------------------------------------------------------
static constexpr std::size_t kMaxHistory = 300;

struct SpoofDetector {
    GeoFix history[kMaxHistory]{};
    std::uint32_t history_count{0};
    std::uint32_t history_head{0};   // Ring buffer head

    void push(const GeoFix& fix) {
        std::uint32_t idx = (history_head + history_count) % kMaxHistory;
        if (history_count < kMaxHistory) {
            history[idx] = fix;
            history_count++;
        } else {
            // Overwrite oldest
            history[history_head] = fix;
            history_head = (history_head + 1) % kMaxHistory;
            history[((history_head + history_count - 1) % kMaxHistory)] = fix;
        }
    }

    const GeoFix* prev(std::uint32_t offset = 1) const {
        if (offset >= history_count) return nullptr;
        std::uint32_t idx = (history_head + history_count - 1 - offset) % kMaxHistory;
        return &history[idx];
    }

    const GeoFix* latest() const {
        if (history_count == 0) return nullptr;
        std::uint32_t idx = (history_head + history_count - 1) % kMaxHistory;
        return &history[idx];
    }
};

// ---------------------------------------------------------------------------
// 5 Detection Layers
// ---------------------------------------------------------------------------

// Layer 1: Speed plausibility
static LayerResult layer_speed(const GeoFix& fix, const GeoFix* prev) {
    LayerResult r{};
    if (!prev) { r.mass_unknown = 1.0f; return r; }

    double dt = fix.timestamp_s - prev->timestamp_s;
    if (dt <= 0.0) { r.mass_unknown = 1.0f; return r; }

    double dist = distance_haversine(prev->lat, prev->lon, fix.lat, fix.lon);
    double speed = dist / dt;

    if (speed > SPOOF_MAX_SPEED_MS) {
        r.mass_spoof = 0.9f;
        r.mass_genuine = 0.0f;
        r.mass_unknown = 0.1f;
    } else if (speed > SPOOF_MAX_SPEED_MS * 0.5) {
        r.mass_spoof = 0.3f;
        r.mass_genuine = 0.2f;
        r.mass_unknown = 0.5f;
    } else {
        r.mass_spoof = 0.05f;
        r.mass_genuine = 0.6f;
        r.mass_unknown = 0.35f;
    }
    return r;
}

// Layer 2: Acceleration plausibility
static LayerResult layer_acceleration(const GeoFix& fix, const GeoFix* prev, const GeoFix* prev2) {
    LayerResult r{};
    if (!prev || !prev2) { r.mass_unknown = 1.0f; return r; }

    double dt1 = prev->timestamp_s - prev2->timestamp_s;
    double dt2 = fix.timestamp_s - prev->timestamp_s;
    if (dt1 <= 0.0 || dt2 <= 0.0) { r.mass_unknown = 1.0f; return r; }

    double d1 = distance_haversine(prev2->lat, prev2->lon, prev->lat, prev->lon);
    double d2 = distance_haversine(prev->lat, prev->lon, fix.lat, fix.lon);
    double v1 = d1 / dt1;
    double v2 = d2 / dt2;
    double accel = std::fabs(v2 - v1) / ((dt1 + dt2) * 0.5);

    if (accel > SPOOF_MAX_ACCELERATION_MS2) {
        r.mass_spoof = 0.85f;
        r.mass_genuine = 0.0f;
        r.mass_unknown = 0.15f;
    } else {
        r.mass_spoof = 0.05f;
        r.mass_genuine = 0.5f;
        r.mass_unknown = 0.45f;
    }
    return r;
}

// Layer 3: IMU consistency
static LayerResult layer_imu(const GeoFix& fix, const GeoFix* prev) {
    LayerResult r{};
    if (!prev) { r.mass_unknown = 1.0f; return r; }

    double gps_dist = distance_haversine(prev->lat, prev->lon, fix.lat, fix.lon);
    double divergence = std::fabs(gps_dist - static_cast<double>(fix.imu_displacement_m));

    if (divergence > SPOOF_IMU_GPS_TOLERANCE_M) {
        r.mass_spoof = 0.7f;
        r.mass_genuine = 0.05f;
        r.mass_unknown = 0.25f;
    } else {
        r.mass_spoof = 0.05f;
        r.mass_genuine = 0.55f;
        r.mass_unknown = 0.4f;
    }
    return r;
}

// Layer 4: Altitude consistency
static LayerResult layer_altitude(const GeoFix& fix) {
    LayerResult r{};
    double divergence = std::fabs(fix.altitude_m - static_cast<double>(fix.baro_altitude_m));

    if (divergence > SPOOF_ALTITUDE_SIGMA_M * 3.0) {
        r.mass_spoof = 0.6f;
        r.mass_genuine = 0.05f;
        r.mass_unknown = 0.35f;
    } else if (divergence > SPOOF_ALTITUDE_SIGMA_M) {
        r.mass_spoof = 0.2f;
        r.mass_genuine = 0.3f;
        r.mass_unknown = 0.5f;
    } else {
        r.mass_spoof = 0.05f;
        r.mass_genuine = 0.6f;
        r.mass_unknown = 0.35f;
    }
    return r;
}

// Layer 5: Signal quality (C/N₀ + satellite count)
static LayerResult layer_signal(const GeoFix& fix, const GeoFix* prev) {
    LayerResult r{};

    bool low_sats = fix.satellite_count < static_cast<std::uint32_t>(SPOOF_MIN_SATELLITE_COUNT);
    bool cnr_jump = prev &&
        std::fabs(fix.cnr_db_hz - prev->cnr_db_hz) > static_cast<float>(SPOOF_CNR_ANOMALY_THRESHOLD);

    if (low_sats && cnr_jump) {
        r.mass_spoof = 0.8f;
        r.mass_genuine = 0.0f;
        r.mass_unknown = 0.2f;
    } else if (low_sats || cnr_jump) {
        r.mass_spoof = 0.4f;
        r.mass_genuine = 0.15f;
        r.mass_unknown = 0.45f;
    } else {
        r.mass_spoof = 0.05f;
        r.mass_genuine = 0.55f;
        r.mass_unknown = 0.4f;
    }
    return r;
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------
SpoofDetector* spoof_detector_create() {
    return new SpoofDetector();
}

void spoof_detector_destroy(SpoofDetector* detector) {
    delete detector;
}

core::Status spoof_detector_process(SpoofDetector* detector,
                                    const GeoFix& fix,
                                    SpoofResult* out_result) {
    if (!detector || !out_result) return core::Status::kInvalidArgument;

    const GeoFix* prev1 = detector->latest();
    const GeoFix* prev2 = detector->prev(1);

    // Run 5 layers
    out_result->layers[0] = layer_speed(fix, prev1);
    out_result->layers[1] = layer_acceleration(fix, prev1, prev2);
    out_result->layers[2] = layer_imu(fix, prev1);
    out_result->layers[3] = layer_altitude(fix);
    out_result->layers[4] = layer_signal(fix, prev1);

    // Fuse via Dempster's rule
    DSMass fused{};
    fused.spoof = out_result->layers[0].mass_spoof;
    fused.genuine = out_result->layers[0].mass_genuine;
    fused.unknown = out_result->layers[0].mass_unknown;

    for (int i = 1; i < 5; ++i) {
        DSMass layer_mass{};
        layer_mass.spoof = out_result->layers[i].mass_spoof;
        layer_mass.genuine = out_result->layers[i].mass_genuine;
        layer_mass.unknown = out_result->layers[i].mass_unknown;
        fused = dempster_combine(fused, layer_mass);
    }

    out_result->fused_mass_spoof = fused.spoof;
    out_result->fused_mass_genuine = fused.genuine;

    // Plausibility score = 1 - Bel(spoof)
    out_result->plausibility_score = 1.0f - fused.spoof;
    out_result->is_spoofed = (out_result->plausibility_score < 0.5f);

    // Store fix in history
    detector->push(fix);

    return core::Status::kOk;
}

void spoof_detector_reset(SpoofDetector* detector) {
    if (detector) {
        detector->history_count = 0;
        detector->history_head = 0;
    }
}

std::uint32_t spoof_detector_history_count(const SpoofDetector* detector) {
    return detector ? detector->history_count : 0;
}

}  // namespace geo
}  // namespace aether
