// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/scheduler/gpu_scheduler.h"

#include <algorithm>

namespace aether {
namespace scheduler {
namespace {

inline float clamp_non_negative(float value) {
    return std::max(0.0f, value);
}

inline float minf(float a, float b) {
    return (a < b) ? a : b;
}

void distribute_pool_weighted(
    float pool,
    const float deficits[3],
    const float weights[3],
    float extras[3]) {
    extras[0] = 0.0f;
    extras[1] = 0.0f;
    extras[2] = 0.0f;
    if (pool <= 0.0f) {
        return;
    }

    float weighted_sum = 0.0f;
    for (int i = 0; i < 3; ++i) {
        if (deficits[i] > 0.0f && weights[i] > 0.0f) {
            weighted_sum += deficits[i] * weights[i];
        }
    }
    if (weighted_sum <= 0.0f) {
        return;
    }

    float used = 0.0f;
    for (int i = 0; i < 3; ++i) {
        if (deficits[i] <= 0.0f || weights[i] <= 0.0f) {
            continue;
        }
        const float ratio = (deficits[i] * weights[i]) / weighted_sum;
        const float grant = minf(deficits[i], pool * ratio);
        extras[i] = grant;
        used += grant;
    }

    float remain = std::max(0.0f, pool - used);
    if (remain <= 1e-6f) {
        return;
    }
    for (int i = 0; i < 3 && remain > 1e-6f; ++i) {
        const float room = std::max(0.0f, deficits[i] - extras[i]);
        const float topup = minf(room, remain);
        extras[i] += topup;
        remain -= topup;
    }
}

core::Status validate_config(const GPUSchedulerConfig& cfg) {
    if (cfg.total_frame_budget_ms <= 0.0f ||
        cfg.system_reserve_ms < 0.0f ||
        cfg.system_reserve_ms >= cfg.total_frame_budget_ms ||
        cfg.capture_tracking_min_ms < 0.0f ||
        cfg.capture_rendering_min_ms < 0.0f ||
        cfg.capture_optimization_min_ms < 0.0f ||
        cfg.finished_tracking_min_ms < 0.0f ||
        cfg.finished_rendering_min_ms < 0.0f ||
        cfg.finished_optimization_min_ms < 0.0f ||
        cfg.capture_tracking_weight < 0.0f ||
        cfg.capture_rendering_weight < 0.0f ||
        cfg.capture_optimization_weight < 0.0f ||
        cfg.finished_tracking_weight < 0.0f ||
        cfg.finished_rendering_weight < 0.0f ||
        cfg.finished_optimization_weight < 0.0f) {
        return core::Status::kInvalidArgument;
    }
    if ((cfg.capture_tracking_weight +
         cfg.capture_rendering_weight +
         cfg.capture_optimization_weight) <= 0.0f ||
        (cfg.finished_tracking_weight +
         cfg.finished_rendering_weight +
         cfg.finished_optimization_weight) <= 0.0f) {
        return core::Status::kInvalidArgument;
    }
    return core::Status::kOk;
}

}  // namespace

TwoStateGPUScheduler::TwoStateGPUScheduler(GPUSchedulerConfig config)
    : config_(config) {}

core::Status TwoStateGPUScheduler::allocate_budget(
    GPUSchedulerState state,
    GPUBudget* out_budget) const {
    if (out_budget == nullptr) {
        return core::Status::kInvalidArgument;
    }
    const core::Status valid = validate_config(config_);
    if (valid != core::Status::kOk) {
        return valid;
    }

    GPUBudget budget{};
    budget.total_frame_budget_ms = config_.total_frame_budget_ms;
    budget.system_reserve_ms = config_.system_reserve_ms;

    if (state == GPUSchedulerState::kCapturing) {
        budget.tracking_ms = config_.capture_tracking_min_ms;
        budget.rendering_ms = config_.capture_rendering_min_ms;
        budget.optimization_ms = config_.capture_optimization_min_ms;
    } else {
        budget.tracking_ms = config_.finished_tracking_min_ms;
        budget.rendering_ms = config_.finished_rendering_min_ms;
        budget.optimization_ms = config_.finished_optimization_min_ms;
    }

    const float fixed = budget.tracking_ms + budget.rendering_ms + budget.optimization_ms + budget.system_reserve_ms;
    if (fixed > budget.total_frame_budget_ms + 1e-5f) {
        return core::Status::kOutOfRange;
    }
    budget.flexible_pool_ms = clamp_non_negative(budget.total_frame_budget_ms - fixed);
    *out_budget = budget;
    return core::Status::kOk;
}

core::Status TwoStateGPUScheduler::execute_frame(
    GPUSchedulerState state,
    const GPUWorkload& workload,
    GPUFrameResult* out_result) const {
    if (out_result == nullptr) {
        return core::Status::kInvalidArgument;
    }

    GPUBudget budget{};
    core::Status status = allocate_budget(state, &budget);
    if (status != core::Status::kOk) {
        return status;
    }

    GPUFrameResult result{};
    result.budget = budget;
    result.tracking_assigned_ms = budget.tracking_ms;
    result.rendering_assigned_ms = budget.rendering_ms;
    result.optimization_assigned_ms = budget.optimization_ms;

    float pool = budget.flexible_pool_ms;
    const float deficits[3] = {
        clamp_non_negative(workload.tracking_demand_ms - result.tracking_assigned_ms),
        clamp_non_negative(workload.rendering_demand_ms - result.rendering_assigned_ms),
        clamp_non_negative(workload.optimization_demand_ms - result.optimization_assigned_ms),
    };
    const float capture_weights[3] = {
        config_.capture_tracking_weight,
        config_.capture_rendering_weight,
        config_.capture_optimization_weight};   // tracking > rendering > optimization
    const float finished_weights[3] = {
        config_.finished_tracking_weight,
        config_.finished_rendering_weight,
        config_.finished_optimization_weight};  // optimization > rendering > tracking
    const float* weights = (state == GPUSchedulerState::kCapturing)
        ? capture_weights
        : finished_weights;

    float extras[3] = {0.0f, 0.0f, 0.0f};
    distribute_pool_weighted(pool, deficits, weights, extras);
    result.tracking_assigned_ms += extras[0];
    result.rendering_assigned_ms += extras[1];
    result.optimization_assigned_ms += extras[2];
    pool = std::max(0.0f, pool - extras[0] - extras[1] - extras[2]);

    result.unused_flexible_ms = pool;
    *out_result = result;
    return core::Status::kOk;
}

core::Status TwoStateGPUScheduler::apply_thermal_scale(
    float thermal_scale,
    GPUBudget* inout_budget) const {
    if (inout_budget == nullptr) {
        return core::Status::kInvalidArgument;
    }
    if (thermal_scale < 0.0f || thermal_scale > 1.0f) {
        return core::Status::kInvalidArgument;
    }

    inout_budget->tracking_ms *= thermal_scale;
    inout_budget->rendering_ms *= thermal_scale;
    inout_budget->optimization_ms *= thermal_scale;
    inout_budget->flexible_pool_ms *= thermal_scale;
    return core::Status::kOk;
}

}  // namespace scheduler
}  // namespace aether
