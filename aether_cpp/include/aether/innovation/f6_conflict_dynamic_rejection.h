// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_INNOVATION_F6_CONFLICT_DYNAMIC_REJECTION_H
#define AETHER_INNOVATION_F6_CONFLICT_DYNAMIC_REJECTION_H

#ifdef __cplusplus

#include "aether/core/status.h"
#include "aether/evidence/ds_mass_function.h"
#include "aether/innovation/core_types.h"

#include <cstddef>
#include <cstdint>
#include <vector>

namespace aether {
namespace innovation {

struct F6ObservationPair {
    std::uint32_t gaussian_id{0};
    std::uint64_t host_unit_id{0};
    evidence::DSMassFunction predicted{};
    evidence::DSMassFunction observed{};
};

struct F6RejectorConfig {
    double conflict_threshold{0.33};
    double release_ratio{0.68};
    std::uint32_t sustain_frames{4};
    std::uint32_t recover_frames{6};
    double ema_alpha{0.45};      // Exponential smoothing factor for conflict.
    double score_gain{1.15};     // Score increment scale when conflict is high.
    double score_decay{0.75};    // Score decay scale when conflict is low.
};

struct F6PerGaussianState {
    std::uint32_t gaussian_id{0};
    std::uint64_t host_unit_id{0};
    std::uint32_t conflict_streak{0};
    std::uint32_t stable_streak{0};
    double last_conflict{0.0};
    double conflict_ema{0.0};
    double dynamic_score{0.0};
    bool dynamic{false};
};

struct F6FrameMetrics {
    std::size_t evaluated_count{0};
    std::size_t marked_dynamic_count{0};
    std::size_t restored_static_count{0};
    double mean_conflict{0.0};
};

class F6ConflictDynamicRejector {
public:
    explicit F6ConflictDynamicRejector(F6RejectorConfig config = {});

    void reset();
    const std::vector<F6PerGaussianState>& states() const { return states_; }

    core::Status process_frame(
        const F6ObservationPair* pairs,
        std::size_t pair_count,
        GaussianPrimitive* gaussians,
        std::size_t gaussian_count,
        F6FrameMetrics* out_metrics);

private:
    F6PerGaussianState* find_or_create_state(std::uint32_t gaussian_id, std::uint64_t host_unit_id);
    const F6PerGaussianState* find_state(std::uint32_t gaussian_id) const;

    F6RejectorConfig config_{};
    std::vector<F6PerGaussianState> states_{};
};

core::Status f6_collect_static_binding_indices(
    const GaussianPrimitive* gaussians,
    std::size_t gaussian_count,
    std::vector<std::uint32_t>* out_indices);

}  // namespace innovation
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_INNOVATION_F6_CONFLICT_DYNAMIC_REJECTION_H
