// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_INNOVATION_F8_UNCERTAINTY_FIELD_H
#define AETHER_INNOVATION_F8_UNCERTAINTY_FIELD_H

#ifdef __cplusplus

#include "aether/core/status.h"
#include "aether/innovation/core_types.h"

#include <cstddef>
#include <cstdint>
#include <vector>

namespace aether {
namespace innovation {

struct F8Observation {
    std::uint32_t gaussian_id{0};
    bool observed{true};
    float residual{0.0f};      // normalized to [0,1]
    float view_cosine{1.0f};   // [-1,1], usually [0,1] after abs(dot)
    double ds_belief{0.5};     // [0,1]
};

struct F8FieldConfig {
    float observed_decay{0.84f};
    float unobserved_growth{0.018f};
    float view_penalty{0.24f};
    float min_uncertainty{0.0f};
    float max_uncertainty{1.0f};
    float belief_mix_alpha{0.65f};  // final = alpha*belief + (1-alpha)*(1-uncertainty)
};

struct F8PerGaussianState {
    std::uint32_t gaussian_id{0};
    float base_uncertainty{0.5f};
    float last_view_cosine{1.0f};
    std::uint32_t observation_count{0};
    std::uint64_t frame_last_seen{0};
};

struct F8FrameStats {
    std::size_t updated_count{0};
    float mean_uncertainty{0.0f};
    double mean_fused_confidence{0.0};
};

class F8UncertaintyField {
public:
    explicit F8UncertaintyField(F8FieldConfig config = {});

    void reset();
    const std::vector<F8PerGaussianState>& states() const { return states_; }

    core::Status bootstrap_from_gaussians(const GaussianPrimitive* gaussians, std::size_t gaussian_count);

    core::Status process_frame(
        const F8Observation* observations,
        std::size_t observation_count,
        GaussianPrimitive* gaussians,
        std::size_t gaussian_count,
        F8FrameStats* out_stats);

    core::Status query_uncertainty(
        std::uint32_t gaussian_id,
        float view_cosine,
        float* out_uncertainty) const;

    core::Status fused_confidence(
        std::uint32_t gaussian_id,
        float view_cosine,
        double ds_belief,
        double* out_confidence) const;

private:
    F8PerGaussianState* find_or_create(std::uint32_t gaussian_id, float initial_uncertainty);
    const F8PerGaussianState* find(std::uint32_t gaussian_id) const;

    F8FieldConfig config_{};
    std::vector<F8PerGaussianState> states_{};
    std::uint64_t frame_counter_{0};
};

core::Status f8_collect_high_uncertainty_indices(
    const GaussianPrimitive* gaussians,
    std::size_t gaussian_count,
    float threshold,
    std::vector<std::uint32_t>* out_indices);

}  // namespace innovation
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_INNOVATION_F8_UNCERTAINTY_FIELD_H
