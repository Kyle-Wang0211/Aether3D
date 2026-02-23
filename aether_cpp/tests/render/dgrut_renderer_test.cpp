// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/render/dgrut_renderer.h"

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <vector>

namespace {

float reference_score(const aether::render::DGRUTSplat& splat) {
    const float confidence = splat.tri_tet_confidence < 0.0f ? 0.0f : splat.tri_tet_confidence;
    const float opacity = splat.opacity < 0.0f ? 0.0f : splat.opacity;
    const float radius = splat.radius < 0.0f ? 0.0f : splat.radius;
    const float depth_penalty = splat.depth > 0.0f ? splat.depth * 8e-4f : 0.0f;
    const float view_factor = splat.view_cosine > 0.0f ? splat.view_cosine : 0.0f;
    const float screen = splat.screen_coverage < 0.0f ? 0.0f : splat.screen_coverage;
    float newborn = 0.0f;
    if (splat.frames_since_birth < 30u) {
        newborn = 0.15f * (1.0f - static_cast<float>(splat.frames_since_birth) / 30.0f);
    }
    return confidence * 0.50f +
        opacity * 0.20f +
        radius * 0.10f +
        view_factor * 0.10f +
        screen * 0.08f +
        newborn -
        depth_penalty;
}

bool better_ref(const aether::render::DGRUTSplat& lhs, const aether::render::DGRUTSplat& rhs) {
    const float lhs_score = reference_score(lhs);
    const float rhs_score = reference_score(rhs);
    if (lhs_score == rhs_score) {
        return lhs.id < rhs.id;
    }
    return lhs_score > rhs_score;
}

float confidence_average(
    const aether::render::DGRUTSplat* splats,
    std::size_t count) {
    if (count == 0u) {
        return 0.0f;
    }
    float sum = 0.0f;
    for (std::size_t i = 0u; i < count; ++i) {
        sum += splats[i].tri_tet_confidence;
    }
    return sum / static_cast<float>(count);
}

std::uint32_t lcg_next(std::uint32_t& state) {
    state = state * 1664525u + 1013904223u;
    return state;
}

}  // namespace

int main() {
    int failed = 0;

    const aether::render::DGRUTSplat input[4] = {
        {10u, 4.0f, 0.4f, 0.8f, 0.6f, 1.0f, 0.2f, 100u},
        {11u, 3.0f, 0.9f, 1.1f, 0.95f, 1.0f, 0.3f, 100u},
        {12u, 2.0f, 0.6f, 0.5f, 0.8f, 1.0f, 0.2f, 100u},
        {13u, 7.0f, 0.2f, 0.4f, 0.3f, 1.0f, 0.1f, 100u},
    };

    aether::render::DGRUTBudget budget{};
    budget.max_splats = 2;
    budget.max_bytes = sizeof(input);

    aether::render::DGRUTSplat output[2]{};
    aether::render::DGRUTSelectionResult result{};
    const auto status = aether::render::select_dgrut_splats(
        input,
        4,
        budget,
        output,
        2,
        &result);

    if (status != aether::core::Status::kOk) {
        std::fprintf(stderr, "select_dgrut_splats returned non-ok status\n");
        failed++;
    }
    if (result.selected_count != 2) {
        std::fprintf(stderr, "selected_count mismatch\n");
        failed++;
    }
    if (output[0].id != 11u) {
        std::fprintf(stderr, "top-ranked splat must be deterministic (id=11)\n");
        failed++;
    }
    if (!(result.mean_opacity > 0.0f)) {
        std::fprintf(stderr, "mean opacity must stay positive\n");
        failed++;
    }

    // KHR forward-compat conversion + selection path.
    aether::render::KHRGaussianSplat khr_input[4]{};
    aether::render::DGRUTSplat roundtrip[4]{};
    const std::uint32_t khr_ids[4] = {10u, 11u, 12u, 13u};
    if (aether::render::dgrut_to_khr_gaussian_splats(input, 4u, khr_input, 4u) != aether::core::Status::kOk) {
        std::fprintf(stderr, "dgrut_to_khr_gaussian_splats failed\n");
        failed++;
    }
    if (aether::render::khr_to_dgrut_splats(khr_input, khr_ids, 4u, roundtrip, 4u) != aether::core::Status::kOk) {
        std::fprintf(stderr, "khr_to_dgrut_splats failed\n");
        failed++;
    }
    if (roundtrip[1].id != 11u) {
        std::fprintf(stderr, "khr roundtrip id mismatch\n");
        failed++;
    }
    if (!(roundtrip[1].radius > 0.0f)) {
        std::fprintf(stderr, "khr roundtrip radius mismatch\n");
        failed++;
    }

    aether::render::KHRGaussianSplat khr_output[2]{};
    std::uint32_t selected_ids[2]{};
    aether::render::DGRUTSelectionResult khr_result{};
    const auto khr_status = aether::render::select_dgrut_splats_khr(
        khr_input,
        khr_ids,
        4u,
        budget,
        aether::render::DGRUTSelectionConfig{},
        khr_output,
        selected_ids,
        2u,
        &khr_result);
    if (khr_status != aether::core::Status::kOk) {
        std::fprintf(stderr, "select_dgrut_splats_khr failed\n");
        failed++;
    }
    if (khr_result.selected_count != 2u) {
        std::fprintf(stderr, "khr selected_count mismatch\n");
        failed++;
    }
    if (selected_ids[0] != 11u) {
        std::fprintf(stderr, "khr top-ranked id mismatch\n");
        failed++;
    }

    // Large-N regression test: accelerated partial selection must match
    // exact reference top-k ordering.
    std::vector<aether::render::DGRUTSplat> large_input;
    large_input.reserve(3000u);
    std::uint32_t rng = 123456789u;
    for (std::uint32_t i = 0u; i < 3000u; ++i) {
        const float depth = static_cast<float>((lcg_next(rng) % 3000u) + 1u);
        const float opacity_v = static_cast<float>(lcg_next(rng) % 1000u) / 1000.0f;
        const float radius_v = static_cast<float>(lcg_next(rng) % 1000u) / 700.0f;
        const float conf_v = static_cast<float>(lcg_next(rng) % 1000u) / 1000.0f;
        const float screen_cov = static_cast<float>(lcg_next(rng) % 1000u) / 1000.0f;
        large_input.push_back(
            aether::render::DGRUTSplat{i + 1000u, depth, opacity_v, radius_v, conf_v, 1.0f, screen_cov, 100u});
    }

    aether::render::DGRUTBudget large_budget{};
    large_budget.max_splats = 120u;
    large_budget.max_bytes = large_input.size() * sizeof(aether::render::DGRUTSplat);

    std::vector<aether::render::DGRUTSplat> large_output(large_budget.max_splats);
    aether::render::DGRUTSelectionResult large_result{};
    const auto large_status = aether::render::select_dgrut_splats(
        large_input.data(),
        large_input.size(),
        large_budget,
        large_output.data(),
        large_output.size(),
        &large_result);
    if (large_status != aether::core::Status::kOk) {
        std::fprintf(stderr, "large-N select_dgrut_splats failed\n");
        failed++;
        return failed;
    }

    std::vector<aether::render::DGRUTSplat> reference = large_input;
    std::stable_sort(reference.begin(), reference.end(), better_ref);
    if (large_result.selected_count != large_budget.max_splats) {
        std::fprintf(stderr, "large-N selected_count mismatch\n");
        failed++;
    }
    const std::size_t compare_count =
        large_result.selected_count < large_budget.max_splats ? large_result.selected_count : large_budget.max_splats;
    for (std::size_t i = 0u; i < compare_count; ++i) {
        if (large_output[i].id != reference[i].id) {
            std::fprintf(stderr, "large-N top-k mismatch at %zu\n", i);
            failed++;
            break;
        }
    }

    // Config A/B: B prioritizes tri-tet confidence more strongly.
    aether::render::DGRUTSelectionConfig config_a{};
    aether::render::DGRUTSelectionConfig config_b{};
    config_b.scoring.weight_confidence = 0.75f;
    config_b.scoring.weight_opacity = 0.20f;
    config_b.scoring.weight_radius = 0.05f;
    config_b.partial_select_min_input = 16u;
    config_b.partial_select_keep_ratio_threshold = 0.5f;

    const aether::render::DGRUTSplat ab_input[6] = {
        {21u, 1.0f, 0.95f, 1.1f, 0.20f, 1.0f, 0.1f, 100u},
        {22u, 1.0f, 0.90f, 0.9f, 0.30f, 1.0f, 0.1f, 100u},
        {23u, 1.0f, 0.50f, 0.8f, 0.85f, 1.0f, 0.1f, 100u},
        {24u, 1.0f, 0.45f, 0.7f, 0.88f, 1.0f, 0.1f, 100u},
        {25u, 1.0f, 0.35f, 0.6f, 0.92f, 1.0f, 0.1f, 100u},
        {26u, 1.0f, 0.30f, 0.5f, 0.94f, 1.0f, 0.1f, 100u},
    };
    aether::render::DGRUTBudget ab_budget{};
    ab_budget.max_splats = 3u;
    ab_budget.max_bytes = sizeof(ab_input);

    aether::render::DGRUTSplat out_a[3]{};
    aether::render::DGRUTSplat out_b[3]{};
    aether::render::DGRUTSelectionResult res_a{};
    aether::render::DGRUTSelectionResult res_b{};
    const auto ab_status_a = aether::render::select_dgrut_splats_with_config(
        ab_input, 6u, ab_budget, config_a, out_a, 3u, &res_a);
    const auto ab_status_b = aether::render::select_dgrut_splats_with_config(
        ab_input, 6u, ab_budget, config_b, out_b, 3u, &res_b);
    if (ab_status_a != aether::core::Status::kOk ||
        ab_status_b != aether::core::Status::kOk) {
        std::fprintf(stderr, "A/B selection call failed\n");
        failed++;
    } else {
        const float mean_conf_a = confidence_average(out_a, res_a.selected_count);
        const float mean_conf_b = confidence_average(out_b, res_b.selected_count);
        if (!(mean_conf_b >= mean_conf_a)) {
            std::fprintf(stderr, "A/B config should increase selected confidence\n");
            failed++;
        }
    }

    return failed;
}
