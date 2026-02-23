// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/scheduler/gpu_scheduler.h"

#include <cmath>
#include <cstdio>

namespace {

bool approx(float a, float b, float eps) {
    return std::fabs(a - b) <= eps;
}

int test_allocate_budget() {
    int failed = 0;
    using namespace aether::scheduler;

    TwoStateGPUScheduler scheduler{};
    GPUBudget capture{};
    if (scheduler.allocate_budget(GPUSchedulerState::kCapturing, &capture) != aether::core::Status::kOk) {
        std::fprintf(stderr, "allocate capture budget failed\n");
        return 1;
    }
    if (!approx(capture.tracking_ms, 4.0f, 1e-5f) ||
        !approx(capture.rendering_ms, 4.0f, 1e-5f) ||
        !approx(capture.optimization_ms, 1.0f, 1e-5f) ||
        !approx(capture.system_reserve_ms, 3.5f, 1e-5f) ||
        !approx(capture.flexible_pool_ms, 4.1f, 1e-4f)) {
        std::fprintf(stderr, "capture budget mismatch\n");
        failed++;
    }

    GPUBudget finished{};
    if (scheduler.allocate_budget(GPUSchedulerState::kCaptureFinished, &finished) != aether::core::Status::kOk) {
        std::fprintf(stderr, "allocate finished budget failed\n");
        return failed + 1;
    }
    if (!approx(finished.tracking_ms, 0.0f, 1e-5f) ||
        !approx(finished.rendering_ms, 2.0f, 1e-5f) ||
        !approx(finished.optimization_ms, 7.0f, 1e-5f) ||
        !approx(finished.flexible_pool_ms, 4.1f, 1e-4f)) {
        std::fprintf(stderr, "finished budget mismatch\n");
        failed++;
    }
    return failed;
}

int test_execute_frame_priorities() {
    int failed = 0;
    using namespace aether::scheduler;

    TwoStateGPUScheduler scheduler{};

    GPUWorkload capture_workload{};
    capture_workload.tracking_demand_ms = 7.0f;
    capture_workload.rendering_demand_ms = 7.0f;
    capture_workload.optimization_demand_ms = 7.0f;
    GPUFrameResult capture_result{};
    if (scheduler.execute_frame(
            GPUSchedulerState::kCapturing,
            capture_workload,
            &capture_result) != aether::core::Status::kOk) {
        std::fprintf(stderr, "execute capture frame failed\n");
        return 1;
    }
    if (!(capture_result.tracking_assigned_ms >= capture_result.rendering_assigned_ms &&
          capture_result.rendering_assigned_ms >= capture_result.optimization_assigned_ms)) {
        std::fprintf(stderr, "capture priority ordering mismatch\n");
        failed++;
    }

    GPUWorkload finished_workload{};
    finished_workload.tracking_demand_ms = 4.0f;
    finished_workload.rendering_demand_ms = 7.0f;
    finished_workload.optimization_demand_ms = 12.0f;
    GPUFrameResult finished_result{};
    if (scheduler.execute_frame(
            GPUSchedulerState::kCaptureFinished,
            finished_workload,
            &finished_result) != aether::core::Status::kOk) {
        std::fprintf(stderr, "execute finished frame failed\n");
        return failed + 1;
    }
    if (!(finished_result.optimization_assigned_ms >= finished_result.rendering_assigned_ms &&
          finished_result.rendering_assigned_ms >= finished_result.tracking_assigned_ms)) {
        std::fprintf(stderr, "finished priority ordering mismatch\n");
        failed++;
    }
    if (finished_result.unused_flexible_ms < -1e-4f) {
        std::fprintf(stderr, "unused flexible pool must be non-negative\n");
        failed++;
    }
    return failed;
}

int test_thermal_scale() {
    int failed = 0;
    using namespace aether::scheduler;

    TwoStateGPUScheduler scheduler{};
    GPUBudget budget{};
    if (scheduler.allocate_budget(GPUSchedulerState::kCapturing, &budget) != aether::core::Status::kOk) {
        std::fprintf(stderr, "allocate budget for thermal test failed\n");
        return 1;
    }
    if (scheduler.apply_thermal_scale(0.5f, &budget) != aether::core::Status::kOk) {
        std::fprintf(stderr, "apply thermal scale failed\n");
        return failed + 1;
    }
    if (!approx(budget.tracking_ms, 2.0f, 1e-5f) ||
        !approx(budget.rendering_ms, 2.0f, 1e-5f) ||
        !approx(budget.optimization_ms, 0.5f, 1e-5f)) {
        std::fprintf(stderr, "thermal scale mismatch\n");
        failed++;
    }
    if (scheduler.apply_thermal_scale(1.2f, &budget) != aether::core::Status::kInvalidArgument) {
        std::fprintf(stderr, "invalid thermal scale should fail\n");
        failed++;
    }
    return failed;
}

int test_config_ab_weights() {
    int failed = 0;
    using namespace aether::scheduler;

    GPUSchedulerConfig config_a{};
    config_a.capture_tracking_weight = 1.0f;
    config_a.capture_rendering_weight = 1.0f;
    config_a.capture_optimization_weight = 1.0f;

    GPUSchedulerConfig config_b{};
    config_b.capture_tracking_weight = 4.0f;
    config_b.capture_rendering_weight = 2.0f;
    config_b.capture_optimization_weight = 1.0f;

    TwoStateGPUScheduler scheduler_a{config_a};
    TwoStateGPUScheduler scheduler_b{config_b};

    GPUWorkload workload{};
    workload.tracking_demand_ms = 9.0f;
    workload.rendering_demand_ms = 7.0f;
    workload.optimization_demand_ms = 6.0f;

    GPUFrameResult result_a{};
    GPUFrameResult result_b{};
    if (scheduler_a.execute_frame(GPUSchedulerState::kCapturing, workload, &result_a) != aether::core::Status::kOk ||
        scheduler_b.execute_frame(GPUSchedulerState::kCapturing, workload, &result_b) != aether::core::Status::kOk) {
        std::fprintf(stderr, "A/B scheduler execution failed\n");
        return 1;
    }

    if (!(result_b.tracking_assigned_ms >= result_a.tracking_assigned_ms)) {
        std::fprintf(stderr, "B config should prioritize tracking more than A\n");
        failed++;
    }
    return failed;
}

}  // namespace

int main() {
    int failed = 0;
    failed += test_allocate_budget();
    failed += test_execute_frame_priorities();
    failed += test_thermal_scale();
    failed += test_config_ab_weights();
    return failed;
}
