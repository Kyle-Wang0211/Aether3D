// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

import Foundation
import CAetherNativeBridge

struct NativeVolumeSignals: Sendable {
var thermalLevel: Int
var thermalHeadroom: Float
var memoryWaterLevel: Int
var trackingState: Int
var angularVelocity: Float
var frameActualDurationMs: Float
var validPixelCount: Int
var totalPixelCount: Int
var timestampS: Double
}

struct NativeVolumeDecision: Sendable {
var shouldSkipFrame: Bool
var integrationSkipRate: Int
var shouldEvict: Bool
var blocksToEvict: Int
var isKeyframe: Bool
var blocksToPreallocate: Int
var qualityWeight: Float
}

final class NativeVolumeControllerBridge {
private var state = aether_volume_controller_state_t(
frame_counter: 0,
integration_skip_rate: 1,
consecutive_good_frames: 0,
consecutive_bad_frames: 0,
consecutive_good_time_s: 0,
consecutive_bad_time_s: 0,
system_thermal_ceiling: 1,
memory_skip_floor: 1,
last_update_s: 0
)

func decide(_ signals: NativeVolumeSignals) -> NativeVolumeDecision? {
var cSignals = aether_volume_controller_signals_t(
thermal_level: Int32(signals.thermalLevel),
thermal_headroom: signals.thermalHeadroom,
memory_water_level: Int32(signals.memoryWaterLevel),
thermal: aether_thermal_state_t(
level: Int32(signals.thermalLevel),
headroom: signals.thermalHeadroom,
time_to_next_s: 0,
slope: 0,
slope_2nd: 0,
confidence: 1
),
memory_pressure: Int32(signals.memoryWaterLevel),
tracking_state: Int32(signals.trackingState),
camera_pose: (
1, 0, 0, 0,
0, 1, 0, 0,
0, 0, 1, 0,
0, 0, 0, 1
),
angular_velocity: signals.angularVelocity,
frame_actual_duration_ms: signals.frameActualDurationMs,
valid_pixel_count: Int32(signals.validPixelCount),
total_pixel_count: Int32(signals.totalPixelCount),
timestamp_s: signals.timestampS
)
var out = aether_volume_controller_decision_t(
should_skip_frame: 0,
integration_skip_rate: 1,
should_evict: 0,
blocks_to_evict: 0,
is_keyframe: 0,
blocks_to_preallocate: 0,
quality_weight: 1
)

let rc = aether_volume_controller_decide(&cSignals, &state, &out)
guard rc == 0 else {
return nil
}
return NativeVolumeDecision(
shouldSkipFrame: out.should_skip_frame != 0,
integrationSkipRate: Int(out.integration_skip_rate),
shouldEvict: out.should_evict != 0,
blocksToEvict: Int(out.blocks_to_evict),
isKeyframe: out.is_keyframe != 0,
blocksToPreallocate: Int(out.blocks_to_preallocate),
qualityWeight: out.quality_weight
)
}

func reset() {
state = aether_volume_controller_state_t(
frame_counter: 0,
integration_skip_rate: 1,
consecutive_good_frames: 0,
consecutive_bad_frames: 0,
consecutive_good_time_s: 0,
consecutive_bad_time_s: 0,
system_thermal_ceiling: 1,
memory_skip_floor: 1,
last_update_s: 0
)
}
}
