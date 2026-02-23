// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/evidence/pr1_information_gain.h"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <vector>

namespace aether {
namespace evidence {
namespace {

constexpr double kEps = 1e-9;
constexpr double kSqrt3 = 1.7320508075688772;

double clamp01(double value) {
    return std::max(0.0, std::min(1.0, value));
}

double clamp_non_negative(double value) {
    return std::max(0.0, value);
}

bool is_finite(double value) {
    return std::isfinite(value);
}

int positive_mod(int value, int modulus) {
    if (modulus <= 0) {
        return 0;
    }
    const int r = value % modulus;
    return r >= 0 ? r : r + modulus;
}

PR1CoverageState decode_state(std::uint8_t raw) {
    if (raw == static_cast<std::uint8_t>(PR1CoverageState::kGray)) {
        return PR1CoverageState::kGray;
    }
    if (raw == static_cast<std::uint8_t>(PR1CoverageState::kWhite)) {
        return PR1CoverageState::kWhite;
    }
    return PR1CoverageState::kUncovered;
}

struct NeighborhoodStats {
    double covered_ratio{0.0};
    double p_uncovered{1.0};
    double p_gray{0.0};
    double p_white{0.0};
};

NeighborhoodStats local_neighborhood_stats(int row, int col, const std::uint8_t* grid, int grid_size) {
    NeighborhoodStats stats{};
    int uncovered = 0;
    int gray = 0;
    int white = 0;
    int covered = 0;
    int total = 0;

    for (int dr = -1; dr <= 1; ++dr) {
        for (int dc = -1; dc <= 1; ++dc) {
            const int rr = row + dr;
            const int cc = col + dc;
            if (rr < 0 || rr >= grid_size || cc < 0 || cc >= grid_size) {
                continue;
            }
            ++total;
            const std::size_t idx = static_cast<std::size_t>(rr) * static_cast<std::size_t>(grid_size) +
                static_cast<std::size_t>(cc);
            const PR1CoverageState state = decode_state(grid[idx]);
            if (state == PR1CoverageState::kUncovered) {
                ++uncovered;
            } else if (state == PR1CoverageState::kGray) {
                ++gray;
            } else {
                ++white;
            }
            if (state != PR1CoverageState::kUncovered) {
                ++covered;
            }
        }
    }

    if (total <= 0) {
        return stats;
    }

    const double inv_total = 1.0 / static_cast<double>(total);
    stats.covered_ratio = static_cast<double>(covered) * inv_total;
    stats.p_uncovered = static_cast<double>(uncovered) * inv_total;
    stats.p_gray = static_cast<double>(gray) * inv_total;
    stats.p_white = static_cast<double>(white) * inv_total;
    return stats;
}

double shannon_entropy3(double p0, double p1, double p2) {
    double entropy = 0.0;
    const double probs[3] = {p0, p1, p2};
    for (double p : probs) {
        if (p > kEps) {
            entropy -= p * std::log(p);
        }
    }
    const double normalizer = std::log(3.0);
    return normalizer > 0.0 ? clamp01(entropy / normalizer) : 0.0;
}

double blend_with_disagreement_guard(
    double first,
    double second,
    const PR1InformationGainConfig& config) {
    const double low = std::min(first, second);
    const double high = std::max(first, second);
    const double diff = high - low;
    const double tolerance = std::max(config.hybrid_agreement_tolerance, 1e-6);
    const double trust = clamp01(1.0 - diff / (2.0 * tolerance));
    const double max_high_weight = clamp01(config.hybrid_high_weight);
    const double high_weight = clamp01(0.05 + trust * (max_high_weight - 0.05));
    return clamp01(low + (high - low) * high_weight);
}

double state_gain_for(PR1CoverageState state, const PR1InformationGainConfig& config) {
    if (state == PR1CoverageState::kUncovered) {
        return clamp01(config.state_gain_uncovered);
    }
    if (state == PR1CoverageState::kGray) {
        return clamp01(config.state_gain_gray);
    }
    return clamp01(config.state_gain_white);
}

double legacy_info_gain(
    PR1CoverageState center,
    const NeighborhoodStats& stats,
    const PR1InformationGainConfig& config) {
    const double state_gain = state_gain_for(center, config);
    const double frontier_gain = 1.0 - std::abs(stats.covered_ratio - 0.5) * 2.0;
    const double state_weight = clamp_non_negative(config.state_weight);
    const double frontier_weight = clamp_non_negative(config.frontier_weight);
    const double sum = state_weight + frontier_weight;
    if (sum <= kEps) {
        return clamp01(0.5 * (state_gain + frontier_gain));
    }
    return clamp01((state_weight * state_gain + frontier_weight * frontier_gain) / sum);
}

double entropy_frontier_info_gain(
    PR1CoverageState center,
    const NeighborhoodStats& stats,
    const PR1InformationGainConfig& config) {
    const double legacy = legacy_info_gain(center, stats, config);
    const double entropy = shannon_entropy3(stats.p_uncovered, stats.p_gray, stats.p_white);
    // Unknown/gray-heavy neighborhoods usually provide higher marginal gain.
    const double rarity = clamp01(stats.p_uncovered + 0.5 * stats.p_gray);

    const double entropy_weight = clamp_non_negative(config.entropy_weight);
    const double rarity_weight = clamp_non_negative(config.rarity_weight);
    const double legacy_weight = std::max(0.0, 1.0 - entropy_weight - rarity_weight);
    const double sum = legacy_weight + entropy_weight + rarity_weight;
    if (sum <= kEps) {
        return legacy;
    }
    return clamp01(
        (legacy_weight * legacy + entropy_weight * entropy + rarity_weight * rarity) /
        sum);
}

double robust_cauchy(double normalized_distance, double scale) {
    const double s = std::max(scale, 1e-6);
    const double x = clamp_non_negative(normalized_distance) / s;
    const double x2 = x * x;
    return clamp01(1.0 - 1.0 / (1.0 + x2));
}

double distance3(float ax, float ay, float az, float bx, float by, float bz) {
    const double dx = static_cast<double>(ax) - static_cast<double>(bx);
    const double dy = static_cast<double>(ay) - static_cast<double>(by);
    const double dz = static_cast<double>(az) - static_cast<double>(bz);
    return std::sqrt(dx * dx + dy * dy + dz * dz);
}

double quantile(std::vector<double>* values, double q) {
    if (values == nullptr || values->empty()) {
        return 1.0;
    }
    std::sort(values->begin(), values->end());
    const double qq = clamp01(q);
    const double pos = qq * static_cast<double>(values->size() - 1u);
    const std::size_t lo = static_cast<std::size_t>(std::floor(pos));
    const std::size_t hi = static_cast<std::size_t>(std::ceil(pos));
    if (lo == hi) {
        return (*values)[lo];
    }
    const double t = pos - static_cast<double>(lo);
    return (*values)[lo] * (1.0 - t) + (*values)[hi] * t;
}

double legacy_novelty(
    const PR1PatchDescriptor& patch,
    const PR1PatchDescriptor* existing_patches,
    std::size_t existing_count,
    const PR1InformationGainConfig& config) {
    if (existing_count == 0u) {
        return 1.0;
    }
    if (existing_patches == nullptr) {
        return 0.0;
    }

    const double pose_norm_scale = std::max(config.pose_eps * 8.0, 1e-9);
    double min_dissimilarity = 1.0;
    for (std::size_t i = 0u; i < existing_count; ++i) {
        const PR1PatchDescriptor& existing = existing_patches[i];
        const double pose_delta = distance3(
            patch.pose_x,
            patch.pose_y,
            patch.pose_z,
            existing.pose_x,
            existing.pose_y,
            existing.pose_z);
        const double pose_dissimilarity = clamp01(pose_delta / pose_norm_scale);

        const int cell_distance = std::abs(patch.coverage_x - existing.coverage_x) +
            std::abs(patch.coverage_y - existing.coverage_y);
        const double cell_dissimilarity = clamp01(static_cast<double>(cell_distance) / 2.0);

        const double radiance_delta = distance3(
            patch.radiance_x,
            patch.radiance_y,
            patch.radiance_z,
            existing.radiance_x,
            existing.radiance_y,
            existing.radiance_z);
        const double radiance_dissimilarity = clamp01(radiance_delta / kSqrt3);

        const double dissimilarity = clamp01(
            0.65 * pose_dissimilarity +
            0.20 * cell_dissimilarity +
            0.15 * radiance_dissimilarity);
        min_dissimilarity = std::min(min_dissimilarity, dissimilarity);
    }

    return clamp01(min_dissimilarity);
}

double robust_novelty(
    const PR1PatchDescriptor& patch,
    const PR1PatchDescriptor* existing_patches,
    std::size_t existing_count,
    const PR1InformationGainConfig& config) {
    if (existing_count == 0u) {
        return 1.0;
    }
    if (existing_patches == nullptr) {
        return 0.0;
    }

    const double pose_norm_scale = std::max(config.pose_eps * 8.0, 1e-9);
    std::vector<double> dissimilarities;
    dissimilarities.reserve(existing_count);

    for (std::size_t i = 0u; i < existing_count; ++i) {
        const PR1PatchDescriptor& existing = existing_patches[i];
        const double pose_delta = distance3(
            patch.pose_x,
            patch.pose_y,
            patch.pose_z,
            existing.pose_x,
            existing.pose_y,
            existing.pose_z);
        const double pose_dissimilarity = robust_cauchy(
            pose_delta / pose_norm_scale,
            config.robustness_scale);

        const int cell_distance = std::abs(patch.coverage_x - existing.coverage_x) +
            std::abs(patch.coverage_y - existing.coverage_y);
        const double cell_dissimilarity = robust_cauchy(
            static_cast<double>(cell_distance) / 2.0,
            config.robustness_scale);

        const double radiance_delta = distance3(
            patch.radiance_x,
            patch.radiance_y,
            patch.radiance_z,
            existing.radiance_x,
            existing.radiance_y,
            existing.radiance_z);
        const double radiance_dissimilarity = robust_cauchy(
            radiance_delta / kSqrt3,
            config.robustness_scale);

        const double dissimilarity = clamp01(
            0.65 * pose_dissimilarity +
            0.20 * cell_dissimilarity +
            0.15 * radiance_dissimilarity);
        dissimilarities.push_back(dissimilarity);
    }

    return clamp01(quantile(&dissimilarities, config.robust_quantile));
}

}  // namespace

core::Status pr1_compute_information_gain(
    const PR1PatchDescriptor& patch,
    const std::uint8_t* coverage_grid_states,
    std::size_t coverage_grid_count,
    const PR1InformationGainConfig& config,
    double* out_info_gain) {
    if (out_info_gain == nullptr) {
        return core::Status::kInvalidArgument;
    }
    if (config.coverage_grid_size <= 0) {
        return core::Status::kInvalidArgument;
    }
    if (!is_finite(config.state_gain_uncovered) ||
        !is_finite(config.state_gain_gray) ||
        !is_finite(config.state_gain_white) ||
        !is_finite(config.state_weight) ||
        !is_finite(config.frontier_weight) ||
        !is_finite(config.entropy_weight) ||
        !is_finite(config.rarity_weight) ||
        !is_finite(config.hybrid_agreement_tolerance) ||
        !is_finite(config.hybrid_high_weight)) {
        return core::Status::kInvalidArgument;
    }

    const std::size_t required_count =
        static_cast<std::size_t>(config.coverage_grid_size) * static_cast<std::size_t>(config.coverage_grid_size);
    if (coverage_grid_states == nullptr || coverage_grid_count < required_count) {
        return core::Status::kInvalidArgument;
    }

    const int row = positive_mod(patch.coverage_y, config.coverage_grid_size);
    const int col = positive_mod(patch.coverage_x, config.coverage_grid_size);
    const std::size_t center_idx =
        static_cast<std::size_t>(row) * static_cast<std::size_t>(config.coverage_grid_size) +
        static_cast<std::size_t>(col);
    const PR1CoverageState center = decode_state(coverage_grid_states[center_idx]);
    const NeighborhoodStats neighborhood = local_neighborhood_stats(
        row,
        col,
        coverage_grid_states,
        config.coverage_grid_size);

    const double legacy = legacy_info_gain(center, neighborhood, config);
    const double entropy_frontier = entropy_frontier_info_gain(center, neighborhood, config);

    double info_gain = legacy;
    if (config.info_gain_strategy == PR1InfoGainStrategy::kEntropyFrontier) {
        info_gain = entropy_frontier;
    } else if (config.info_gain_strategy == PR1InfoGainStrategy::kHybridCrossCheck) {
        info_gain = blend_with_disagreement_guard(legacy, entropy_frontier, config);
    }

    *out_info_gain = clamp01(info_gain);
    return core::Status::kOk;
}

core::Status pr1_compute_novelty(
    const PR1PatchDescriptor& patch,
    const PR1PatchDescriptor* existing_patches,
    std::size_t existing_count,
    const PR1InformationGainConfig& config,
    double* out_novelty) {
    if (out_novelty == nullptr) {
        return core::Status::kInvalidArgument;
    }
    if (config.pose_eps <= 0.0 || !std::isfinite(config.pose_eps) ||
        !std::isfinite(config.robust_quantile) ||
        !std::isfinite(config.robustness_scale) ||
        !std::isfinite(config.hybrid_agreement_tolerance) ||
        !std::isfinite(config.hybrid_high_weight)) {
        return core::Status::kInvalidArgument;
    }
    if (existing_count > 0u && existing_patches == nullptr) {
        return core::Status::kInvalidArgument;
    }

    const double legacy = legacy_novelty(patch, existing_patches, existing_count, config);
    const double robust = robust_novelty(patch, existing_patches, existing_count, config);
    double novelty = legacy;
    if (config.novelty_strategy == PR1NoveltyStrategy::kKernelRobust) {
        novelty = robust;
    } else if (config.novelty_strategy == PR1NoveltyStrategy::kHybridCrossCheck) {
        novelty = blend_with_disagreement_guard(legacy, robust, config);
    }

    *out_novelty = clamp01(novelty);
    return core::Status::kOk;
}

}  // namespace evidence
}  // namespace aether
