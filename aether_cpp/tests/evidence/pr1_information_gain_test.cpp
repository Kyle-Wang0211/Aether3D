// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/evidence/pr1_information_gain.h"

#include <cmath>
#include <cstdio>
#include <cstdint>
#include <vector>

namespace {

bool approx(double a, double b, double eps = 1e-9) {
    return std::fabs(a - b) <= eps;
}

}  // namespace

int main() {
    using namespace aether::evidence;
    int failed = 0;

    PR1InformationGainConfig cfg{};
    constexpr int kGridSize = 128;
    cfg.coverage_grid_size = kGridSize;

    std::vector<std::uint8_t> grid(static_cast<std::size_t>(kGridSize) * static_cast<std::size_t>(kGridSize), 0u);

    PR1PatchDescriptor patch{};
    patch.coverage_x = 8;
    patch.coverage_y = 9;
    double info_gain = -1.0;
    if (pr1_compute_information_gain(patch, grid.data(), grid.size(), cfg, &info_gain) != aether::core::Status::kOk) {
        std::fprintf(stderr, "info gain compute failed on all-uncovered grid\n");
        failed++;
    } else if (!approx(info_gain, 0.72)) {
        std::fprintf(stderr, "unexpected info gain for all-uncovered grid: %.12f\n", info_gain);
        failed++;
    }

    const std::size_t center_idx =
        static_cast<std::size_t>(patch.coverage_y) * static_cast<std::size_t>(kGridSize) +
        static_cast<std::size_t>(patch.coverage_x);
    grid[center_idx] = static_cast<std::uint8_t>(PR1CoverageState::kWhite);
    if (pr1_compute_information_gain(patch, grid.data(), grid.size(), cfg, &info_gain) != aether::core::Status::kOk) {
        std::fprintf(stderr, "info gain compute failed on white-center grid\n");
        failed++;
    } else if (!(info_gain < 0.72 && info_gain >= 0.0)) {
        std::fprintf(stderr, "white-center info gain expected lower than uncovered, got %.12f\n", info_gain);
        failed++;
    }

    PR1InformationGainConfig entropy_cfg = cfg;
    entropy_cfg.info_gain_strategy = PR1InfoGainStrategy::kEntropyFrontier;
    double info_gain_entropy = -1.0;
    if (pr1_compute_information_gain(patch, grid.data(), grid.size(), entropy_cfg, &info_gain_entropy) !=
        aether::core::Status::kOk) {
        std::fprintf(stderr, "entropy info gain compute failed\n");
        failed++;
    } else if (info_gain_entropy + 1e-9 < info_gain) {
        std::fprintf(stderr, "entropy info gain expected >= legacy on sparse-white neighborhood\n");
        failed++;
    }

    PR1InformationGainConfig hybrid_cfg = cfg;
    hybrid_cfg.info_gain_strategy = PR1InfoGainStrategy::kHybridCrossCheck;
    double info_gain_hybrid = -1.0;
    if (pr1_compute_information_gain(patch, grid.data(), grid.size(), hybrid_cfg, &info_gain_hybrid) !=
        aether::core::Status::kOk) {
        std::fprintf(stderr, "hybrid info gain compute failed\n");
        failed++;
    } else if (!(info_gain_hybrid >= std::min(info_gain, info_gain_entropy) - 1e-9 &&
                 info_gain_hybrid <= std::max(info_gain, info_gain_entropy) + 1e-9)) {
        std::fprintf(stderr, "hybrid info gain expected bounded by legacy/entropy\n");
        failed++;
    }

    PR1PatchDescriptor existing{};
    existing.pose_x = patch.pose_x;
    existing.pose_y = patch.pose_y;
    existing.pose_z = patch.pose_z;
    existing.coverage_x = patch.coverage_x;
    existing.coverage_y = patch.coverage_y;
    existing.radiance_x = patch.radiance_x;
    existing.radiance_y = patch.radiance_y;
    existing.radiance_z = patch.radiance_z;

    double novelty = -1.0;
    if (pr1_compute_novelty(patch, nullptr, 0u, cfg, &novelty) != aether::core::Status::kOk ||
        !approx(novelty, 1.0)) {
        std::fprintf(stderr, "novelty on empty set mismatch: %.12f\n", novelty);
        failed++;
    }

    if (pr1_compute_novelty(patch, &existing, 1u, cfg, &novelty) != aether::core::Status::kOk ||
        novelty > 0.05) {
        std::fprintf(stderr, "novelty on identical patch expected near zero, got %.12f\n", novelty);
        failed++;
    }

    existing.pose_x = 10.0f;
    existing.pose_y = 10.0f;
    existing.pose_z = 10.0f;
    existing.coverage_x = patch.coverage_x + 100;
    existing.coverage_y = patch.coverage_y + 100;
    existing.radiance_x = 1.0f;
    existing.radiance_y = 1.0f;
    existing.radiance_z = 1.0f;
    if (pr1_compute_novelty(patch, &existing, 1u, cfg, &novelty) != aether::core::Status::kOk ||
        novelty < 0.8) {
        std::fprintf(stderr, "novelty on far patch expected high, got %.12f\n", novelty);
        failed++;
    }

    PR1InformationGainConfig robust_cfg = cfg;
    robust_cfg.novelty_strategy = PR1NoveltyStrategy::kKernelRobust;
    double novelty_robust = -1.0;
    if (pr1_compute_novelty(patch, &existing, 1u, robust_cfg, &novelty_robust) != aether::core::Status::kOk ||
        novelty_robust < 0.0 || novelty_robust > 1.0) {
        std::fprintf(stderr, "robust novelty expected in [0,1], got %.12f\n", novelty_robust);
        failed++;
    }

    PR1InformationGainConfig hybrid_novelty_cfg = cfg;
    hybrid_novelty_cfg.novelty_strategy = PR1NoveltyStrategy::kHybridCrossCheck;
    double novelty_hybrid = -1.0;
    if (pr1_compute_novelty(patch, &existing, 1u, hybrid_novelty_cfg, &novelty_hybrid) !=
        aether::core::Status::kOk) {
        std::fprintf(stderr, "hybrid novelty compute failed\n");
        failed++;
    } else if (!(novelty_hybrid >= std::min(novelty, novelty_robust) - 1e-9 &&
                 novelty_hybrid <= std::max(novelty, novelty_robust) + 1e-9)) {
        std::fprintf(stderr, "hybrid novelty expected bounded by legacy/robust\n");
        failed++;
    }

    if (pr1_compute_information_gain(patch, grid.data(), grid.size(), cfg, nullptr) != aether::core::Status::kInvalidArgument) {
        std::fprintf(stderr, "expected invalid argument for null info gain output\n");
        failed++;
    }
    if (pr1_compute_novelty(patch, &existing, 1u, cfg, nullptr) != aether::core::Status::kInvalidArgument) {
        std::fprintf(stderr, "expected invalid argument for null novelty output\n");
        failed++;
    }

    return failed;
}
