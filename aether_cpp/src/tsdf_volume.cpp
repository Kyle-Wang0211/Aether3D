// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/tsdf/adaptive_resolution.h"
#include "aether/tsdf/block_index.h"
#include "aether/tsdf/spatial_hash_table.h"
#include "aether/tsdf/tsdf_constants.h"
#include "aether/tsdf/tsdf_types.h"
#include "aether/tsdf/tsdf_volume.h"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>

namespace aether {
namespace tsdf {

namespace {

double now_seconds() {
    using clock = std::chrono::steady_clock;
    return std::chrono::duration<double>(clock::now().time_since_epoch()).count();
}

inline void unproject(
    float u,
    float v,
    float d,
    float fx,
    float fy,
    float cx,
    float cy,
    float& x_cam,
    float& y_cam,
    float& z_cam) {
    x_cam = (u - cx) * d / fx;
    y_cam = -(v - cy) * d / fy;  // ARKit convention: camera Y is UP, image Y is DOWN → negate
    z_cam = -d;  // ARKit convention: camera looks along -Z, so depth is at -Z
}

inline void transform_point(
    const float* m,
    float x,
    float y,
    float z,
    float& x_out,
    float& y_out,
    float& z_out) {
    x_out = m[0] * x + m[4] * y + m[8] * z + m[12];
    y_out = m[1] * x + m[5] * y + m[9] * z + m[13];
    z_out = m[2] * x + m[6] * y + m[10] * z + m[14];
}

inline float translation_delta(const float* a, const float* b) {
    const float dx = a[12] - b[12];
    const float dy = a[13] - b[13];
    const float dz = a[14] - b[14];
    return std::sqrt(dx * dx + dy * dy + dz * dz);
}

inline float rotation_delta(const float* a, const float* b) {
    float ar[3][3];
    float br[3][3];
    for (int r = 0; r < 3; ++r) {
        for (int c = 0; c < 3; ++c) {
            ar[r][c] = a[c * 4 + r];
            br[r][c] = b[c * 4 + r];
        }
    }

    float rel[3][3] = {};
    for (int r = 0; r < 3; ++r) {
        for (int c = 0; c < 3; ++c) {
            rel[r][c] = ar[0][r] * br[0][c] + ar[1][r] * br[1][c] + ar[2][r] * br[2][c];
        }
    }
    const float trace = rel[0][0] + rel[1][1] + rel[2][2];
    const float c = std::clamp((trace - 1.0f) * 0.5f, -1.0f, 1.0f);
    return std::acos(c);
}

inline BlockIndex world_to_block(float wx, float wy, float wz, float voxel_size) {
    const float inv = 1.0f / (voxel_size * static_cast<float>(BLOCK_SIZE));
    return BlockIndex(
        static_cast<int32_t>(std::floor(wx * inv)),
        static_cast<int32_t>(std::floor(wy * inv)),
        static_cast<int32_t>(std::floor(wz * inv)));
}

inline int clampi(int value, int low, int high) {
    return std::max(low, std::min(high, value));
}

inline int voxel_linear_index(int x, int y, int z) {
    return x + y * BLOCK_SIZE + z * BLOCK_SIZE * BLOCK_SIZE;
}

inline void world_to_camera(
    const float* camera_to_world,
    float wx,
    float wy,
    float wz,
    float& x_cam,
    float& y_cam,
    float& z_cam) {
    const float dx = wx - camera_to_world[12];
    const float dy = wy - camera_to_world[13];
    const float dz = wz - camera_to_world[14];
    x_cam = camera_to_world[0] * dx + camera_to_world[1] * dy + camera_to_world[2] * dz;
    // Negate Y: ARKit col1 = UP direction, but projection formula expects Y-down (CV convention).
    // Consistent with unproject() where y_cam = -(v-cy)*d/fy.
    y_cam = -(camera_to_world[4] * dx + camera_to_world[5] * dy + camera_to_world[6] * dz);
    // Negate Z: ARKit col2 = back direction; negate to get positive depth for in-front points.
    z_cam = -(camera_to_world[8] * dx + camera_to_world[9] * dy + camera_to_world[10] * dz);
}

TSDFVolume& default_volume() {
    static TSDFVolume volume;
    return volume;
}

}  // namespace

TSDFVolume::TSDFVolume() {
    hash_table_.init();
    current_max_blocks_per_extraction_ = MAX_BLOCKS_PER_EXTRACTION;
}

void TSDFVolume::reset() {
    hash_table_.reset();
    hash_table_.init();
    blocks_.clear();
    free_block_slots_.clear();
    frame_count_ = 0;
    has_last_pose_ = false;
    std::memset(last_pose_, 0, sizeof(last_pose_));
    last_timestamp_ = 0.0;
    system_thermal_ceiling_ = 1;
    current_integration_skip_ = 1;
    consecutive_good_frames_ = 0;
    consecutive_rejections_ = 0;
    last_thermal_change_time_s_ = 0.0;
    current_max_blocks_per_extraction_ = MAX_BLOCKS_PER_EXTRACTION;
    consecutive_good_meshing_cycles_ = 0;
    forgiveness_window_remaining_ = 0;
    consecutive_teleport_count_ = 0;
    last_angular_velocity_ = 0.0f;
    recent_pose_count_ = 0;
    last_idle_check_time_s_ = 0.0;
    memory_water_level_ = MemoryWaterLevel::kGreen;
    memory_pressure_ratio_ = 0.0f;
    last_memory_pressure_change_time_s_ = 0.0;
    last_evicted_blocks_ = 0;
}

void TSDFVolume::runtime_state(TSDFRuntimeState* out_state) const {
    if (out_state == nullptr) {
        return;
    }
    TSDFRuntimeState state{};
    state.frame_count = frame_count_;
    state.has_last_pose = has_last_pose_;
    std::memcpy(state.last_pose, last_pose_, sizeof(last_pose_));
    state.last_timestamp = last_timestamp_;
    state.system_thermal_ceiling = system_thermal_ceiling_;
    state.current_integration_skip = current_integration_skip_;
    state.consecutive_good_frames = consecutive_good_frames_;
    state.consecutive_rejections = consecutive_rejections_;
    state.last_thermal_change_time_s = last_thermal_change_time_s_;
    state.hash_table_size = hash_table_.size();
    state.hash_table_capacity = hash_table_.capacity();
    state.current_max_blocks_per_extraction = current_max_blocks_per_extraction_;
    state.consecutive_good_meshing_cycles = consecutive_good_meshing_cycles_;
    state.forgiveness_window_remaining = forgiveness_window_remaining_;
    state.consecutive_teleport_count = consecutive_teleport_count_;
    state.last_angular_velocity = last_angular_velocity_;
    state.recent_pose_count = recent_pose_count_;
    state.last_idle_check_time_s = last_idle_check_time_s_;
    state.memory_water_level = static_cast<int>(memory_water_level_);
    state.memory_pressure_ratio = memory_pressure_ratio_;
    state.last_memory_pressure_change_time_s = last_memory_pressure_change_time_s_;
    state.free_block_slot_count = static_cast<int>(free_block_slots_.size());
    state.last_evicted_blocks = last_evicted_blocks_;
    *out_state = state;
}

void TSDFVolume::restore_runtime_state(const TSDFRuntimeState& state) {
    frame_count_ = state.frame_count;
    has_last_pose_ = state.has_last_pose;
    std::memcpy(last_pose_, state.last_pose, sizeof(last_pose_));
    last_timestamp_ = state.last_timestamp;
    system_thermal_ceiling_ = std::max(1, std::min(state.system_thermal_ceiling, THERMAL_MAX_INTEGRATION_SKIP));
    current_integration_skip_ = std::max(1, std::min(state.current_integration_skip, THERMAL_MAX_INTEGRATION_SKIP));
    consecutive_good_frames_ = std::max(0, state.consecutive_good_frames);
    consecutive_rejections_ = std::max(0, state.consecutive_rejections);
    last_thermal_change_time_s_ = std::max(0.0, state.last_thermal_change_time_s);
    current_max_blocks_per_extraction_ = std::clamp(
        state.current_max_blocks_per_extraction,
        MIN_BLOCKS_PER_EXTRACTION,
        MAX_BLOCKS_PER_EXTRACTION);
    consecutive_good_meshing_cycles_ = std::max(0, state.consecutive_good_meshing_cycles);
    forgiveness_window_remaining_ = std::max(0, state.forgiveness_window_remaining);
    consecutive_teleport_count_ = std::max(0, state.consecutive_teleport_count);
    if (std::isfinite(state.last_angular_velocity)) {
        last_angular_velocity_ = std::max(0.0f, state.last_angular_velocity);
    } else {
        last_angular_velocity_ = 0.0f;
    }
    recent_pose_count_ = std::max(0, state.recent_pose_count);
    last_idle_check_time_s_ = std::max(0.0, state.last_idle_check_time_s);
    memory_water_level_ = static_cast<MemoryWaterLevel>(
        std::clamp(state.memory_water_level, 0, 4));
    if (std::isfinite(state.memory_pressure_ratio)) {
        memory_pressure_ratio_ = std::clamp(state.memory_pressure_ratio, 0.0f, 1.5f);
    } else {
        memory_pressure_ratio_ = 0.0f;
    }
    last_memory_pressure_change_time_s_ = std::max(0.0, state.last_memory_pressure_change_time_s);
    last_evicted_blocks_ = std::max(0, state.last_evicted_blocks);
    current_integration_skip_ = std::max(current_integration_skip_, memory_skip_target());
    free_block_slots_.clear();
}

bool TSDFVolume::query_block_runtime_info(
    const BlockIndex& block_index,
    TSDFBlockRuntimeInfo* out_info) const {
    if (out_info == nullptr) {
        return false;
    }
    const int slot = hash_table_.lookup(block_index);
    if (slot < 0 || static_cast<std::size_t>(slot) >= blocks_.size()) {
        return false;
    }
    const BlockRecord& rec = blocks_[static_cast<std::size_t>(slot)];
    if (!rec.active) {
        return false;
    }
    out_info->integration_generation = rec.block.integration_generation;
    out_info->mesh_generation = rec.block.mesh_generation;
    out_info->last_observed_timestamp = rec.block.last_observed_timestamp;
    return true;
}

bool TSDFVolume::gate_pose_teleport(const float* pose) const {
    if (!has_last_pose_) return false;
    const float delta_translation = translation_delta(last_pose_, pose);
    if (delta_translation > MAX_POSE_DELTA_PER_FRAME) return true;
    const float delta_rotation = rotation_delta(last_pose_, pose);
    if (delta_rotation > MAX_ANGULAR_VELOCITY) return true;
    return false;
}

bool TSDFVolume::gate_pose_jitter(const float* pose) const {
    if (!has_last_pose_) return false;
    const float delta_translation = translation_delta(last_pose_, pose);
    const float delta_rotation = rotation_delta(last_pose_, pose);
    return delta_translation < POSE_JITTER_GATE_TRANSLATION &&
           delta_rotation < POSE_JITTER_GATE_ROTATION;
}

bool TSDFVolume::gate_integration_skip() const {
    if (current_integration_skip_ <= 1) return false;
    return (frame_count_ % static_cast<uint64_t>(current_integration_skip_)) != 0;
}

int TSDFVolume::memory_skip_target() const {
    switch (memory_water_level_) {
        case MemoryWaterLevel::kGreen:
            return 1;
        case MemoryWaterLevel::kYellow:
            return 2;
        case MemoryWaterLevel::kOrange:
            return 3;
        case MemoryWaterLevel::kRed:
            return 4;
        case MemoryWaterLevel::kCritical:
            return THERMAL_MAX_INTEGRATION_SKIP;
    }
    return 1;
}

void TSDFVolume::update_aimd(double frame_time_ms) {
    const double good_frame_threshold = INTEGRATION_TIMEOUT_MS * static_cast<double>(THERMAL_GOOD_FRAME_RATIO);
    if (frame_time_ms < good_frame_threshold) {
        ++consecutive_good_frames_;
        if (consecutive_good_frames_ >= THERMAL_RECOVER_GOOD_FRAMES && current_integration_skip_ > 1) {
            current_integration_skip_ -= 1;
            if (current_integration_skip_ < 1) current_integration_skip_ = 1;
            consecutive_good_frames_ = 0;
        }
    } else {
        consecutive_good_frames_ = 0;
        current_integration_skip_ = std::min(
            current_integration_skip_ * 2,
            std::min(system_thermal_ceiling_, THERMAL_MAX_INTEGRATION_SKIP));
        if (current_integration_skip_ < 1) current_integration_skip_ = 1;
    }
    current_integration_skip_ = std::max(current_integration_skip_, memory_skip_target());
}

void TSDFVolume::apply_memory_pressure_eviction(double now_s) {
    last_evicted_blocks_ = 0;
    if (memory_water_level_ < MemoryWaterLevel::kOrange || blocks_.empty()) {
        return;
    }

    double stale_age_s = STALE_BLOCK_EVICTION_AGE_S;
    std::size_t max_evictions = 64u;
    if (memory_water_level_ == MemoryWaterLevel::kRed) {
        stale_age_s *= 0.5;
        max_evictions = 256u;
    } else if (memory_water_level_ == MemoryWaterLevel::kCritical) {
        stale_age_s *= 0.25;
        max_evictions = 512u;
    }

    for (std::size_t i = 0u; i < blocks_.size() && static_cast<std::size_t>(last_evicted_blocks_) < max_evictions; ++i) {
        BlockRecord& rec = blocks_[i];
        if (!rec.active) {
            continue;
        }
        const double age = now_s - rec.block.last_observed_timestamp;
        if (!std::isfinite(age) || age < stale_age_s) {
            continue;
        }
        if (!hash_table_.remove(rec.index)) {
            continue;
        }
        const float voxel_size = rec.block.voxel_size > 0.0f ? rec.block.voxel_size : VOXEL_SIZE_MID;
        rec.block.clear(voxel_size);
        rec.active = false;
        free_block_slots_.push_back(static_cast<int>(i));
        ++last_evicted_blocks_;
    }
}

void TSDFVolume::handle_thermal_state(int state) {
    int target_ceiling = 2;
    switch (state) {
        case 0: target_ceiling = 1; break;
        case 1: target_ceiling = 2; break;
        case 2: target_ceiling = 4; break;
        case 3: target_ceiling = 12; break;
        default: break;
    }
    if (target_ceiling > THERMAL_MAX_INTEGRATION_SKIP) target_ceiling = THERMAL_MAX_INTEGRATION_SKIP;
    if (target_ceiling < 1) target_ceiling = 1;

    const double now = now_seconds();
    const bool worsening = target_ceiling > system_thermal_ceiling_;
    const double hysteresis = worsening ? THERMAL_DEGRADE_HYSTERESIS_S : THERMAL_RECOVER_HYSTERESIS_S;
    if ((now - last_thermal_change_time_s_) < hysteresis) return;

    const int old_ceiling = system_thermal_ceiling_;
    system_thermal_ceiling_ = target_ceiling;
    if (target_ceiling > old_ceiling) {
        current_integration_skip_ = std::max(current_integration_skip_, target_ceiling);
    } else {
        current_integration_skip_ = std::min(current_integration_skip_, target_ceiling);
    }
    current_integration_skip_ = std::max(current_integration_skip_, memory_skip_target());
    if (current_integration_skip_ < 1) current_integration_skip_ = 1;
    last_thermal_change_time_s_ = now;
    consecutive_good_frames_ = 0;
}

void TSDFVolume::handle_memory_pressure(MemoryPressureLevel level) {
    float ratio_hint = 0.72f;
    if (level == MemoryPressureLevel::kCritical) {
        ratio_hint = 0.88f;
    } else if (level == MemoryPressureLevel::kTerminal) {
        ratio_hint = 0.97f;
    }
    handle_memory_pressure_ratio(ratio_hint);
}

void TSDFVolume::handle_memory_pressure_ratio(float pressure_ratio) {
    if (!std::isfinite(pressure_ratio)) {
        return;
    }
    const float clamped = std::max(0.0f, std::min(1.5f, pressure_ratio));
    MemoryWaterLevel target = MemoryWaterLevel::kGreen;
    if (clamped >= 0.92f) {
        target = MemoryWaterLevel::kCritical;
    } else if (clamped >= 0.85f) {
        target = MemoryWaterLevel::kRed;
    } else if (clamped >= 0.75f) {
        target = MemoryWaterLevel::kOrange;
    } else if (clamped >= 0.60f) {
        target = MemoryWaterLevel::kYellow;
    }

    const double now = now_seconds();
    const bool worsening = static_cast<int>(target) > static_cast<int>(memory_water_level_);
    const double hysteresis = worsening ? (THERMAL_DEGRADE_HYSTERESIS_S * 0.5) : THERMAL_RECOVER_HYSTERESIS_S;
    if (target != memory_water_level_ &&
        (now - last_memory_pressure_change_time_s_) < hysteresis) {
        memory_pressure_ratio_ = clamped;
        return;
    }

    memory_pressure_ratio_ = clamped;
    if (target != memory_water_level_) {
        memory_water_level_ = target;
        last_memory_pressure_change_time_s_ = now;
    }

    int extraction_cap = MAX_BLOCKS_PER_EXTRACTION;
    switch (memory_water_level_) {
        case MemoryWaterLevel::kGreen:
            extraction_cap = MAX_BLOCKS_PER_EXTRACTION;
            break;
        case MemoryWaterLevel::kYellow:
            extraction_cap = (MAX_BLOCKS_PER_EXTRACTION * 4) / 5;
            break;
        case MemoryWaterLevel::kOrange:
            extraction_cap = (MAX_BLOCKS_PER_EXTRACTION * 3) / 5;
            break;
        case MemoryWaterLevel::kRed:
            extraction_cap = MAX_BLOCKS_PER_EXTRACTION / 2;
            break;
        case MemoryWaterLevel::kCritical:
            extraction_cap = std::max(MIN_BLOCKS_PER_EXTRACTION, MAX_BLOCKS_PER_EXTRACTION / 3);
            break;
    }
    current_max_blocks_per_extraction_ = std::clamp(
        extraction_cap,
        MIN_BLOCKS_PER_EXTRACTION,
        MAX_BLOCKS_PER_EXTRACTION);
    current_integration_skip_ = std::max(current_integration_skip_, memory_skip_target());
    current_integration_skip_ = std::min(current_integration_skip_, THERMAL_MAX_INTEGRATION_SKIP);
}

void TSDFVolume::apply_frame_feedback(double gpu_time_ms) {
    if (!std::isfinite(gpu_time_ms) || gpu_time_ms < 0.0) {
        return;
    }
    update_aimd(gpu_time_ms);
}

int TSDFVolume::integrate(const IntegrationInput& input, IntegrationResult& result) {
    result = IntegrationResult{};

    if (!input.depth_data || !input.view_matrix) return -1;
    if (input.depth_width <= 0 || input.depth_height <= 0) return -2;
    if (input.fx <= 0.0f || input.fy <= 0.0f) return -3;
    if (input.voxel_size <= 0.0f || input.voxel_size > 1.0f) return -4;

    const int w = input.depth_width;
    const int h = input.depth_height;
    const size_t total_pixels = static_cast<size_t>(w) * static_cast<size_t>(h);
    if (total_pixels > static_cast<size_t>(MAX_VOXELS_PER_FRAME)) return -5;

    // Gate 1: tracking state.
    if (input.tracking_state != 2) {
        result.skipped = true;
        result.skip_reason = IntegrationSkipReason::kTrackingLost;
        ++consecutive_rejections_;
        ++frame_count_;
        return -7;
    }

    const bool gate_pose_checks = has_last_pose_ && input.timestamp > 0.0 && input.timestamp > last_timestamp_;
    if (gate_pose_checks) {
        const double delta_t = std::max(1e-6, input.timestamp - last_timestamp_);
        const float delta_r = rotation_delta(last_pose_, input.view_matrix);
        last_angular_velocity_ = delta_r / static_cast<float>(delta_t);
    } else {
        last_angular_velocity_ = 0.0f;
    }

    if (gate_pose_checks && gate_pose_teleport(input.view_matrix)) {
        result.skipped = true;
        result.skip_reason = IntegrationSkipReason::kPoseTeleport;
        ++consecutive_teleport_count_;
        ++consecutive_rejections_;
        ++frame_count_;
        return -8;
    }
    consecutive_teleport_count_ = 0;

    if (gate_pose_checks && gate_pose_jitter(input.view_matrix)) {
        result.skipped = true;
        result.skip_reason = IntegrationSkipReason::kPoseJitter;
        ++consecutive_rejections_;
        ++frame_count_;
        return -9;
    }

    if (gate_integration_skip()) {
        result.skipped = true;
        const bool memory_throttled = memory_water_level_ >= MemoryWaterLevel::kOrange;
        result.skip_reason = memory_throttled
            ? IntegrationSkipReason::kMemoryPressure
            : IntegrationSkipReason::kThermalThrottle;
        ++consecutive_rejections_;
        ++frame_count_;
        return memory_throttled ? -13 : -10;
    }

    apply_memory_pressure_eviction(now_seconds());

    // ── Pixel stride: controls quality vs CPU tradeoff ──
    // Stride 1 → process ALL pixels → fastest geo_q convergence → fastest S6+.
    // User priority: maximum quality speed, CPU usage is acceptable.
    constexpr int PIXEL_STRIDE = 1;

    // ── Valid pixel ratio check (sampled, not exhaustive) ──
    // Sample every 4th row to estimate valid ratio without full scan.
    int valid_sample = 0, total_sample = 0;
    for (int v = 0; v < h; v += 4) {
        for (int u = 0; u < w; u += 4) {
            const float d = input.depth_data[static_cast<size_t>(v) * static_cast<size_t>(w) + static_cast<size_t>(u)];
            ++total_sample;
            if (!std::isfinite(d) || d < DEPTH_MIN || d > DEPTH_MAX) continue;
            if (SKIP_LOW_CONFIDENCE_PIXELS && input.confidence_data &&
                input.confidence_data[static_cast<size_t>(v) * static_cast<size_t>(w) + static_cast<size_t>(u)] == 0) {
                continue;
            }
            ++valid_sample;
        }
    }

    const float valid_ratio = total_sample > 0
        ? static_cast<float>(valid_sample) / static_cast<float>(total_sample)
        : 0.0f;
    if (valid_ratio < MIN_VALID_PIXEL_RATIO) {
        result.skipped = true;
        result.skip_reason = IntegrationSkipReason::kLowValidPixels;
        ++consecutive_rejections_;
        ++frame_count_;
        return -11;
    }
    const int valid_pixels = static_cast<int>(valid_ratio * static_cast<float>(total_pixels));

    const auto start = std::chrono::steady_clock::now();

    int local_table_size = 256;
    while (local_table_size < valid_pixels * 2 && local_table_size < HASH_TABLE_INITIAL_SIZE) {
        local_table_size <<= 1;
    }
    SpatialHashTable frame_blocks;
    frame_blocks.init(local_table_size, valid_pixels > 0 ? valid_pixels : 1);

    const float* depth = input.depth_data;
    const float* view = input.view_matrix;
    int voxel_count = 0;
    int blocks_allocated = 0;
    const std::uint32_t frame_generation = static_cast<std::uint32_t>(std::min<std::uint64_t>(
        frame_count_ + 1u,
        static_cast<std::uint64_t>(std::numeric_limits<std::uint32_t>::max())));
    const float cam_origin_x = view[12];
    const float cam_origin_y = view[13];
    const float cam_origin_z = view[14];
    // ARKit col2 = back direction; negate to get actual forward direction
    const float cam_forward_x = -view[8];
    const float cam_forward_y = -view[9];
    const float cam_forward_z = -view[10];
    const float cam_forward_len = std::sqrt(
        cam_forward_x * cam_forward_x +
        cam_forward_y * cam_forward_y +
        cam_forward_z * cam_forward_z);

    for (int v = 0; v < h; v += PIXEL_STRIDE) {
        for (int u = 0; u < w; u += PIXEL_STRIDE) {
            const size_t idx = static_cast<size_t>(v) * static_cast<size_t>(w) + static_cast<size_t>(u);
            const float d = depth[idx];
            if (!std::isfinite(d) || d < DEPTH_MIN || d > DEPTH_MAX) continue;
            if (SKIP_LOW_CONFIDENCE_PIXELS && input.confidence_data && input.confidence_data[idx] == 0) continue;

            float x_cam = 0.0f;
            float y_cam = 0.0f;
            float z_cam = 0.0f;
            unproject(static_cast<float>(u), static_cast<float>(v), d, input.fx, input.fy, input.cx, input.cy, x_cam, y_cam, z_cam);

            float wx = 0.0f;
            float wy = 0.0f;
            float wz = 0.0f;
            transform_point(view, x_cam, y_cam, z_cam, wx, wy, wz);

            const float selected_voxel_size = input.voxel_size > 0.0f
                ? input.voxel_size
                : continuous_voxel_size(
                    d,
                    0.5f,
                    false,
                    default_continuous_resolution_config());
            const BlockIndex bi = world_to_block(wx, wy, wz, selected_voxel_size);
            int block_slot = hash_table_.lookup(bi);
            if (block_slot < 0) {
                if (free_block_slots_.empty() &&
                    static_cast<int>(blocks_.size()) >= MAX_TOTAL_VOXEL_BLOCKS) {
                    continue;
                }
                const bool reuse_slot = !free_block_slots_.empty();
                const int requested_slot = reuse_slot
                    ? free_block_slots_.back()
                    : static_cast<int>(blocks_.size());
                const int inserted_slot = hash_table_.insert_or_get(bi, requested_slot);
                if (inserted_slot < 0) {
                    continue;
                }
                block_slot = inserted_slot;
                if (inserted_slot == requested_slot) {
                    if (reuse_slot) {
                        free_block_slots_.pop_back();
                        TSDFVolume::BlockRecord& rec = blocks_[static_cast<std::size_t>(requested_slot)];
                        rec.index = bi;
                        rec.block.clear(selected_voxel_size);
                        rec.active = true;
                        rec.peak_quality = 0.0f;  // Reset peak on reuse
                    } else {
                        TSDFVolume::BlockRecord rec{};
                        rec.index = bi;
                        rec.block.clear(selected_voxel_size);
                        rec.active = true;
                        rec.peak_quality = 0.0f;
                        blocks_.push_back(rec);
                    }
                    ++blocks_allocated;
                }
            }
            if (block_slot < 0 || static_cast<std::size_t>(block_slot) >= blocks_.size()) {
                continue;
            }
            (void)frame_blocks.insert(bi);
            TSDFVolume::BlockRecord& rec = blocks_[static_cast<std::size_t>(block_slot)];
            if (!rec.active) {
                continue;
            }
            rec.block.voxel_size = selected_voxel_size;
            rec.block.last_observed_timestamp = input.timestamp;
            if (rec.block.integration_generation < frame_generation) {
                rec.block.integration_generation = frame_generation;

                // ── Update angular diversity bitmask (once per block per frame) ──
                // Compute view direction from camera to block center, classify
                // into 24 theta (horizontal) + 12 phi (vertical) directional buckets.
                const float bw = selected_voxel_size * static_cast<float>(BLOCK_SIZE);
                const float bcx = static_cast<float>(rec.index.x) * bw + bw * 0.5f;
                const float bcy = static_cast<float>(rec.index.y) * bw + bw * 0.5f;
                const float bcz = static_cast<float>(rec.index.z) * bw + bw * 0.5f;
                const float vdx = bcx - cam_origin_x;
                const float vdy = bcy - cam_origin_y;
                const float vdz = bcz - cam_origin_z;
                const float vdlen = std::sqrt(vdx * vdx + vdy * vdy + vdz * vdz);
                if (vdlen > 1e-6f) {
                    // Theta bucket (horizontal): atan2(dz, dx) → 24 buckets (15° each)
                    float theta_angle = std::atan2(vdz, vdx);  // [-π, π]
                    if (theta_angle < 0.0f) theta_angle += 2.0f * 3.14159265f;
                    int theta_idx = static_cast<int>(theta_angle * 24.0f / (2.0f * 3.14159265f));
                    theta_idx = std::max(0, std::min(23, theta_idx));
                    rec.block.view_theta_bits |= (1u << theta_idx);

                    // Phi bucket (vertical): atan2(dy, horizontal_dist) → 12 buckets (15° each)
                    const float horiz = std::sqrt(vdx * vdx + vdz * vdz);
                    float phi_angle = std::atan2(vdy, horiz);  // [-π/2, π/2]
                    float phi_norm = (phi_angle + 1.5707963f) / 3.14159265f;  // [0, 1]
                    int phi_idx = static_cast<int>(phi_norm * 12.0f);
                    phi_idx = std::max(0, std::min(11, phi_idx));
                    rec.block.view_phi_bits |= static_cast<std::uint16_t>(1u << phi_idx);
                }
            }

            const float block_world = selected_voxel_size * static_cast<float>(BLOCK_SIZE);
            const float block_origin_x = static_cast<float>(rec.index.x) * block_world;
            const float block_origin_y = static_cast<float>(rec.index.y) * block_world;
            const float block_origin_z = static_cast<float>(rec.index.z) * block_world;
            const int vx = clampi(static_cast<int>(std::floor((wx - block_origin_x) / selected_voxel_size)), 0, BLOCK_SIZE - 1);
            const int vy = clampi(static_cast<int>(std::floor((wy - block_origin_y) / selected_voxel_size)), 0, BLOCK_SIZE - 1);
            const int vz = clampi(static_cast<int>(std::floor((wz - block_origin_z) / selected_voxel_size)), 0, BLOCK_SIZE - 1);
            const int voxel_idx = voxel_linear_index(vx, vy, vz);

            const float center_x = block_origin_x + (static_cast<float>(vx) + 0.5f) * selected_voxel_size;
            const float center_y = block_origin_y + (static_cast<float>(vy) + 0.5f) * selected_voxel_size;
            const float center_z = block_origin_z + (static_cast<float>(vz) + 0.5f) * selected_voxel_size;
            float cx = 0.0f;
            float cy = 0.0f;
            float cz = 0.0f;
            world_to_camera(view, center_x, center_y, center_z, cx, cy, cz);
            if (!std::isfinite(cz) || cz <= DEPTH_MIN || cz > DEPTH_MAX) {
                continue;
            }

            const float proj_u = input.fx * (cx / cz) + input.cx;
            const float proj_v = input.fy * (cy / cz) + input.cy;
            if (!std::isfinite(proj_u) || !std::isfinite(proj_v)) {
                continue;
            }
            const int su = clampi(static_cast<int>(std::lround(proj_u)), 0, w - 1);
            const int sv = clampi(static_cast<int>(std::lround(proj_v)), 0, h - 1);
            const size_t sample_idx = static_cast<size_t>(sv) * static_cast<size_t>(w) + static_cast<size_t>(su);
            const float sampled_depth = depth[sample_idx];
            if (!std::isfinite(sampled_depth) || sampled_depth < DEPTH_MIN || sampled_depth > DEPTH_MAX) {
                continue;
            }

            std::uint8_t confidence_level = 2u;
            if (input.confidence_data != nullptr) {
                confidence_level = input.confidence_data[sample_idx];
                if (confidence_level > 2u) {
                    confidence_level = 2u;
                }
                if (SKIP_LOW_CONFIDENCE_PIXELS && confidence_level == 0u) {
                    continue;
                }
            }

            const float trunc = truncation_distance(selected_voxel_size);
            const float sdf = sampled_depth - cz;
            if (sdf <= -trunc) {
                continue;
            }
            const float sdf_norm = std::max(-1.0f, std::min(1.0f, sdf / std::max(1e-6f, trunc)));

            float ray_cos = 1.0f;
            const float rx = wx - cam_origin_x;
            const float ry = wy - cam_origin_y;
            const float rz = wz - cam_origin_z;
            const float ray_len = std::sqrt(rx * rx + ry * ry + rz * rz);
            if (ray_len > 1e-6f && cam_forward_len > 1e-6f) {
                ray_cos = (rx * cam_forward_x + ry * cam_forward_y + rz * cam_forward_z) /
                    (ray_len * cam_forward_len);
            }

            const float obs_weight = std::max(
                0.05f,
                distance_weight(sampled_depth) *
                    confidence_weight(confidence_level) *
                    viewing_angle_weight(ray_cos));
            Voxel& voxel = rec.block.voxels[voxel_idx];
            const float old_weight = static_cast<float>(voxel.weight);
            const float old_sdf = (old_weight > 0.0f) ? voxel.sdf.to_float() : 1.0f;
            const float new_weight = std::min(static_cast<float>(WEIGHT_MAX), old_weight + obs_weight);
            const float denom = std::max(1e-6f, old_weight + obs_weight);
            const float fused = std::max(-1.0f, std::min(1.0f, (old_sdf * old_weight + sdf_norm * obs_weight) / denom));
            voxel.sdf = SDFStorage::from_float(fused);
            voxel.weight = static_cast<std::uint8_t>(std::lround(new_weight));
            voxel.confidence = std::max(voxel.confidence, confidence_level);
            ++voxel_count;
        }
    }

    const auto end = std::chrono::steady_clock::now();
    const double frame_time_ms = std::chrono::duration<double, std::milli>(end - start).count();

    result.voxels_integrated = voxel_count;
    result.blocks_updated = frame_blocks.size();
    result.stats.blocks_updated = frame_blocks.size();
    result.stats.blocks_allocated = blocks_allocated;
    result.stats.voxels_updated = voxel_count;
    result.stats.total_time_ms = frame_time_ms;
    result.stats.gpu_time_ms = frame_time_ms;

    if (frame_time_ms > INTEGRATION_TIMEOUT_MS) {
        result.skipped = true;
        result.skip_reason = IntegrationSkipReason::kFrameTimeout;
        ++consecutive_rejections_;
        ++frame_count_;
        return -12;
    }

    update_aimd(frame_time_ms);
    consecutive_rejections_ = 0;
    std::memcpy(last_pose_, input.view_matrix, sizeof(last_pose_));
    has_last_pose_ = true;
    last_timestamp_ = input.timestamp;
    recent_pose_count_ = std::min(recent_pose_count_ + 1, 10);
    last_idle_check_time_s_ = now_seconds();
    ++frame_count_;

    if (voxel_count <= 0 || result.blocks_updated <= 0) {
        return -6;
    }

    result.success = true;
    return 0;
}

void TSDFVolume::extract_surface_points(
    std::vector<SurfacePoint>& out,
    std::size_t max_points) const
{
    out.clear();
    out.reserve(std::min(max_points, std::size_t(100000)));

    for (std::size_t bi = 0; bi < blocks_.size(); ++bi) {
        if (out.size() >= max_points) break;
        const BlockRecord& rec = blocks_[bi];
        if (!rec.active) continue;

        const float vs = rec.block.voxel_size > 0.0f ? rec.block.voxel_size : VOXEL_SIZE_MID;
        const float block_world = vs * static_cast<float>(BLOCK_SIZE);
        const float origin_x = static_cast<float>(rec.index.x) * block_world;
        const float origin_y = static_cast<float>(rec.index.y) * block_world;
        const float origin_z = static_cast<float>(rec.index.z) * block_world;

        for (int vz = 0; vz < BLOCK_SIZE; ++vz) {
            for (int vy = 0; vy < BLOCK_SIZE; ++vy) {
                for (int vx = 0; vx < BLOCK_SIZE; ++vx) {
                    if (out.size() >= max_points) goto done;

                    const int idx = vx + vy * BLOCK_SIZE + vz * BLOCK_SIZE * BLOCK_SIZE;
                    const Voxel& v = rec.block.voxels[idx];
                    if (v.weight == 0) continue;

                    const float sdf = v.sdf.to_float();
                    if (sdf > 0.5f || sdf < -0.5f) continue;  // Not near surface

                    SurfacePoint sp;
                    sp.position[0] = origin_x + (static_cast<float>(vx) + 0.5f) * vs;
                    sp.position[1] = origin_y + (static_cast<float>(vy) + 0.5f) * vs;
                    sp.position[2] = origin_z + (static_cast<float>(vz) + 0.5f) * vs;

                    // SDF gradient normal (central differences, within-block only)
                    float nx = 0.0f, ny = 0.0f, nz = 0.0f;
                    if (vx > 0 && vx < BLOCK_SIZE - 1 &&
                        vy > 0 && vy < BLOCK_SIZE - 1 &&
                        vz > 0 && vz < BLOCK_SIZE - 1) {
                        const auto sdf_at = [&](int x, int y, int z) {
                            return rec.block.voxels[x + y * BLOCK_SIZE + z * BLOCK_SIZE * BLOCK_SIZE].sdf.to_float();
                        };
                        nx = sdf_at(vx + 1, vy, vz) - sdf_at(vx - 1, vy, vz);
                        ny = sdf_at(vx, vy + 1, vz) - sdf_at(vx, vy - 1, vz);
                        nz = sdf_at(vx, vy, vz + 1) - sdf_at(vx, vy, vz - 1);
                    } else {
                        ny = 1.0f;  // Default up for boundary voxels
                    }
                    float len = std::sqrt(nx * nx + ny * ny + nz * nz);
                    if (len > 1e-6f) {
                        sp.normal[0] = nx / len;
                        sp.normal[1] = ny / len;
                        sp.normal[2] = nz / len;
                    } else {
                        sp.normal[0] = 0.0f;
                        sp.normal[1] = 1.0f;
                        sp.normal[2] = 0.0f;
                    }

                    sp.weight = v.weight;
                    sp.confidence = v.confidence;
                    out.push_back(sp);
                }
            }
        }
    }
done:;
}

void TSDFVolume::get_block_quality_samples(
    std::vector<BlockQualitySample>& out,
    std::size_t max_blocks,
    std::size_t start_offset)
{
    out.clear();
    const std::size_t total = blocks_.size();
    if (total == 0) return;

    // Rotating-offset iteration: iterate min(max_blocks, total) slots starting at
    // start_offset (wrapping around). Callers increment start_offset by max_blocks
    // each call so successive rebuilds cover different slices of the block array,
    // achieving full spatial coverage without re-sampling the same blocks each time.
    const std::size_t iter_limit = (max_blocks < total) ? max_blocks : total;
    const std::size_t base = start_offset % total;
    out.reserve(iter_limit);

    for (std::size_t i = 0; i < iter_limit; ++i) {
        const std::size_t bi = (base + i) % total;
        BlockRecord& rec = blocks_[bi];  // non-const: update peak_quality
        if (!rec.active) continue;

        const float vs = rec.block.voxel_size > 0.0f ? rec.block.voxel_size : VOXEL_SIZE_MID;
        const float block_world = vs * static_cast<float>(BLOCK_SIZE);

        BlockQualitySample sample;
        sample.center[0] = static_cast<float>(rec.index.x) * block_world + block_world * 0.5f;
        sample.center[1] = static_cast<float>(rec.index.y) * block_world + block_world * 0.5f;
        sample.center[2] = static_cast<float>(rec.index.z) * block_world + block_world * 0.5f;

        float max_weight = 0.0f;  // Use max instead of avg to prevent regression
        std::uint32_t occupied = 0;
        // Surface position accumulator: face-isolated grouping.
        // Problem: when a block spans a corner (e.g., top face ∩ side face),
        // naive averaging of ALL zero-crossings places surface_center in the
        // void between the two faces (5-10cm offset). Fix: group crossings by
        // their SDF gradient direction into 6 buckets (±X, ±Y, ±Z), then use
        // the largest bucket's centroid as surface_center.
        struct FaceBucket {
            double sx = 0, sy = 0, sz = 0;
            std::uint32_t count = 0;
        };
        FaceBucket face_buckets[6]; // 0=+X, 1=-X, 2=+Y, 3=-Y, 4=+Z, 5=-Z
        std::uint32_t surf_count = 0;
        // Per-crossing normal accumulator for normal_consistency metric.
        // Accumulates unit normals at each zero-crossing. The length of the
        // resulting sum, divided by count, measures how aligned the crossings are.
        // Real surfaces: all normals aligned → consistency ~1.0.
        // Phantom blocks (depth conflicts): chaotic normals → consistency ~0.3-0.5.
        float cross_nx_sum = 0.0f, cross_ny_sum = 0.0f, cross_nz_sum = 0.0f;
        std::uint32_t cross_normal_count = 0;
        // Block world-space origin (corner, not center)
        const float bx0 = static_cast<float>(rec.index.x) * block_world;
        const float by0 = static_cast<float>(rec.index.y) * block_world;
        const float bz0 = static_cast<float>(rec.index.z) * block_world;
        // Accumulate SDF gradient (finite differences) for surface normal.
        // CRITICAL: Only use voxels where ALL 6 neighbors have valid observations.
        // Edge voxels (at block boundary) use sdf_at() = 0.0 fallback, which
        // creates FALSE gradients that tilt normals on flat surfaces.
        // Example: flat floor → SDF gradient should be pure Y. But at ix=0,
        //   gx = sdf(1,y,z) - sdf(-1,y,z) = sdf(1,y,z) - 0.0 ≠ 0
        // This false X-gradient tilts the surface normal away from [0,1,0].
        float nx = 0.0f, ny = 0.0f, nz = 0.0f;
        std::uint32_t normal_contrib_count = 0;
        auto sdf_at = [&](int x, int y, int z) -> float {
            if (x < 0 || x >= BLOCK_SIZE || y < 0 || y >= BLOCK_SIZE ||
                z < 0 || z >= BLOCK_SIZE) return 0.0f;
            return rec.block.voxels[z * BLOCK_SIZE * BLOCK_SIZE + y * BLOCK_SIZE + x].sdf.to_float();
        };
        auto weight_at = [&](int x, int y, int z) -> std::uint8_t {
            if (x < 0 || x >= BLOCK_SIZE || y < 0 || y >= BLOCK_SIZE ||
                z < 0 || z >= BLOCK_SIZE) return 0;
            return rec.block.voxels[z * BLOCK_SIZE * BLOCK_SIZE + y * BLOCK_SIZE + x].weight;
        };
        for (int i = 0; i < VoxelBlock::kVoxelCount; ++i) {
            if (rec.block.voxels[i].weight > 0) {
                const float w = static_cast<float>(rec.block.voxels[i].weight);
                if (w > max_weight) max_weight = w;
                ++occupied;
                int ix = i % BLOCK_SIZE;
                int iy = (i / BLOCK_SIZE) % BLOCK_SIZE;
                int iz = i / (BLOCK_SIZE * BLOCK_SIZE);

                // SDF gradient: ONLY when all 6 neighbors have valid observations.
                // This excludes:
                //   1. Block boundary voxels (out-of-bounds → weight=0)
                //   2. Interior voxels with sparse/missing neighbors
                // Result: accurate normals even on flat surfaces.
                if (weight_at(ix-1,iy,iz) > 0 && weight_at(ix+1,iy,iz) > 0 &&
                    weight_at(ix,iy-1,iz) > 0 && weight_at(ix,iy+1,iz) > 0 &&
                    weight_at(ix,iy,iz-1) > 0 && weight_at(ix,iy,iz+1) > 0) {
                    float gx = sdf_at(ix+1,iy,iz) - sdf_at(ix-1,iy,iz);
                    float gy = sdf_at(ix,iy+1,iz) - sdf_at(ix,iy-1,iz);
                    float gz = sdf_at(ix,iy,iz+1) - sdf_at(ix,iy,iz-1);
                    // Weight by surface proximity: voxels near zero-crossing
                    // (|sdf| small) have the most geometrically accurate gradient.
                    float sdf_val = std::abs(rec.block.voxels[i].sdf.to_float());
                    float prox_w = 1.0f / (1.0f + sdf_val * 20.0f);
                    nx += gx * prox_w;
                    ny += gy * prox_w;
                    nz += gz * prox_w;
                    ++normal_contrib_count;
                }

                // Zero-crossing detection + surface position interpolation.
                // Check 3 positive-direction neighbors. When SDF sign changes,
                // linearly interpolate the crossing position: t = s0 / (s0 - s1).
                float s0 = rec.block.voxels[i].sdf.to_float();
                // Voxel center in world space
                float vx = bx0 + (static_cast<float>(ix) + 0.5f) * vs;
                float vy = by0 + (static_cast<float>(iy) + 0.5f) * vs;
                float vz = bz0 + (static_cast<float>(iz) + 0.5f) * vs;

                // Helper: compute local SDF gradient at voxel (ix,iy,iz) for
                // per-crossing normal consistency metric. Only uses valid neighbors.
                auto accumulate_crossing_normal = [&](int cx, int cy, int cz) {
                    // Compute gradient at the crossing voxel using finite differences.
                    // Only use axes where both neighbors have valid weight.
                    float cgx = 0, cgy = 0, cgz = 0;
                    int axes = 0;
                    if (cx > 0 && cx < BLOCK_SIZE-1 &&
                        weight_at(cx-1,cy,cz) > 0 && weight_at(cx+1,cy,cz) > 0) {
                        cgx = sdf_at(cx+1,cy,cz) - sdf_at(cx-1,cy,cz);
                        ++axes;
                    }
                    if (cy > 0 && cy < BLOCK_SIZE-1 &&
                        weight_at(cx,cy-1,cz) > 0 && weight_at(cx,cy+1,cz) > 0) {
                        cgy = sdf_at(cx,cy+1,cz) - sdf_at(cx,cy-1,cz);
                        ++axes;
                    }
                    if (cz > 0 && cz < BLOCK_SIZE-1 &&
                        weight_at(cx,cy,cz-1) > 0 && weight_at(cx,cy,cz+1) > 0) {
                        cgz = sdf_at(cx,cy,cz+1) - sdf_at(cx,cy,cz-1);
                        ++axes;
                    }
                    if (axes >= 2) {
                        float clen = std::sqrt(cgx*cgx + cgy*cgy + cgz*cgz);
                        if (clen > 1e-6f) {
                            cross_nx_sum += cgx / clen;
                            cross_ny_sum += cgy / clen;
                            cross_nz_sum += cgz / clen;
                            ++cross_normal_count;
                        }
                    }
                };

                // Helper: classify crossing into face bucket by SDF gradient direction.
                // Returns bucket index 0-5 (±X, ±Y, ±Z), or -1 if gradient invalid.
                auto classify_face = [&](int cx, int cy, int cz) -> int {
                    float gx = 0, gy = 0, gz = 0;
                    if (cx > 0 && cx < BLOCK_SIZE-1 &&
                        weight_at(cx-1,cy,cz) > 0 && weight_at(cx+1,cy,cz) > 0)
                        gx = sdf_at(cx+1,cy,cz) - sdf_at(cx-1,cy,cz);
                    if (cy > 0 && cy < BLOCK_SIZE-1 &&
                        weight_at(cx,cy-1,cz) > 0 && weight_at(cx,cy+1,cz) > 0)
                        gy = sdf_at(cx,cy+1,cz) - sdf_at(cx,cy-1,cz);
                    if (cz > 0 && cz < BLOCK_SIZE-1 &&
                        weight_at(cx,cy,cz-1) > 0 && weight_at(cx,cy,cz+1) > 0)
                        gz = sdf_at(cx,cy,cz+1) - sdf_at(cx,cy,cz-1);
                    float ax = std::abs(gx), ay = std::abs(gy), az = std::abs(gz);
                    if (ax < 1e-7f && ay < 1e-7f && az < 1e-7f) return -1;
                    if (ax >= ay && ax >= az) return gx > 0 ? 0 : 1;
                    if (ay >= ax && ay >= az) return gy > 0 ? 2 : 3;
                    return gz > 0 ? 4 : 5;
                };

                // Check +X neighbor
                if (ix + 1 < BLOCK_SIZE && weight_at(ix+1,iy,iz) > 0) {
                    float s1 = sdf_at(ix+1,iy,iz);
                    if ((s0 > 0) != (s1 > 0)) {
                        float t = s0 / (s0 - s1);  // Interpolation parameter [0,1]
                        double cx = vx + t * vs, cy = vy, cz = vz;
                        int bucket = classify_face(ix, iy, iz);
                        if (bucket < 0) bucket = 0;  // fallback: +X face for X-crossing
                        face_buckets[bucket].sx += cx;
                        face_buckets[bucket].sy += cy;
                        face_buckets[bucket].sz += cz;
                        face_buckets[bucket].count++;
                        surf_count++;
                        accumulate_crossing_normal(ix, iy, iz);
                    }
                }
                // Check +Y neighbor
                if (iy + 1 < BLOCK_SIZE && weight_at(ix,iy+1,iz) > 0) {
                    float s1 = sdf_at(ix,iy+1,iz);
                    if ((s0 > 0) != (s1 > 0)) {
                        float t = s0 / (s0 - s1);
                        double cx = vx, cy = vy + t * vs, cz = vz;
                        int bucket = classify_face(ix, iy, iz);
                        if (bucket < 0) bucket = 2;  // fallback: +Y face for Y-crossing
                        face_buckets[bucket].sx += cx;
                        face_buckets[bucket].sy += cy;
                        face_buckets[bucket].sz += cz;
                        face_buckets[bucket].count++;
                        surf_count++;
                        accumulate_crossing_normal(ix, iy, iz);
                    }
                }
                // Check +Z neighbor
                if (iz + 1 < BLOCK_SIZE && weight_at(ix,iy,iz+1) > 0) {
                    float s1 = sdf_at(ix,iy,iz+1);
                    if ((s0 > 0) != (s1 > 0)) {
                        float t = s0 / (s0 - s1);
                        double cx = vx, cy = vy, cz = vz + t * vs;
                        int bucket = classify_face(ix, iy, iz);
                        if (bucket < 0) bucket = 4;  // fallback: +Z face for Z-crossing
                        face_buckets[bucket].sx += cx;
                        face_buckets[bucket].sy += cy;
                        face_buckets[bucket].sz += cz;
                        face_buckets[bucket].count++;
                        surf_count++;
                        accumulate_crossing_normal(ix, iy, iz);
                    }
                }
            }
        }
        // Normalize the accumulated gradient.
        // If no interior voxels had fully valid neighbors (normal_contrib_count==0),
        // the gradient is [0,0,0] and we fall back to up-facing normal.
        // This happens for very sparsely observed blocks — the fallback is safe
        // since the shader will orient the quad toward the camera anyway.
        float nlen = std::sqrt(nx*nx + ny*ny + nz*nz);
        if (nlen > 1e-6f && normal_contrib_count > 0) {
            sample.normal[0] = nx / nlen;
            sample.normal[1] = ny / nlen;
            sample.normal[2] = nz / nlen;
        } else {
            sample.normal[0] = 0.0f;
            sample.normal[1] = 1.0f;  // Default: up
            sample.normal[2] = 0.0f;
        }
        // Use max_weight (not avg_weight) to prevent regression when new low-weight
        // voxels are added. avg_weight = sum/count can DECREASE, violating Lyapunov.
        sample.avg_weight = max_weight;
        sample.occupied_count = occupied;
        sample.training_obs_count = rec.block.training_obs_count;

        // Surface center: face-isolated positioning.
        // Select the face bucket with the most zero-crossings. This ensures
        // that when a block spans a corner (two perpendicular faces), the tile
        // is placed on the dominant face rather than floating in the void between them.
        if (surf_count > 0) {
            int best_bucket = 0;
            for (int fb = 1; fb < 6; ++fb) {
                if (face_buckets[fb].count > face_buckets[best_bucket].count) {
                    best_bucket = fb;
                }
            }
            const auto& best = face_buckets[best_bucket];
            if (best.count > 0) {
                double inv = 1.0 / static_cast<double>(best.count);
                sample.surface_center[0] = static_cast<float>(best.sx * inv);
                sample.surface_center[1] = static_cast<float>(best.sy * inv);
                sample.surface_center[2] = static_cast<float>(best.sz * inv);
            } else {
                // All crossings had invalid gradients — fall back to global average
                std::uint32_t total = 0;
                double gsx = 0, gsy = 0, gsz = 0;
                for (int fb = 0; fb < 6; ++fb) {
                    gsx += face_buckets[fb].sx;
                    gsy += face_buckets[fb].sy;
                    gsz += face_buckets[fb].sz;
                    total += face_buckets[fb].count;
                }
                if (total > 0) {
                    double inv = 1.0 / static_cast<double>(total);
                    sample.surface_center[0] = static_cast<float>(gsx * inv);
                    sample.surface_center[1] = static_cast<float>(gsy * inv);
                    sample.surface_center[2] = static_cast<float>(gsz * inv);
                } else {
                    sample.surface_center[0] = sample.center[0];
                    sample.surface_center[1] = sample.center[1];
                    sample.surface_center[2] = sample.center[2];
                }
            }
        } else {
            sample.surface_center[0] = sample.center[0];
            sample.surface_center[1] = sample.center[1];
            sample.surface_center[2] = sample.center[2];
        }

        // ── Angular diversity from 24θ×12φ directional bitmask ──
        // popcount: how many directional buckets have been observed
        const std::uint32_t theta_bits = rec.block.view_theta_bits & 0x00FFFFFFu; // mask to 24 bits
        const std::uint16_t phi_bits = rec.block.view_phi_bits & 0x0FFFu;          // mask to 12 bits
        sample.theta_filled = static_cast<std::uint8_t>(__builtin_popcount(theta_bits));
        sample.phi_filled = static_cast<std::uint8_t>(__builtin_popcount(phi_bits));

        // Circular span (theta): find largest gap in the 24-bit ring → span = 24 - maxGap
        {
            int max_gap = 0;
            if (sample.theta_filled > 0 && sample.theta_filled < 24) {
                int gap = 0;
                // Find first set bit, then walk around
                for (int b = 0; b < 48; ++b) {  // wrap-around: iterate 2x
                    if (theta_bits & (1u << (b % 24))) {
                        if (gap > max_gap) max_gap = gap;
                        gap = 0;
                    } else {
                        ++gap;
                    }
                }
                max_gap = std::min(max_gap, 24);
            } else if (sample.theta_filled == 0) {
                max_gap = 24;
            }
            sample.theta_span = static_cast<std::uint8_t>(24 - max_gap);
        }

        // Linear span (phi): max filled - min filled
        {
            int first = -1, last = -1;
            for (int b = 0; b < 12; ++b) {
                if (phi_bits & (1u << b)) {
                    if (first < 0) first = b;
                    last = b;
                }
            }
            sample.phi_span = (first >= 0) ? static_cast<std::uint8_t>(last - first + 1) : 0;
        }

        // ── Angular diversity composite score [0,1] ──
        // sigmoid((theta_span_deg - 26) / 8) * sigmoid((phi_span_deg - 15) / 6)
        // × (0.7 + 0.3 * fill_ratio)
        {
            const float theta_span_deg = static_cast<float>(sample.theta_span) * 15.0f;
            const float phi_span_deg = static_cast<float>(sample.phi_span) * 15.0f;

            // Logistic sigmoid: 1 / (1 + exp(-x))
            auto sigmoid = [](float x) -> float {
                if (x < -10.0f) return 0.0f;
                if (x > 10.0f) return 1.0f;
                return 1.0f / (1.0f + std::exp(-x));
            };

            const float theta_score = sigmoid((theta_span_deg - 26.0f) / 8.0f);
            const float phi_score = sigmoid((phi_span_deg - 15.0f) / 6.0f);
            const float fill_theta = static_cast<float>(sample.theta_filled) / 24.0f;
            const float fill_phi = static_cast<float>(sample.phi_filled) / 12.0f;
            const float fill_boost = 0.7f + 0.3f * fill_theta * fill_phi;

            sample.angular_diversity = theta_score * phi_score * fill_boost;
        }

        // ── Depth confidence: max voxel confidence [0,1] ──
        // Use max (not avg) to prevent regression when new low-confidence voxels appear.
        {
            std::uint8_t max_conf = 0;
            for (int i = 0; i < VoxelBlock::kVoxelCount; ++i) {
                if (rec.block.voxels[i].weight > 0) {
                    if (rec.block.voxels[i].confidence > max_conf) {
                        max_conf = rec.block.voxels[i].confidence;
                    }
                }
            }
            sample.depth_confidence = static_cast<float>(max_conf) / 2.0f;  // confidence max = 2
        }

        // ── Composite quality score [0,1] ──
        // Q = w_geo * geometric + w_ang * angular + w_obs * training + w_dep * depth
        // ── S6+ quality = PURE SCAN QUALITY (no training dependency) ──
        // User requirement: "只要没有区域达到s6+的审核标准，那收集多少帧也不能开始渲染"
        // Quality is determined SOLELY by scanning coverage metrics:
        //   1. Geometric confidence (voxel weight) — enough depth observations?
        //   2. Angular diversity (directional bitmask) — enough viewing angles?
        //   3. Depth confidence — reliable depth data?
        // Training observation count REMOVED: training should be gated BY quality,
        // not the other way around. S6+ must be achievable without training.
        {
            // kTargetWeight: TSDF weight at which geometric confidence saturates.
            // At 30fps / 2 (every other frame) = 15 frames/s forwarded.
            // A block in the FOV for 1s accumulates ~15 observations → weight ≈15.
            // Original 32 required ~2s of dwell time per block → too slow for
            // handheld scanning. Lowered to 16: 1s dwell → geo_q saturates.
            // This makes S6+ reachable in normal scanning speed (~3-5s per area).
            constexpr float kTargetWeight = 16.0f;
            constexpr float w_geo = 0.35f;   // 35% — enough depth observations?
            constexpr float w_ang = 0.40f;   // 40% — enough viewing angles? (strongest predictor)
            constexpr float w_dep = 0.25f;   // 25% — reliable depth data?

            const float geo_q = std::min(1.0f, sample.avg_weight / kTargetWeight);

            float raw_quality = w_geo * geo_q
                              + w_ang * sample.angular_diversity
                              + w_dep * sample.depth_confidence;

            // ── Lyapunov monotonic guarantee (peak high-water mark) ──
            // Quality ONLY increases. Once a block reaches a quality level,
            // it never visually regresses. This prevents "state regression"
            // where overlay tiles flash between red and green colors.
            if (raw_quality > rec.peak_quality) {
                rec.peak_quality = raw_quality;
            }
            sample.composite_quality = rec.peak_quality;
        }

        sample.voxel_size = vs;  // Adaptive: 0.005 (near) / 0.01 (mid) / 0.02 (far)
        // A real surface crossing an 8×8×8 block produces 20-100+ zero-crossings
        // (an entire slice of voxel pairs). Depth noise at object edges creates
        // 3-8 phantom crossings. Require ≥12 to keep only genuine surfaces.
        sample.surf_count = surf_count;
        sample.has_surface = (surf_count >= 12);

        // ── Normal consistency: how aligned are the per-crossing normals? ──
        // consistency = ||sum_of_unit_normals|| / count.
        //   1.0 = all crossings have identical normals (flat real surface).
        //   ~0.3-0.5 = chaotic normals (phantom block from depth conflicts).
        // Real surfaces produce aligned gradients because the SDF field has
        // a smooth, consistent gradient. Phantom blocks at depth discontinuities
        // have conflicting SDF values from different viewpoints, creating
        // zero-crossings with divergent gradient directions.
        if (cross_normal_count >= 3) {
            float clen = std::sqrt(cross_nx_sum * cross_nx_sum +
                                   cross_ny_sum * cross_ny_sum +
                                   cross_nz_sum * cross_nz_sum);
            sample.normal_consistency = clen / static_cast<float>(cross_normal_count);
        } else {
            sample.normal_consistency = 0.0f;  // Not enough data
        }

        // ── SDF smoothness: Laplacian-based field quality metric [0,1] ──
        // For a real surface, the SDF is a smooth linear function (distance
        // to surface plane). The discrete Laplacian of a linear function is 0.
        // For phantom blocks from depth conflicts, the SDF has abrupt
        // transitions and noise → high Laplacian magnitude.
        //
        // Compute: avg |Laplacian(sdf)| over interior voxels with valid neighbors.
        // Laplacian = sum(neighbors) - 6*center.
        // Map to [0,1]: smoothness = 1 / (1 + avg_laplacian * scale).
        // Partial Laplacian: compute per-axis second derivatives independently.
        // Only requires ONE axis with both neighbors valid (not all 6).
        // This dramatically increases coverage for sparse/edge blocks where
        // the strict all-6 requirement yielded sdf_smoothness = 0.
        {
            float laplacian_sum = 0.0f;
            int laplacian_count = 0;
            for (int iz = 1; iz < BLOCK_SIZE - 1; ++iz) {
                for (int iy = 1; iy < BLOCK_SIZE - 1; ++iy) {
                    for (int ix = 1; ix < BLOCK_SIZE - 1; ++ix) {
                        if (weight_at(ix,iy,iz) == 0) continue;
                        float center = sdf_at(ix, iy, iz);
                        float partial_lap = 0.0f;
                        int valid_axes = 0;
                        // X axis
                        if (weight_at(ix-1,iy,iz) > 0 && weight_at(ix+1,iy,iz) > 0) {
                            partial_lap += sdf_at(ix-1,iy,iz) + sdf_at(ix+1,iy,iz)
                                         - 2.0f * center;
                            ++valid_axes;
                        }
                        // Y axis
                        if (weight_at(ix,iy-1,iz) > 0 && weight_at(ix,iy+1,iz) > 0) {
                            partial_lap += sdf_at(ix,iy-1,iz) + sdf_at(ix,iy+1,iz)
                                         - 2.0f * center;
                            ++valid_axes;
                        }
                        // Z axis
                        if (weight_at(ix,iy,iz-1) > 0 && weight_at(ix,iy,iz+1) > 0) {
                            partial_lap += sdf_at(ix,iy,iz-1) + sdf_at(ix,iy,iz+1)
                                         - 2.0f * center;
                            ++valid_axes;
                        }
                        if (valid_axes >= 1) {
                            // Normalize by axes to make values comparable
                            laplacian_sum += std::abs(partial_lap)
                                           / static_cast<float>(valid_axes);
                            ++laplacian_count;
                        }
                    }
                }
            }
            if (laplacian_count >= 4) {
                float avg_lap = laplacian_sum / static_cast<float>(laplacian_count);
                // Scale factor: 10.0 maps typical noise ranges to [0,1].
                // avg_lap for real surface: ~0.01-0.05 → smoothness ~0.95-0.67
                // avg_lap for phantom:      ~0.10-0.30 → smoothness ~0.50-0.25
                sample.sdf_smoothness = 1.0f / (1.0f + avg_lap * 10.0f);
            } else {
                sample.sdf_smoothness = 0.0f;
            }
        }

        out.push_back(sample);
    }
}

void TSDFVolume::mark_training_coverage(
    const float camera_to_world[16],
    float fx, float fy, float cx_img, float cy_img,
    std::uint32_t img_width, std::uint32_t img_height)
{
    // For each active block, project center into the camera.
    // If the projection falls within the image bounds, increment training_obs_count.
    // Uses the same world_to_camera + projection as integrate() for consistency.

    const float w = static_cast<float>(img_width);
    const float h = static_cast<float>(img_height);
    // 10% margin: block center may be slightly outside but block volume overlaps
    const float margin_x = 0.1f * w;
    const float margin_y = 0.1f * h;

    for (std::size_t bi = 0; bi < blocks_.size(); ++bi) {
        BlockRecord& rec = blocks_[bi];
        if (!rec.active) continue;

        const float vs = rec.block.voxel_size > 0.0f
                       ? rec.block.voxel_size : VOXEL_SIZE_MID;
        const float block_world = vs * static_cast<float>(BLOCK_SIZE);
        const float center_x = static_cast<float>(rec.index.x) * block_world
                              + block_world * 0.5f;
        const float center_y = static_cast<float>(rec.index.y) * block_world
                              + block_world * 0.5f;
        const float center_z = static_cast<float>(rec.index.z) * block_world
                              + block_world * 0.5f;

        // World → camera (same helper as integrate)
        float cam_x = 0.0f, cam_y = 0.0f, cam_z = 0.0f;
        world_to_camera(camera_to_world, center_x, center_y, center_z,
                        cam_x, cam_y, cam_z);

        // Must be in front of camera at reasonable depth
        if (cam_z <= 0.1f || cam_z > 5.0f) continue;

        // Project to image
        const float proj_u = fx * (cam_x / cam_z) + cx_img;
        const float proj_v = fy * (cam_y / cam_z) + cy_img;

        if (proj_u >= -margin_x && proj_u < w + margin_x &&
            proj_v >= -margin_y && proj_v < h + margin_y) {
            if (rec.block.training_obs_count < 65535u) {
                rec.block.training_obs_count++;
            }
        }
    }
}

int integrate(const IntegrationInput& input, IntegrationResult& result) {
    return default_volume().integrate(input, result);
}

void handle_thermal_state(int state) {
    default_volume().handle_thermal_state(state);
}

void handle_memory_pressure(int level) {
    if (level <= 0) {
        default_volume().handle_memory_pressure_ratio(0.50f);
        return;
    }
    MemoryPressureLevel mapped = MemoryPressureLevel::kWarning;
    if (level == 2) mapped = MemoryPressureLevel::kCritical;
    if (level >= 3) mapped = MemoryPressureLevel::kTerminal;
    default_volume().handle_memory_pressure(mapped);
}

void handle_memory_pressure_ratio(float pressure_ratio) {
    default_volume().handle_memory_pressure_ratio(pressure_ratio);
}

bool query_default_block_runtime_info(
    const BlockIndex& block_index,
    TSDFBlockRuntimeInfo* out_info) {
    return default_volume().query_block_runtime_info(block_index, out_info);
}

}  // namespace tsdf
}  // namespace aether
