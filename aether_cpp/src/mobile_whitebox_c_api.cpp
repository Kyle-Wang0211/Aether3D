// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether_tsdf_c.h"

#include "aether/core/status.h"
#include "aether/render/gpu_device.h"
#include "aether/trainer/da3_depth_fuser.h"
#include "aether/trainer/noise_aware_trainer.h"
#include "aether/tsdf/pose_stabilizer.h"

#include <cmath>
#include <cstdint>
#include <cstring>
#include <new>
#include <vector>

using aether::core::Status;
using aether::render::GPUDevice;

struct aether_gpu_device {
    GPUDevice* impl;
};

struct aether_pose_stabilizer {
    explicit aether_pose_stabilizer(const aether::tsdf::PoseStabilizerConfig& config)
        : impl(config) {}

    aether::tsdf::PoseStabilizer impl;
};

namespace {

inline int to_rc(Status status) {
    return static_cast<int>(status);
}

inline aether::trainer::TriTetClass to_cpp_tri_tet_class(std::uint8_t tri_tet_class) {
    switch (tri_tet_class) {
        case AETHER_TRI_TET_CLASS_MEASURED:
            return aether::trainer::TriTetClass::kMeasured;
        case AETHER_TRI_TET_CLASS_ESTIMATED:
            return aether::trainer::TriTetClass::kEstimated;
        default:
            return aether::trainer::TriTetClass::kUnknown;
    }
}

}  // namespace

extern "C" {

void aether_gpu_device_destroy(aether_gpu_device_t* device) {
    if (!device) {
        return;
    }
    delete device->impl;
    delete device;
}

int aether_pose_stabilizer_create(
    const aether_pose_stabilizer_config_t* config_or_null,
    aether_pose_stabilizer_t** out_stabilizer) {
    if (out_stabilizer == nullptr) {
        return -1;
    }

    aether::tsdf::PoseStabilizerConfig config{};
    if (config_or_null != nullptr) {
        config.translation_alpha = config_or_null->translation_alpha;
        config.rotation_alpha = config_or_null->rotation_alpha;
        config.max_prediction_horizon_s = config_or_null->max_prediction_horizon_s;
        config.bias_alpha = config_or_null->bias_alpha;
        config.init_frames = config_or_null->init_frames;
        config.fast_init = (config_or_null->fast_init != 0);
        config.use_ieskf = (config_or_null->use_ieskf != 0);
    }

    auto* stabilizer = new (std::nothrow) aether_pose_stabilizer_t(config);
    if (stabilizer == nullptr) {
        return -2;
    }

    *out_stabilizer = stabilizer;
    return 0;
}

int aether_pose_stabilizer_destroy(aether_pose_stabilizer_t* stabilizer) {
    if (stabilizer == nullptr) {
        return -1;
    }
    delete stabilizer;
    return 0;
}

int aether_pose_stabilizer_reset(aether_pose_stabilizer_t* stabilizer) {
    if (stabilizer == nullptr) {
        return -1;
    }
    stabilizer->impl.reset();
    return 0;
}

int aether_pose_stabilizer_update(
    aether_pose_stabilizer_t* stabilizer,
    const float* raw_pose_16,
    const float* gyro_xyz,
    const float* accel_xyz,
    uint64_t timestamp_ns,
    float* out_stabilized_pose_16,
    float* out_pose_quality) {
    if (stabilizer == nullptr ||
        raw_pose_16 == nullptr ||
        gyro_xyz == nullptr ||
        accel_xyz == nullptr ||
        out_stabilized_pose_16 == nullptr ||
        out_pose_quality == nullptr) {
        return -1;
    }

    const Status status = stabilizer->impl.update(
        raw_pose_16,
        gyro_xyz,
        accel_xyz,
        timestamp_ns,
        out_stabilized_pose_16,
        out_pose_quality);
    return status == Status::kOk ? 0 : to_rc(status);
}

int aether_pose_stabilizer_predict(
    const aether_pose_stabilizer_t* stabilizer,
    uint64_t target_timestamp_ns,
    float* out_predicted_pose_16) {
    if (stabilizer == nullptr || out_predicted_pose_16 == nullptr) {
        return -1;
    }

    const Status status = stabilizer->impl.predict(
        target_timestamp_ns,
        out_predicted_pose_16);
    return status == Status::kOk ? 0 : to_rc(status);
}

int aether_da3_fuse_depth(
    const aether_da3_depth_sample_t* sample,
    float* out_fused_depth,
    float* out_confidence) {
    if (sample == nullptr || out_fused_depth == nullptr) {
        return -1;
    }
    if (!std::isfinite(sample->depth_from_vision) ||
        !std::isfinite(sample->depth_from_tsdf) ||
        !std::isfinite(sample->sigma2_vision) ||
        !std::isfinite(sample->sigma2_tsdf)) {
        return -1;
    }

    aether::trainer::DA3DepthSample cpp_sample{};
    cpp_sample.depth_from_vision = sample->depth_from_vision;
    cpp_sample.depth_from_tsdf = sample->depth_from_tsdf;
    cpp_sample.sigma2_vision = sample->sigma2_vision;
    cpp_sample.sigma2_tsdf = sample->sigma2_tsdf;
    cpp_sample.tri_tet_class = to_cpp_tri_tet_class(sample->tri_tet_class);

    float confidence = 0.0f;
    *out_fused_depth = aether::trainer::fuse_da3_depth(
        cpp_sample,
        out_confidence != nullptr ? &confidence : nullptr);
    if (out_confidence != nullptr) {
        *out_confidence = confidence;
    }
    return 0;
}

int aether_noise_aware_compute_weight(
    const aether_noise_aware_sample_t* sample,
    float* out_weight) {
    if (sample == nullptr || out_weight == nullptr) {
        return -1;
    }

    aether::trainer::NoiseAwareSample cpp_sample{};
    cpp_sample.photometric_residual = sample->photometric_residual;
    cpp_sample.depth_residual = sample->depth_residual;
    cpp_sample.sigma2 = sample->sigma2;
    cpp_sample.confidence = sample->confidence;
    cpp_sample.tri_tet_class = to_cpp_tri_tet_class(sample->tri_tet_class);

    *out_weight = aether::trainer::compute_noise_aware_weight(cpp_sample);
    return 0;
}

int aether_noise_aware_batch_loss(
    const aether_noise_aware_sample_t* samples,
    int count,
    aether_noise_aware_result_t* out_result) {
    if (out_result == nullptr) {
        return -1;
    }
    if (count > 0 && samples == nullptr) {
        return -1;
    }

    std::vector<aether::trainer::NoiseAwareSample> cpp_samples;
    cpp_samples.reserve(static_cast<std::size_t>(count));
    for (int i = 0; i < count; ++i) {
        aether::trainer::NoiseAwareSample cpp_sample{};
        cpp_sample.photometric_residual = samples[i].photometric_residual;
        cpp_sample.depth_residual = samples[i].depth_residual;
        cpp_sample.sigma2 = samples[i].sigma2;
        cpp_sample.confidence = samples[i].confidence;
        cpp_sample.tri_tet_class = to_cpp_tri_tet_class(samples[i].tri_tet_class);
        cpp_samples.push_back(cpp_sample);
    }

    aether::trainer::NoiseAwareAccumulator acc{};
    const Status status = aether::trainer::accumulate_noise_aware_batch(
        cpp_samples.data(),
        cpp_samples.size(),
        &acc);
    if (status != Status::kOk) {
        return to_rc(status);
    }

    out_result->weighted_loss = aether::trainer::finalize_noise_aware_loss(acc);
    out_result->weight_sum = static_cast<float>(acc.weight_sum);
    out_result->sample_count = static_cast<uint32_t>(acc.sample_count);
    return 0;
}

int aether_scan_state_can_transition(
    int32_t from_state,
    int32_t to_state,
    int32_t* out_allowed) {
    if (out_allowed == nullptr) {
        return -1;
    }

    int32_t allowed = 0;
    switch (from_state) {
        case AETHER_SCAN_STATE_INITIALIZING:
            allowed = (to_state == AETHER_SCAN_STATE_READY || to_state == AETHER_SCAN_STATE_FAILED) ? 1 : 0;
            break;
        case AETHER_SCAN_STATE_READY:
            allowed = (to_state == AETHER_SCAN_STATE_CAPTURING || to_state == AETHER_SCAN_STATE_FAILED) ? 1 : 0;
            break;
        case AETHER_SCAN_STATE_CAPTURING:
            allowed = (to_state == AETHER_SCAN_STATE_PAUSED ||
                       to_state == AETHER_SCAN_STATE_FINISHING ||
                       to_state == AETHER_SCAN_STATE_FAILED) ? 1 : 0;
            break;
        case AETHER_SCAN_STATE_PAUSED:
            allowed = (to_state == AETHER_SCAN_STATE_CAPTURING ||
                       to_state == AETHER_SCAN_STATE_READY ||
                       to_state == AETHER_SCAN_STATE_FINISHING ||
                       to_state == AETHER_SCAN_STATE_FAILED) ? 1 : 0;
            break;
        case AETHER_SCAN_STATE_FINISHING:
            allowed = (to_state == AETHER_SCAN_STATE_COMPLETED ||
                       to_state == AETHER_SCAN_STATE_FAILED) ? 1 : 0;
            break;
        case AETHER_SCAN_STATE_COMPLETED:
            allowed = (to_state == AETHER_SCAN_STATE_READY) ? 1 : 0;
            break;
        case AETHER_SCAN_STATE_FAILED:
            allowed = (to_state == AETHER_SCAN_STATE_READY) ? 1 : 0;
            break;
        default:
            allowed = 0;
            break;
    }

    *out_allowed = allowed;
    return 0;
}

int aether_scan_state_is_active(
    int32_t state,
    int32_t* out_active) {
    if (out_active == nullptr) {
        return -1;
    }
    *out_active = (state == AETHER_SCAN_STATE_CAPTURING || state == AETHER_SCAN_STATE_FINISHING) ? 1 : 0;
    return 0;
}

int aether_scan_state_can_finish(
    int32_t state,
    int32_t* out_can_finish) {
    if (out_can_finish == nullptr) {
        return -1;
    }
    *out_can_finish = (state == AETHER_SCAN_STATE_CAPTURING || state == AETHER_SCAN_STATE_PAUSED) ? 1 : 0;
    return 0;
}

int aether_scan_state_recommended_abort_state(
    int32_t state,
    int32_t* out_state) {
    if (out_state == nullptr) {
        return -1;
    }
    *out_state = (state == AETHER_SCAN_STATE_COMPLETED) ? AETHER_SCAN_STATE_COMPLETED : AETHER_SCAN_STATE_FAILED;
    return 0;
}

int aether_scan_state_action_plan(
    int32_t state,
    int32_t reason,
    aether_scan_action_plan_t* out_plan) {
    if (out_plan == nullptr) {
        return -1;
    }

    std::memset(out_plan, 0, sizeof(*out_plan));
    if (reason == AETHER_SCAN_ACTION_REASON_ABORT) {
        out_plan->action_mask = AETHER_SCAN_ACTION_APPLY_TRANSITION;
        out_plan->overlay_clear_alpha = 0.0f;
        out_plan->transition_target_state = AETHER_SCAN_STATE_FAILED;
        return 0;
    }

    out_plan->action_mask = AETHER_SCAN_ACTION_SET_BORDER_DEPTH_LESS_EQUAL;
    out_plan->overlay_clear_alpha = 0.0f;
    out_plan->transition_target_state = state;
    return 0;
}

int aether_scan_state_render_presentation_policy(
    int32_t /*state*/,
    aether_scan_render_presentation_policy_t* out_policy) {
    if (out_policy == nullptr) {
        return -1;
    }

    std::memset(out_policy, 0, sizeof(*out_policy));
    out_policy->force_black_background = 0;
    out_policy->overlay_opaque = 0;
    out_policy->overlay_clear_alpha = 0.0f;
    out_policy->border_depth_mode = AETHER_SCAN_BORDER_DEPTH_LESS_EQUAL;
    return 0;
}

}  // extern "C"
