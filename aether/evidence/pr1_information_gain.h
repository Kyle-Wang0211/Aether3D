// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_EVIDENCE_PR1_INFORMATION_GAIN_H
#define AETHER_EVIDENCE_PR1_INFORMATION_GAIN_H

#include "aether/core/status.h"

#include <cstddef>
#include <cstdint>

namespace aether {
namespace evidence {

enum class PR1CoverageState : std::uint8_t {
    kUncovered = 0u,
    kGray = 1u,
    kWhite = 2u,
};

enum class PR1InfoGainStrategy : std::uint8_t {
    // Backward-compatible policy: state + frontier only.
    kLegacy = 0u,
    // Active-view style policy: state + frontier + local entropy + rarity.
    kEntropyFrontier = 1u,
    // Safety policy: blends legacy and entropy methods with disagreement damping.
    kHybridCrossCheck = 2u,
};

enum class PR1NoveltyStrategy : std::uint8_t {
    // Backward-compatible nearest-neighbor linear dissimilarity.
    kLegacy = 0u,
    // Robust-kernel novelty with percentile selection.
    kKernelRobust = 1u,
    // Safety policy: blends legacy and robust methods with disagreement damping.
    kHybridCrossCheck = 2u,
};

struct PR1PatchDescriptor {
    float pose_x{0.0f};
    float pose_y{0.0f};
    float pose_z{0.0f};
    std::int32_t coverage_x{0};
    std::int32_t coverage_y{0};
    float radiance_x{0.0f};
    float radiance_y{0.0f};
    float radiance_z{0.0f};
};

struct PR1InformationGainConfig {
    std::int32_t coverage_grid_size{128};
    double state_gain_uncovered{1.0};
    double state_gain_gray{0.45};
    double state_gain_white{0.08};
    double state_weight{0.72};
    double frontier_weight{0.28};
    double entropy_weight{0.12};
    double rarity_weight{0.08};
    double pose_eps{0.01};
    double robust_quantile{0.25};
    double robustness_scale{0.35};
    double hybrid_agreement_tolerance{0.20};
    double hybrid_high_weight{0.50};
    PR1InfoGainStrategy info_gain_strategy{PR1InfoGainStrategy::kLegacy};
    PR1NoveltyStrategy novelty_strategy{PR1NoveltyStrategy::kLegacy};
};

core::Status pr1_compute_information_gain(
    const PR1PatchDescriptor& patch,
    const std::uint8_t* coverage_grid_states,
    std::size_t coverage_grid_count,
    const PR1InformationGainConfig& config,
    double* out_info_gain);

core::Status pr1_compute_novelty(
    const PR1PatchDescriptor& patch,
    const PR1PatchDescriptor* existing_patches,
    std::size_t existing_count,
    const PR1InformationGainConfig& config,
    double* out_novelty);

}  // namespace evidence
}  // namespace aether

#endif  // AETHER_EVIDENCE_PR1_INFORMATION_GAIN_H
