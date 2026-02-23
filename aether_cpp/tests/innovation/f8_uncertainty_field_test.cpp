// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/innovation/f8_uncertainty_field.h"

#include <cstdio>
#include <vector>

namespace {

aether::innovation::GaussianPrimitive make_gaussian(std::uint32_t id, float uncertainty) {
    aether::innovation::GaussianPrimitive g{};
    g.id = id;
    g.host_unit_id = 1u;
    g.uncertainty = uncertainty;
    g.opacity = 0.5f;
    return g;
}

int test_update_and_view_dependence() {
    int failed = 0;
    using namespace aether::innovation;

    F8UncertaintyField field{};
    std::vector<GaussianPrimitive> gaussians;
    gaussians.push_back(make_gaussian(1u, 0.50f));
    gaussians.push_back(make_gaussian(2u, 0.50f));

    F8Observation obs[1]{};
    obs[0].gaussian_id = 1u;
    obs[0].observed = true;
    obs[0].residual = 0.1f;
    obs[0].view_cosine = 1.0f;
    obs[0].ds_belief = 0.8;

    F8FrameStats stats{};
    if (field.process_frame(obs, 1u, gaussians.data(), gaussians.size(), &stats) != aether::core::Status::kOk) {
        std::fprintf(stderr, "process_frame failed\n");
        return 1;
    }

    if (!(gaussians[0].uncertainty < 0.50f)) {
        std::fprintf(stderr, "observed gaussian uncertainty should decrease\n");
        failed++;
    }
    if (!(gaussians[1].uncertainty > 0.50f)) {
        std::fprintf(stderr, "unobserved gaussian uncertainty should increase\n");
        failed++;
    }

    float u_front = 0.0f;
    float u_glancing = 0.0f;
    if (field.query_uncertainty(1u, 1.0f, &u_front) != aether::core::Status::kOk ||
        field.query_uncertainty(1u, 0.0f, &u_glancing) != aether::core::Status::kOk) {
        std::fprintf(stderr, "query_uncertainty failed\n");
        failed++;
    } else if (!(u_glancing > u_front)) {
        std::fprintf(stderr, "view-dependent uncertainty should be higher at glancing angle\n");
        failed++;
    }

    double fused = 0.0;
    if (field.fused_confidence(1u, 1.0f, 0.8, &fused) != aether::core::Status::kOk) {
        std::fprintf(stderr, "fused_confidence failed\n");
        failed++;
    } else if (!(fused >= 0.0 && fused <= 1.0)) {
        std::fprintf(stderr, "fused confidence should stay in [0,1]\n");
        failed++;
    }

    return failed;
}

int test_collect_and_invalid() {
    int failed = 0;
    using namespace aether::innovation;

    std::vector<GaussianPrimitive> gaussians;
    gaussians.push_back(make_gaussian(1u, 0.2f));
    gaussians.push_back(make_gaussian(2u, 0.9f));
    gaussians.push_back(make_gaussian(3u, 0.7f));
    gaussians[2].patch_priority = 2u;

    std::vector<std::uint32_t> out;
    if (f8_collect_high_uncertainty_indices(
            gaussians.data(), gaussians.size(), 0.7f, &out) != aether::core::Status::kOk) {
        std::fprintf(stderr, "collect_high_uncertainty failed\n");
        return 1;
    }
    if (out.size() != 2u || out[0] != 1u) {
        std::fprintf(stderr, "high-uncertainty ranking mismatch\n");
        failed++;
    }

    F8UncertaintyField field{};
    F8FrameStats stats{};
    if (field.process_frame(nullptr, 1u, gaussians.data(), gaussians.size(), &stats) != aether::core::Status::kInvalidArgument) {
        std::fprintf(stderr, "null observations with non-zero count should fail\n");
        failed++;
    }
    if (field.query_uncertainty(999u, 1.0f, nullptr) != aether::core::Status::kInvalidArgument) {
        std::fprintf(stderr, "null uncertainty output should fail\n");
        failed++;
    }

    return failed;
}

}  // namespace

int main() {
    int failed = 0;
    failed += test_update_and_view_dependence();
    failed += test_collect_and_invalid();
    return failed;
}
