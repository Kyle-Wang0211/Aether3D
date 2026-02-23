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
    y_cam = (v - cy) * d / fy;
    z_cam = d;
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
    y_cam = camera_to_world[4] * dx + camera_to_world[5] * dy + camera_to_world[6] * dz;
    z_cam = camera_to_world[8] * dx + camera_to_world[9] * dy + camera_to_world[10] * dz;
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

    int valid_pixels = 0;
    for (int v = 0; v < h; ++v) {
        for (int u = 0; u < w; ++u) {
            const float d = input.depth_data[static_cast<size_t>(v) * static_cast<size_t>(w) + static_cast<size_t>(u)];
            if (!std::isfinite(d) || d < DEPTH_MIN || d > DEPTH_MAX) continue;
            if (SKIP_LOW_CONFIDENCE_PIXELS && input.confidence_data &&
                input.confidence_data[static_cast<size_t>(v) * static_cast<size_t>(w) + static_cast<size_t>(u)] == 0) {
                continue;
            }
            ++valid_pixels;
        }
    }

    const float valid_ratio = total_pixels > 0
        ? static_cast<float>(valid_pixels) / static_cast<float>(total_pixels)
        : 0.0f;
    if (valid_ratio < MIN_VALID_PIXEL_RATIO) {
        result.skipped = true;
        result.skip_reason = IntegrationSkipReason::kLowValidPixels;
        ++consecutive_rejections_;
        ++frame_count_;
        return -11;
    }

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
    const float cam_forward_x = view[8];
    const float cam_forward_y = view[9];
    const float cam_forward_z = view[10];
    const float cam_forward_len = std::sqrt(
        cam_forward_x * cam_forward_x +
        cam_forward_y * cam_forward_y +
        cam_forward_z * cam_forward_z);

    for (int v = 0; v < h; ++v) {
        for (int u = 0; u < w; ++u) {
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
                    } else {
                        TSDFVolume::BlockRecord rec{};
                        rec.index = bi;
                        rec.block.clear(selected_voxel_size);
                        rec.active = true;
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
