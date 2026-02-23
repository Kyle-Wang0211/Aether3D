// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/innovation/f6_conflict_dynamic_rejection.h"

#include <cstdio>
#include <vector>

namespace {

aether::innovation::GaussianPrimitive make_gaussian(std::uint32_t id) {
    aether::innovation::GaussianPrimitive g{};
    g.id = id;
    g.host_unit_id = 10u;
    g.opacity = 0.6f;
    g.observation_count = 4u;
    return g;
}

int test_conflict_to_dynamic_and_recover() {
    int failed = 0;
    using namespace aether::innovation;
    using aether::evidence::DSMassFunction;

    F6RejectorConfig cfg{};
    cfg.conflict_threshold = 0.30;
    cfg.sustain_frames = 3u;
    cfg.recover_frames = 2u;
    cfg.release_ratio = 0.6;
    F6ConflictDynamicRejector rejector(cfg);

    GaussianPrimitive gaussians[1] = {make_gaussian(42u)};
    F6ObservationPair pair{};
    pair.gaussian_id = 42u;
    pair.host_unit_id = 10u;
    pair.predicted = DSMassFunction(0.90, 0.05, 0.05);
    pair.observed = DSMassFunction(0.05, 0.90, 0.05);

    F6FrameMetrics metrics{};
    for (int i = 0; i < 3; ++i) {
        if (rejector.process_frame(&pair, 1u, gaussians, 1u, &metrics) != aether::core::Status::kOk) {
            std::fprintf(stderr, "process_frame conflict stage failed\n");
            return 1;
        }
    }
    if (!gaussian_is_dynamic(gaussians[0])) {
        std::fprintf(stderr, "gaussian should become dynamic after sustained conflict\n");
        failed++;
    }

    std::vector<std::uint32_t> binding_indices;
    if (f6_collect_static_binding_indices(gaussians, 1u, &binding_indices) != aether::core::Status::kOk) {
        std::fprintf(stderr, "collect static indices failed\n");
        failed++;
    } else if (!binding_indices.empty()) {
        std::fprintf(stderr, "dynamic gaussian should be excluded from binding indices\n");
        failed++;
    }

    pair.observed = DSMassFunction(0.92, 0.03, 0.05);  // low conflict.
    for (int i = 0; i < 2; ++i) {
        if (rejector.process_frame(&pair, 1u, gaussians, 1u, &metrics) != aether::core::Status::kOk) {
            std::fprintf(stderr, "process_frame recovery stage failed\n");
            return failed + 1;
        }
    }
    if (gaussian_is_dynamic(gaussians[0])) {
        std::fprintf(stderr, "gaussian should recover to static after stable frames\n");
        failed++;
    }

    return failed;
}

int test_no_false_positive_and_invalid() {
    int failed = 0;
    using namespace aether::innovation;
    using aether::evidence::DSMassFunction;

    F6ConflictDynamicRejector rejector{};
    GaussianPrimitive gaussians[1] = {make_gaussian(7u)};
    F6ObservationPair pair{};
    pair.gaussian_id = 7u;
    pair.host_unit_id = 1u;
    pair.predicted = DSMassFunction(0.80, 0.10, 0.10);
    pair.observed = DSMassFunction(0.78, 0.12, 0.10);

    F6FrameMetrics metrics{};
    for (int i = 0; i < 4; ++i) {
        if (rejector.process_frame(&pair, 1u, gaussians, 1u, &metrics) != aether::core::Status::kOk) {
            std::fprintf(stderr, "process_frame low-conflict failed\n");
            return 1;
        }
    }
    if (gaussian_is_dynamic(gaussians[0])) {
        std::fprintf(stderr, "low conflict should not trigger dynamic marking\n");
        failed++;
    }

    if (rejector.process_frame(nullptr, 1u, gaussians, 1u, &metrics) != aether::core::Status::kInvalidArgument) {
        std::fprintf(stderr, "null pair pointer should fail\n");
        failed++;
    }
    if (rejector.process_frame(&pair, 1u, nullptr, 1u, &metrics) != aether::core::Status::kInvalidArgument) {
        std::fprintf(stderr, "null gaussian pointer should fail\n");
        failed++;
    }
    if (f6_collect_static_binding_indices(gaussians, 1u, nullptr) != aether::core::Status::kInvalidArgument) {
        std::fprintf(stderr, "null output vector should fail\n");
        failed++;
    }

    return failed;
}

}  // namespace

int main() {
    int failed = 0;
    failed += test_conflict_to_dynamic_and_recover();
    failed += test_no_false_positive_and_invalid();
    return failed;
}
