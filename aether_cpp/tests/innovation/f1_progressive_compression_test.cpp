// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/innovation/f1_progressive_compression.h"

#include <cmath>
#include <cstdio>
#include <vector>

namespace {

bool approx(float a, float b, float eps) {
    return std::fabs(a - b) <= eps;
}

std::vector<aether::innovation::ScaffoldUnit> make_units() {
    using aether::innovation::ScaffoldUnit;
    std::vector<ScaffoldUnit> units;
    units.resize(4);

    units[0].unit_id = 1001u;
    units[0].area = 0.1f;
    units[1].unit_id = 1002u;
    units[1].area = 0.8f;
    units[2].unit_id = 1003u;
    units[2].area = 2.0f;
    units[3].unit_id = 1004u;
    units[3].area = 5.0f;
    return units;
}

std::vector<aether::innovation::GaussianPrimitive> make_gaussians() {
    using aether::innovation::GaussianPrimitive;
    using aether::innovation::make_float3;

    std::vector<GaussianPrimitive> gaussians;
    gaussians.resize(6);
    for (std::size_t i = 0; i < gaussians.size(); ++i) {
        auto& g = gaussians[i];
        g.id = static_cast<std::uint32_t>(40u + i);
        g.position = make_float3(
            -1.5f + static_cast<float>(i) * 0.4f,
            0.2f + static_cast<float>(i) * 0.1f,
            2.0f - static_cast<float>(i) * 0.15f);
        g.scale = make_float3(
            0.02f + static_cast<float>(i) * 0.01f,
            0.03f + static_cast<float>(i) * 0.01f,
            0.04f + static_cast<float>(i) * 0.01f);
        g.opacity = 0.25f + static_cast<float>(i) * 0.1f;
        g.observation_count = static_cast<std::uint16_t>(3u + i);
        g.patch_priority = 0u;
        g.capture_sequence = static_cast<std::uint32_t>(10u + i);
        g.flags = (i % 2u == 0u) ? 0x0u : 0x1u;
        g.uncertainty = 0.05f + static_cast<float>(i) * 0.05f;
        g.host_unit_id = 1001u + static_cast<std::uint64_t>(i % 4u);
        for (std::size_t c = 0; c < g.sh_coeffs.size(); ++c) {
            g.sh_coeffs[c] = (static_cast<float>(c) * 0.03f) - 0.5f + static_cast<float>(i) * 0.02f;
        }
    }
    return gaussians;
}

int test_hierarchy_and_budget() {
    int failed = 0;
    using namespace aether::innovation;

    const auto units = make_units();
    const auto gaussians = make_gaussians();

    ProgressiveCompressionConfig cfg{};
    cfg.level_count = 3u;
    cfg.area_gamma = 1.0f;
    cfg.capture_order_priority = true;
    cfg.sh_coeff_count = 8u;

    ProgressiveHierarchy hierarchy{};
    const auto st = f1_build_progressive_hierarchy(
        units.data(),
        units.size(),
        gaussians.data(),
        gaussians.size(),
        nullptr,
        cfg,
        &hierarchy);
    if (st != aether::core::Status::kOk) {
        std::fprintf(stderr, "f1_build_progressive_hierarchy failed\n");
        return 1;
    }
    if (hierarchy.levels.size() != 3u) {
        std::fprintf(stderr, "unexpected level count\n");
        failed++;
    }
    if (!(hierarchy.levels[0].gaussian_indices.size() <= hierarchy.levels[1].gaussian_indices.size() &&
          hierarchy.levels[1].gaussian_indices.size() <= hierarchy.levels[2].gaussian_indices.size())) {
        std::fprintf(stderr, "levels must be progressive supersets\n");
        failed++;
    }
    if (!hierarchy.scene_bounds.valid) {
        std::fprintf(stderr, "scene bounds must be valid\n");
        failed++;
    }

    std::uint32_t selected = 0u;
    const auto budget_status = f1_select_level_for_budget(
        hierarchy,
        hierarchy.levels.back().estimated_bytes,
        &selected);
    if (budget_status != aether::core::Status::kOk || selected != 2u) {
        std::fprintf(stderr, "budget selection should pick highest level\n");
        failed++;
    }

    selected = 999u;
    const auto under_budget = f1_select_level_for_budget(hierarchy, 8u, &selected);
    if (under_budget != aether::core::Status::kOutOfRange || selected != 0u) {
        std::fprintf(stderr, "under budget should clamp to level 0 with OutOfRange\n");
        failed++;
    }
    return failed;
}

int test_roundtrip_and_determinism() {
    int failed = 0;
    using namespace aether::innovation;

    const auto units = make_units();
    auto gaussians = make_gaussians();
    gaussians[0].id = 0xF2345678u;
    gaussians[0].capture_sequence = 0xF0000001u;
    gaussians[1].id = 0x81234567u;
    gaussians[1].capture_sequence = 0x92345678u;

    ProgressiveCompressionConfig cfg{};
    cfg.level_count = 3u;
    cfg.capture_order_priority = true;
    cfg.sh_coeff_count = 8u;
    cfg.quant_bits_position = 16u;
    cfg.quant_bits_scale = 16u;
    cfg.quant_bits_opacity = 8u;
    cfg.quant_bits_uncertainty = 12u;

    ProgressiveHierarchy hierarchy{};
    if (f1_build_progressive_hierarchy(
            units.data(),
            units.size(),
            gaussians.data(),
            gaussians.size(),
            nullptr,
            cfg,
            &hierarchy) != aether::core::Status::kOk) {
        std::fprintf(stderr, "failed to build hierarchy for roundtrip\n");
        return 1;
    }

    ProgressiveEncodedLevel encoded_a{};
    ProgressiveEncodedLevel encoded_b{};
    if (f1_encode_level(
            gaussians.data(),
            gaussians.size(),
            hierarchy,
            2u,
            cfg,
            &encoded_a) != aether::core::Status::kOk) {
        std::fprintf(stderr, "encode A failed\n");
        return 1;
    }
    if (f1_encode_level(
            gaussians.data(),
            gaussians.size(),
            hierarchy,
            2u,
            cfg,
            &encoded_b) != aether::core::Status::kOk) {
        std::fprintf(stderr, "encode B failed\n");
        return 1;
    }
    if (encoded_a.bytes != encoded_b.bytes) {
        std::fprintf(stderr, "encoding must be deterministic\n");
        failed++;
    }

    std::vector<GaussianPrimitive> decoded;
    if (f1_decode_level(encoded_a, &decoded) != aether::core::Status::kOk) {
        std::fprintf(stderr, "decode failed\n");
        return failed + 1;
    }
    if (decoded.size() != hierarchy.levels[2].gaussian_indices.size()) {
        std::fprintf(stderr, "decoded gaussian count mismatch\n");
        failed++;
    }

    for (std::size_t i = 0; i < decoded.size(); ++i) {
        const auto source_idx = hierarchy.levels[2].gaussian_indices[i];
        const auto& src = gaussians[source_idx];
        const auto& out = decoded[i];
        if (src.id != out.id || src.host_unit_id != out.host_unit_id ||
            src.observation_count != out.observation_count || src.flags != out.flags ||
            src.patch_priority != out.patch_priority || src.capture_sequence != out.capture_sequence) {
            std::fprintf(stderr, "roundtrip metadata mismatch at %zu\n", i);
            failed++;
        }
        if (!approx(src.position.x, out.position.x, 1e-3f) ||
            !approx(src.position.y, out.position.y, 1e-3f) ||
            !approx(src.position.z, out.position.z, 1e-3f)) {
            std::fprintf(stderr, "roundtrip position mismatch at %zu\n", i);
            failed++;
        }
        if (!approx(src.scale.x, out.scale.x, 1e-3f) ||
            !approx(src.scale.y, out.scale.y, 1e-3f) ||
            !approx(src.scale.z, out.scale.z, 1e-3f)) {
            std::fprintf(stderr, "roundtrip scale mismatch at %zu\n", i);
            failed++;
        }
        if (!approx(src.opacity, out.opacity, 3e-3f)) {
            std::fprintf(stderr, "roundtrip opacity mismatch at %zu\n", i);
            failed++;
        }
        if (!approx(src.uncertainty, out.uncertainty, 2e-2f)) {
            std::fprintf(stderr, "roundtrip uncertainty mismatch at %zu\n", i);
            failed++;
        }
        for (std::uint32_t c = 0u; c < cfg.sh_coeff_count; ++c) {
            if (!approx(src.sh_coeffs[c], out.sh_coeffs[c], 0.04f)) {
                std::fprintf(stderr, "roundtrip SH mismatch at %zu coeff %u\n", i, c);
                failed++;
                break;
            }
        }
    }
    return failed;
}

int test_capture_order_queue() {
    int failed = 0;
    using namespace aether::innovation;

    const auto units = make_units();
    auto gaussians = make_gaussians();
    gaussians[2].capture_sequence = 3u;
    gaussians[3].capture_sequence = 4u;
    gaussians[5].capture_sequence = 5u;
    gaussians[3].patch_priority = 2u;  // simulate reshoot front-load.
    gaussians[2].patch_priority = 1u;

    ProgressiveCompressionConfig cfg{};
    cfg.level_count = 3u;
    cfg.capture_order_priority = true;
    cfg.sh_coeff_count = 8u;

    ProgressiveHierarchy hierarchy{};
    if (f1_build_progressive_hierarchy(
            units.data(),
            units.size(),
            gaussians.data(),
            gaussians.size(),
            nullptr,
            cfg,
            &hierarchy) != aether::core::Status::kOk) {
        std::fprintf(stderr, "failed to build hierarchy for queue test\n");
        return 1;
    }

    std::vector<F1RenderQueueEntry> queue;
    if (f1_build_capture_order_queue(
            hierarchy,
            gaussians.data(),
            gaussians.size(),
            2u,
            &queue) != aether::core::Status::kOk) {
        std::fprintf(stderr, "failed to build capture-order queue\n");
        return 1;
    }
    if (queue.size() != hierarchy.levels[2].gaussian_indices.size()) {
        std::fprintf(stderr, "queue size mismatch\n");
        failed++;
    }
    if (queue.size() >= 2u) {
        const auto& first = gaussians[queue[0].gaussian_index];
        const auto& second = gaussians[queue[1].gaussian_index];
        if (!(first.patch_priority >= second.patch_priority)) {
            std::fprintf(stderr, "queue must prioritize patch priority\n");
            failed++;
        }
    }
    for (std::size_t i = 1; i < queue.size(); ++i) {
        const auto& prev = queue[i - 1u];
        const auto& curr = queue[i];
        if (prev.patch_priority == curr.patch_priority &&
            prev.capture_sequence > curr.capture_sequence) {
            std::fprintf(stderr, "queue capture sequence order violation\n");
            failed++;
            break;
        }
    }

    return failed;
}

int test_capture_order_queue_patch_map_resolution() {
    int failed = 0;
    using namespace aether::innovation;

    const auto units = make_units();
    auto gaussians = make_gaussians();
    gaussians[0].host_unit_id = 0u;
    gaussians[0].patch_id = "patch0";

    ScaffoldPatchMap patch_map{};
    ScaffoldUnit mapped_unit{};
    mapped_unit.unit_id = 1003u;
    mapped_unit.patch_id = "patch0";
    const aether::tsdf::BlockIndex block_index{1, 2, 3};
    if (patch_map.upsert_unit(mapped_unit, block_index) != aether::core::Status::kOk) {
        std::fprintf(stderr, "patch map bind failed\n");
        return 1;
    }

    ProgressiveCompressionConfig cfg{};
    cfg.level_count = 3u;
    cfg.capture_order_priority = true;
    cfg.sh_coeff_count = 8u;

    ProgressiveHierarchy hierarchy{};
    if (f1_build_progressive_hierarchy(
            units.data(),
            units.size(),
            gaussians.data(),
            gaussians.size(),
            &patch_map,
            cfg,
            &hierarchy) != aether::core::Status::kOk) {
        std::fprintf(stderr, "failed to build hierarchy for patch-map queue test\n");
        return 1;
    }

    std::vector<F1RenderQueueEntry> queue;
    if (f1_build_capture_order_queue(
            hierarchy,
            gaussians.data(),
            gaussians.size(),
            2u,
            &queue,
            &patch_map) != aether::core::Status::kOk) {
        std::fprintf(stderr, "failed to build capture-order queue with patch map\n");
        return 1;
    }

    bool found = false;
    for (const auto& entry : queue) {
        if (entry.gaussian_id == gaussians[0].id) {
            found = true;
            if (entry.host_unit_id != 1003u) {
                std::fprintf(stderr, "queue patch-map host unit resolution mismatch\n");
                failed++;
            }
            break;
        }
    }
    if (!found) {
        std::fprintf(stderr, "queue missing patched gaussian entry\n");
        failed++;
    }

    return failed;
}

int test_invalid_paths() {
    int failed = 0;
    using namespace aether::innovation;

    const auto units = make_units();
    const auto gaussians = make_gaussians();
    ProgressiveCompressionConfig cfg{};
    cfg.sh_coeff_count = 8u;

    if (f1_build_progressive_hierarchy(
            units.data(),
            units.size(),
            gaussians.data(),
            gaussians.size(),
            nullptr,
            cfg,
            nullptr) != aether::core::Status::kInvalidArgument) {
        std::fprintf(stderr, "null output hierarchy must fail\n");
        failed++;
    }

    ProgressiveHierarchy hierarchy{};
    if (f1_build_progressive_hierarchy(
            units.data(),
            units.size(),
            gaussians.data(),
            gaussians.size(),
            nullptr,
            cfg,
            &hierarchy) != aether::core::Status::kOk) {
        std::fprintf(stderr, "hierarchy build for invalid path test failed\n");
        return failed + 1;
    }

    ProgressiveEncodedLevel encoded{};
    if (f1_encode_level(
            gaussians.data(),
            gaussians.size(),
            hierarchy,
            99u,
            cfg,
            &encoded) != aether::core::Status::kInvalidArgument) {
        std::fprintf(stderr, "invalid level index must fail\n");
        failed++;
    }

    encoded.bytes.assign(4u, 0u);
    std::vector<GaussianPrimitive> out;
    if (f1_decode_level(encoded, &out) != aether::core::Status::kOutOfRange) {
        std::fprintf(stderr, "short payload must fail decode\n");
        failed++;
    }
    return failed;
}

}  // namespace

int main() {
    int failed = 0;
    failed += test_hierarchy_and_budget();
    failed += test_roundtrip_and_determinism();
    failed += test_capture_order_queue();
    failed += test_capture_order_queue_patch_map_resolution();
    failed += test_invalid_paths();
    return failed;
}
