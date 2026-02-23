// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_TSDF_TSDF_CONSTANTS_H
#define AETHER_TSDF_TSDF_CONSTANTS_H

#include <cstdint>

namespace aether {
namespace tsdf {

// Section 1: Adaptive voxel resolution.
constexpr float VOXEL_SIZE_NEAR = 0.005f;
constexpr float VOXEL_SIZE_MID = 0.01f;
constexpr float VOXEL_SIZE_FAR = 0.02f;
constexpr float DEPTH_NEAR_THRESHOLD = 1.0f;
constexpr float DEPTH_FAR_THRESHOLD = 3.0f;

// Section 2: Truncation distance.
constexpr float TRUNCATION_MULTIPLIER = 3.0f;
constexpr float TRUNCATION_MINIMUM = 0.01f;

// Section 3: Fusion weights.
constexpr uint8_t WEIGHT_MAX = 64;
constexpr float CONFIDENCE_WEIGHT_LOW = 0.1f;
constexpr float CONFIDENCE_WEIGHT_MID = 0.5f;
constexpr float CONFIDENCE_WEIGHT_HIGH = 1.0f;
constexpr float DISTANCE_DECAY_ALPHA = 0.1f;
constexpr float VIEWING_ANGLE_WEIGHT_FLOOR = 0.1f;
constexpr uint8_t CARVING_DECAY_RATE = 2;

// Section 4: Depth filtering.
constexpr float DEPTH_MIN = 0.1f;
constexpr float DEPTH_MAX = 5.0f;
constexpr float MIN_VALID_PIXEL_RATIO = 0.3f;
constexpr bool SKIP_LOW_CONFIDENCE_PIXELS = true;

// Section 5: Performance budget.
constexpr int MAX_VOXELS_PER_FRAME = 500000;
constexpr int MAX_TRIANGLES_PER_CYCLE = 50000;
constexpr double INTEGRATION_TIMEOUT_MS = 10.0;
constexpr int COMPUTE_WORKGROUP_SIZE = 8;
constexpr int GPU_INFLIGHT_BUFFER_COUNT = 3;
// Backward-compatible aliases during migration.
constexpr int METAL_THREADGROUP_SIZE = COMPUTE_WORKGROUP_SIZE;
constexpr int INFLIGHT_BUFFER_COUNT = GPU_INFLIGHT_BUFFER_COUNT;

// Section 6: Memory management.
constexpr int MAX_TOTAL_VOXEL_BLOCKS = 100000;
constexpr int HASH_TABLE_INITIAL_SIZE = 65536;
constexpr float HASH_TABLE_MAX_LOAD_FACTOR = 0.7f;
constexpr int HASH_MAX_PROBE_LENGTH = 128;
constexpr float DIRTY_THRESHOLD_MULTIPLIER = 0.5f;
constexpr double STALE_BLOCK_EVICTION_AGE_S = 30.0;
constexpr double STALE_BLOCK_FORCE_EVICTION_AGE_S = 60.0;

// Section 7: Block geometry.
constexpr int BLOCK_SIZE = 8;

// Section 8: Camera pose safety.
constexpr float MAX_POSE_DELTA_PER_FRAME = 0.1f;
constexpr float MAX_ANGULAR_VELOCITY = 2.0f;
constexpr int POSE_REJECT_WARNING_COUNT = 30;
constexpr int POSE_REJECT_FAIL_COUNT = 180;
constexpr float LOOP_CLOSURE_DRIFT_THRESHOLD = 0.02f;

// Section 9: Keyframe selection.
constexpr int KEYFRAME_INTERVAL = 6;
constexpr float KEYFRAME_ANGULAR_TRIGGER_DEG = 15.0f;
constexpr float KEYFRAME_TRANSLATION_TRIGGER = 0.3f;
constexpr int MAX_KEYFRAMES_PER_SESSION = 30;

// Section 10: GPU safety.
constexpr double SEMAPHORE_WAIT_TIMEOUT_MS = 100.0;
constexpr int GPU_MEMORY_PROACTIVE_EVICT_BYTES = 500000000;
constexpr int GPU_MEMORY_AGGRESSIVE_EVICT_BYTES = 800000000;
constexpr float WORLD_ORIGIN_RECENTER_DISTANCE = 100.0f;

// Section 11: AIMD thermal management.
constexpr double THERMAL_DEGRADE_HYSTERESIS_S = 10.0;
constexpr double THERMAL_RECOVER_HYSTERESIS_S = 5.0;
constexpr int THERMAL_RECOVER_GOOD_FRAMES = 30;
constexpr float THERMAL_GOOD_FRAME_RATIO = 0.8f;
constexpr int THERMAL_MAX_INTEGRATION_SKIP = 12;

// Section 12: Mesh extraction quality.
constexpr float MIN_TRIANGLE_AREA = 1e-8f;
constexpr float MAX_TRIANGLE_ASPECT_RATIO = 100.0f;
constexpr int INTEGRATION_RECORD_CAPACITY = 300;

// Section 13: UX stability.
constexpr float SDF_DEAD_ZONE_BASE = 0.001f;
constexpr float SDF_DEAD_ZONE_WEIGHT_SCALE = 0.004f;
constexpr float VERTEX_QUANTIZATION_STEP = 0.0005f;
constexpr float MESH_EXTRACTION_TARGET_HZ = 10.0f;
constexpr double MESH_EXTRACTION_BUDGET_MS = 5.0;
constexpr float MC_INTERPOLATION_MIN = 0.1f;
constexpr float MC_INTERPOLATION_MAX = 0.9f;
constexpr float POSE_JITTER_GATE_TRANSLATION = 0.001f;
constexpr float POSE_JITTER_GATE_ROTATION = 0.002f;
constexpr uint32_t MIN_OBSERVATIONS_BEFORE_MESH = 3u;
constexpr int MESH_FADE_IN_FRAMES = 7;

// Section 14: Congestion control.
constexpr double MESH_BUDGET_TARGET_MS = 4.0;
constexpr double MESH_BUDGET_GOOD_MS = 3.0;
constexpr double MESH_BUDGET_OVERRUN_MS = 5.0;
constexpr int MIN_BLOCKS_PER_EXTRACTION = 50;
constexpr int MAX_BLOCKS_PER_EXTRACTION = 250;
constexpr int BLOCK_RAMP_PER_CYCLE = 15;
constexpr int CONSECUTIVE_GOOD_CYCLES_BEFORE_RAMP = 3;
constexpr int FORGIVENESS_WINDOW_CYCLES = 5;
constexpr float SLOW_START_RATIO = 0.25f;

// Section 15: Motion tiers.
constexpr float NORMAL_AVERAGING_BOUNDARY_DISTANCE = 0.001f;
constexpr float MOTION_DEFER_TRANSLATION_SPEED = 0.5f;
constexpr float MOTION_DEFER_ANGULAR_SPEED = 1.0f;
constexpr float IDLE_TRANSLATION_SPEED = 0.01f;
constexpr float IDLE_ANGULAR_SPEED = 0.05f;
constexpr float ANTICIPATORY_PREALLOCATION_DISTANCE = 0.5f;

// Numeric constant count from the current Track P set.
constexpr int TSDF_CONSTANTS_NUMERIC_COUNT = 77;

static_assert(VOXEL_SIZE_NEAR < VOXEL_SIZE_MID && VOXEL_SIZE_MID < VOXEL_SIZE_FAR, "voxel tier ordering");
static_assert(DEPTH_NEAR_THRESHOLD < DEPTH_FAR_THRESHOLD, "depth tier ordering");
static_assert(TRUNCATION_MULTIPLIER >= 2.0f, "truncation multiplier floor");
static_assert(HASH_TABLE_INITIAL_SIZE > 0 && (HASH_TABLE_INITIAL_SIZE & (HASH_TABLE_INITIAL_SIZE - 1)) == 0,
              "hash table size must be power of two");
static_assert(HASH_TABLE_MAX_LOAD_FACTOR == 0.7f, "cross-end parity: hash load factor");
static_assert(BLOCK_SIZE == 8, "Track P fixed block size");
static_assert(WEIGHT_MAX == 64, "voxel weight cap");
static_assert(THERMAL_MAX_INTEGRATION_SKIP == 12, "thermal cap parity");
static_assert(MC_INTERPOLATION_MIN < MC_INTERPOLATION_MAX, "interpolation range");
static_assert(TSDF_CONSTANTS_NUMERIC_COUNT == 77, "core constant-count parity");

}  // namespace tsdf
}  // namespace aether

#endif  // AETHER_TSDF_TSDF_CONSTANTS_H
