// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_SCHEDULER_GPU_SCHEDULER_H
#define AETHER_SCHEDULER_GPU_SCHEDULER_H

#ifdef __cplusplus

#include "aether/core/status.h"

namespace aether {
namespace scheduler {

enum class GPUSchedulerState : int {
    kCapturing = 0,
    kCaptureFinished = 1,
};

struct GPUBudget {
    float tracking_ms{0.0f};
    float rendering_ms{0.0f};
    float optimization_ms{0.0f};
    float flexible_pool_ms{0.0f};
    float system_reserve_ms{3.5f};
    float total_frame_budget_ms{16.6f};
};

struct GPUSchedulerConfig {
    float total_frame_budget_ms{16.6f};
    float system_reserve_ms{3.5f};

    float capture_tracking_min_ms{4.0f};
    float capture_rendering_min_ms{4.0f};
    float capture_optimization_min_ms{1.0f};

    float finished_tracking_min_ms{0.0f};
    float finished_rendering_min_ms{2.0f};
    float finished_optimization_min_ms{7.0f};

    float capture_tracking_weight{4.0f};
    float capture_rendering_weight{2.0f};
    float capture_optimization_weight{1.0f};

    float finished_tracking_weight{1.0f};
    float finished_rendering_weight{2.0f};
    float finished_optimization_weight{4.0f};
};

struct GPUWorkload {
    float tracking_demand_ms{0.0f};
    float rendering_demand_ms{0.0f};
    float optimization_demand_ms{0.0f};
};

struct GPUFrameResult {
    GPUBudget budget{};
    float tracking_assigned_ms{0.0f};
    float rendering_assigned_ms{0.0f};
    float optimization_assigned_ms{0.0f};
    float unused_flexible_ms{0.0f};
};

class TwoStateGPUScheduler {
public:
    explicit TwoStateGPUScheduler(GPUSchedulerConfig config = {});

    const GPUSchedulerConfig& config() const { return config_; }

    core::Status allocate_budget(
        GPUSchedulerState state,
        GPUBudget* out_budget) const;

    core::Status execute_frame(
        GPUSchedulerState state,
        const GPUWorkload& workload,
        GPUFrameResult* out_result) const;

    core::Status apply_thermal_scale(
        float thermal_scale,
        GPUBudget* inout_budget) const;

private:
    GPUSchedulerConfig config_{};
};

}  // namespace scheduler
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_SCHEDULER_GPU_SCHEDULER_H
