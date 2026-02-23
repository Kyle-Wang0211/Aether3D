// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_TSDF_THERMAL_ENGINE_H
#define AETHER_TSDF_THERMAL_ENGINE_H

#ifdef __cplusplus

#include "aether/core/status.h"

#include <cstdint>

namespace aether {
namespace tsdf {

enum class AetherThermalLevel : std::int32_t {
    kFrost = 0,
    kCool = 1,
    kNormal = 2,
    kWarm = 3,
    kHot = 4,
    kVeryHot = 5,
    kThrottle = 6,
    kCritical = 7,
    kEmergency = 8,
    kDead = 9,
};

struct AetherThermalState {
    AetherThermalLevel level{AetherThermalLevel::kNormal};
    float headroom{1.0f};
    float time_to_next_s{0.0f};
    float slope{0.0f};
    float slope_2nd{0.0f};
    float confidence{1.0f};
};

struct ThermalObservation {
    std::int32_t os_level{2};          // 0..9
    float os_headroom{1.0f};           // 0..1
    float battery_temp_c{32.0f};       // Celsius
    float soc_temp_c{35.0f};           // Celsius
    float skin_temp_c{33.0f};          // Celsius
    float gpu_busy_ratio{0.0f};        // 0..1
    float cpu_probe_ms{0.0f};          // Optional external probe
    double timestamp_s{0.0};           // Monotonic seconds
};

class AetherThermalEngine {
public:
    AetherThermalEngine() = default;

    core::Status update(const ThermalObservation& obs, AetherThermalState* out_state);
    const AetherThermalState& state() const { return state_; }

    static float run_cpu_probe();

private:
    AetherThermalState state_{};
    bool has_history_{false};
    double last_timestamp_s_{0.0};
    float last_headroom_{1.0f};
    float last_slope_{0.0f};
    float probe_ewma_ms_{0.0f};

    float fuse_headroom(const ThermalObservation& obs) const;
    static float normalize_temperature(float celsius);
    static AetherThermalLevel map_level(float fused_headroom, std::int32_t os_level);
};

}  // namespace tsdf
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_TSDF_THERMAL_ENGINE_H
