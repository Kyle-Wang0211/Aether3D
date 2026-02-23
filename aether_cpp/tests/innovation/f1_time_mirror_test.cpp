// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/innovation/f1_time_mirror.h"

#include "aether/tsdf/block_index.h"

#include <cmath>
#include <cstdio>
#include <vector>

namespace {

bool approx(float a, float b, float eps) {
    return std::fabs(a - b) <= eps;
}

std::vector<aether::innovation::ScaffoldVertex> make_vertices() {
    using namespace aether::innovation;
    std::vector<ScaffoldVertex> out(4);
    out[0].id = 0u;
    out[0].position = make_float3(0.0f, 0.0f, 2.0f);
    out[1].id = 1u;
    out[1].position = make_float3(1.0f, 0.0f, 2.0f);
    out[2].id = 2u;
    out[2].position = make_float3(0.0f, 1.0f, 2.0f);
    out[3].id = 3u;
    out[3].position = make_float3(1.0f, 1.0f, 2.0f);
    return out;
}

std::vector<aether::innovation::ScaffoldUnit> make_units() {
    using namespace aether::innovation;
    std::vector<ScaffoldUnit> out(2);
    out[0].unit_id = 1001u;
    out[0].v0 = 0u;
    out[0].v1 = 1u;
    out[0].v2 = 2u;
    out[0].area = 0.2f;
    out[0].normal = make_float3(0.0f, 0.0f, 1.0f);
    out[1].unit_id = 1002u;
    out[1].v0 = 1u;
    out[1].v1 = 3u;
    out[1].v2 = 2u;
    out[1].area = 1.0f;
    out[1].normal = make_float3(0.0f, 0.0f, 1.0f);
    return out;
}

std::vector<aether::innovation::GaussianPrimitive> make_gaussians() {
    using namespace aether::innovation;
    std::vector<GaussianPrimitive> out(4);
    for (std::size_t i = 0u; i < out.size(); ++i) {
        out[i].id = static_cast<std::uint32_t>(10u + i);
        out[i].position = make_float3(0.2f + static_cast<float>(i) * 0.1f, 0.2f, 2.0f);
        out[i].scale = make_float3(0.03f, 0.03f, 0.03f);
        out[i].opacity = 0.8f;
        out[i].host_unit_id = (i < 2u) ? 1001u : 1002u;
        out[i].first_observed_frame_id = (i < 2u) ? 100u : 120u;
        out[i].first_observed_ms = (i < 2u) ? 1000 : 1200;
        out[i].capture_sequence = static_cast<std::uint32_t>(i);
        out[i].patch_priority = 0u;
        out[i].patch_id = (i < 2u) ? "p0" : "p1";
        out[i].sh_coeffs[0] = 0.5f;
        for (std::size_t c = 1u; c < out[i].sh_coeffs.size(); ++c) {
            out[i].sh_coeffs[c] = 0.2f;
        }
    }
    return out;
}

std::vector<aether::innovation::CameraTrajectoryEntry> make_trajectory() {
    using namespace aether::innovation;
    std::vector<CameraTrajectoryEntry> out(2);
    out[0].frame_id = 100u;
    out[0].pose.position = make_float3(-0.5f, 0.0f, 1.8f);
    out[0].pose.forward = make_float3(0.5f, 0.0f, 1.0f);
    out[0].pose.up = make_float3(0.0f, 1.0f, 0.0f);
    out[0].timestamp_ms = 1000;
    out[1].frame_id = 120u;
    out[1].pose.position = make_float3(1.5f, 0.2f, 1.8f);
    out[1].pose.forward = make_float3(-0.5f, 0.0f, 1.0f);
    out[1].pose.up = make_float3(0.0f, 1.0f, 0.0f);
    out[1].timestamp_ms = 1200;
    return out;
}

int test_fragment_queue_build() {
    int failed = 0;
    using namespace aether::innovation;

    const auto units = make_units();
    const auto vertices = make_vertices();
    const auto gaussians = make_gaussians();
    const auto trajectory = make_trajectory();

    ScaffoldPatchMap patch_map{};
    patch_map.upsert_unit(units[0], aether::tsdf::BlockIndex{0, 0, 0});
    patch_map.upsert_unit(units[1], aether::tsdf::BlockIndex{1, 0, 0});
    patch_map.bind_from_primitives(gaussians.data(), gaussians.size());

    F1TimeMirrorConfig config{};
    std::vector<FragmentFlightParams> fragments;
    const auto status = f1_build_fragment_queue(
        units.data(),
        units.size(),
        vertices.data(),
        vertices.size(),
        gaussians.data(),
        gaussians.size(),
        &patch_map,
        trajectory.data(),
        trajectory.size(),
        config,
        &fragments);
    if (status != aether::core::Status::kOk) {
        std::fprintf(stderr, "f1_build_fragment_queue failed\n");
        return 1;
    }
    if (fragments.size() != 2u) {
        std::fprintf(stderr, "unexpected fragment count\n");
        failed++;
    }
    if (fragments.size() >= 2u && fragments[0].first_observed_ms > fragments[1].first_observed_ms) {
        std::fprintf(stderr, "fragments must be sorted by observed time\n");
        failed++;
    }
    if (fragments.size() >= 1u && fragments[0].gaussian_count != 2u) {
        std::fprintf(stderr, "fragment gaussian count mismatch\n");
        failed++;
    }
    return failed;
}

int test_priority_boost_reorders_fragments() {
    int failed = 0;
    using namespace aether::innovation;

    const auto units = make_units();
    const auto vertices = make_vertices();
    auto gaussians = make_gaussians();
    const auto trajectory = make_trajectory();

    // Mark the second fragment as "retake" so it should appear first even
    // though it was observed later.
    gaussians[2].patch_priority = 100u;
    gaussians[3].patch_priority = 100u;
    gaussians[2].capture_sequence = 999u;
    gaussians[3].capture_sequence = 1000u;

    ScaffoldPatchMap patch_map{};
    patch_map.upsert_unit(units[0], aether::tsdf::BlockIndex{0, 0, 0});
    patch_map.upsert_unit(units[1], aether::tsdf::BlockIndex{1, 0, 0});
    patch_map.bind_from_primitives(gaussians.data(), gaussians.size());

    F1TimeMirrorConfig config{};
    std::vector<FragmentFlightParams> fragments;
    if (f1_build_fragment_queue(
            units.data(),
            units.size(),
            vertices.data(),
            vertices.size(),
            gaussians.data(),
            gaussians.size(),
            &patch_map,
            trajectory.data(),
            trajectory.size(),
            config,
            &fragments) != aether::core::Status::kOk) {
        std::fprintf(stderr, "build queue with priority boost failed\n");
        return 1;
    }
    if (fragments.size() != 2u) {
        std::fprintf(stderr, "unexpected fragment count in priority test\n");
        return 1;
    }
    if (fragments[0].unit_id != 1002u) {
        std::fprintf(stderr, "priority boosted fragment should be rendered first\n");
        failed++;
    }
    if (!(fragments[0].appear_offset_s <= fragments[1].appear_offset_s)) {
        std::fprintf(stderr, "priority boosted fragment should have earlier appear offset\n");
        failed++;
    }
    return failed;
}

int test_animate_frame() {
    int failed = 0;
    using namespace aether::innovation;

    const auto units = make_units();
    const auto vertices = make_vertices();
    const auto gaussians = make_gaussians();
    const auto trajectory = make_trajectory();

    ScaffoldPatchMap patch_map{};
    patch_map.upsert_unit(units[0], aether::tsdf::BlockIndex{0, 0, 0});
    patch_map.upsert_unit(units[1], aether::tsdf::BlockIndex{1, 0, 0});
    patch_map.bind_from_primitives(gaussians.data(), gaussians.size());

    F1TimeMirrorConfig config{};
    std::vector<FragmentFlightParams> fragments;
    if (f1_build_fragment_queue(
            units.data(),
            units.size(),
            vertices.data(),
            vertices.size(),
            gaussians.data(),
            gaussians.size(),
            &patch_map,
            trajectory.data(),
            trajectory.size(),
            config,
            &fragments) != aether::core::Status::kOk) {
        std::fprintf(stderr, "failed to build queue for animation test\n");
        return 1;
    }

    float total_time = 0.0f;
    for (const auto& f : fragments) {
        total_time = std::max(total_time, f.appear_offset_s + f.flight_duration_s);
    }

    std::vector<GaussianPrimitive> frame0;
    F1AnimationMetrics metrics0{};
    if (f1_animate_frame(
            gaussians.data(),
            gaussians.size(),
            fragments.data(),
            fragments.size(),
            &patch_map,
            config,
            0.0f,
            total_time,
            &frame0,
            &metrics0) != aether::core::Status::kOk) {
        std::fprintf(stderr, "f1_animate_frame at t=0 failed\n");
        return 1;
    }
    if (frame0.size() != gaussians.size()) {
        std::fprintf(stderr, "animated frame size mismatch\n");
        failed++;
    }
    if (metrics0.hidden_gaussian_count == 0u) {
        std::fprintf(stderr, "expected hidden gaussians at t=0\n");
        failed++;
    }

    std::vector<GaussianPrimitive> frame_end;
    F1AnimationMetrics metrics_end{};
    if (f1_animate_frame(
            gaussians.data(),
            gaussians.size(),
            fragments.data(),
            fragments.size(),
            &patch_map,
            config,
            total_time,
            total_time,
            &frame_end,
            &metrics_end) != aether::core::Status::kOk) {
        std::fprintf(stderr, "f1_animate_frame at t=end failed\n");
        return failed + 1;
    }
    for (std::size_t i = 0u; i < gaussians.size(); ++i) {
        if (!approx(frame_end[i].position.x, gaussians[i].position.x, 1e-4f) ||
            !approx(frame_end[i].position.y, gaussians[i].position.y, 1e-4f) ||
            !approx(frame_end[i].position.z, gaussians[i].position.z, 1e-4f)) {
            std::fprintf(stderr, "final frame position mismatch at %zu\n", i);
            failed++;
            break;
        }
        if (!approx(frame_end[i].opacity, gaussians[i].opacity, 1e-4f)) {
            std::fprintf(stderr, "final frame opacity mismatch at %zu\n", i);
            failed++;
            break;
        }
    }
    if (!approx(metrics_end.completion_ratio, 1.0f, 1e-4f)) {
        std::fprintf(stderr, "completion ratio mismatch at end\n");
        failed++;
    }

    std::vector<GaussianPrimitive> frame_mid;
    F1AnimationMetrics metrics_mid{};
    if (f1_animate_frame(
            gaussians.data(),
            gaussians.size(),
            fragments.data(),
            fragments.size(),
            &patch_map,
            config,
            0.5f * total_time,
            total_time,
            &frame_mid,
            &metrics_mid) != aether::core::Status::kOk) {
        std::fprintf(stderr, "f1_animate_frame at t=mid failed\n");
        return failed + 1;
    }
    bool any_moved = false;
    for (std::size_t i = 0u; i < gaussians.size(); ++i) {
        if (!approx(frame_mid[i].position.x, gaussians[i].position.x, 1e-4f) ||
            !approx(frame_mid[i].position.y, gaussians[i].position.y, 1e-4f) ||
            !approx(frame_mid[i].position.z, gaussians[i].position.z, 1e-4f)) {
            any_moved = true;
            break;
        }
    }
    if (!any_moved) {
        std::fprintf(stderr, "mid frame should move at least one gaussian\n");
        failed++;
    }
    return failed;
}

}  // namespace

int main() {
    int failed = 0;
    failed += test_fragment_queue_build();
    failed += test_priority_boost_reorders_fragments();
    failed += test_animate_frame();
    return failed;
}
