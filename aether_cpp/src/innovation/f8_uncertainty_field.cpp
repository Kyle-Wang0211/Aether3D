// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/innovation/f8_uncertainty_field.h"

#include <algorithm>
#include <cmath>

namespace aether {
namespace innovation {
namespace {

float clampf(float v, float lo, float hi) {
    return std::max(lo, std::min(v, hi));
}

double clampd(double v, double lo, double hi) {
    return std::max(lo, std::min(v, hi));
}

}  // namespace

F8UncertaintyField::F8UncertaintyField(F8FieldConfig config)
    : config_(config) {}

void F8UncertaintyField::reset() {
    states_.clear();
    frame_counter_ = 0u;
}

F8PerGaussianState* F8UncertaintyField::find_or_create(std::uint32_t gaussian_id, float initial_uncertainty) {
    auto it = std::lower_bound(states_.begin(), states_.end(), gaussian_id, [](const F8PerGaussianState& lhs, std::uint32_t rhs_id) {
        return lhs.gaussian_id < rhs_id;
    });
    if (it != states_.end() && it->gaussian_id == gaussian_id) {
        return &(*it);
    }
    F8PerGaussianState s{};
    s.gaussian_id = gaussian_id;
    s.base_uncertainty = clampf(initial_uncertainty, config_.min_uncertainty, config_.max_uncertainty);
    s.last_view_cosine = 1.0f;
    it = states_.insert(it, s);
    return &(*it);
}

const F8PerGaussianState* F8UncertaintyField::find(std::uint32_t gaussian_id) const {
    auto it = std::lower_bound(states_.begin(), states_.end(), gaussian_id, [](const F8PerGaussianState& lhs, std::uint32_t rhs_id) {
        return lhs.gaussian_id < rhs_id;
    });
    if (it != states_.end() && it->gaussian_id == gaussian_id) {
        return &(*it);
    }
    return nullptr;
}

core::Status F8UncertaintyField::bootstrap_from_gaussians(
    const GaussianPrimitive* gaussians,
    std::size_t gaussian_count) {
    if (gaussian_count > 0u && gaussians == nullptr) {
        return core::Status::kInvalidArgument;
    }
    for (std::size_t i = 0u; i < gaussian_count; ++i) {
        (void)find_or_create(gaussians[i].id, gaussians[i].uncertainty);
    }
    return core::Status::kOk;
}

core::Status F8UncertaintyField::process_frame(
    const F8Observation* observations,
    std::size_t observation_count,
    GaussianPrimitive* gaussians,
    std::size_t gaussian_count,
    F8FrameStats* out_stats) {
    if (observation_count > 0u && observations == nullptr) {
        return core::Status::kInvalidArgument;
    }
    if (gaussian_count > 0u && gaussians == nullptr) {
        return core::Status::kInvalidArgument;
    }
    if (out_stats == nullptr) {
        return core::Status::kInvalidArgument;
    }
    if (!(config_.observed_decay > 0.0f && config_.observed_decay < 1.0f) ||
        !(config_.unobserved_growth >= 0.0f && config_.unobserved_growth <= 1.0f) ||
        !(config_.view_penalty >= 0.0f && config_.view_penalty <= 1.0f) ||
        !(config_.belief_mix_alpha >= 0.0f && config_.belief_mix_alpha <= 1.0f) ||
        !(config_.min_uncertainty >= 0.0f && config_.min_uncertainty <= config_.max_uncertainty &&
          config_.max_uncertainty <= 1.0f)) {
        return core::Status::kInvalidArgument;
    }

    frame_counter_ += 1u;
    (void)bootstrap_from_gaussians(gaussians, gaussian_count);

    std::vector<std::uint8_t> touched(states_.size(), 0u);
    double fused_sum = 0.0;
    std::size_t fused_count = 0u;
    for (std::size_t i = 0u; i < observation_count; ++i) {
        const auto& obs = observations[i];
        F8PerGaussianState* state = find_or_create(obs.gaussian_id, 0.5f);
        std::size_t state_index = static_cast<std::size_t>(state - &states_[0]);
        if (state_index < touched.size()) {
            touched[state_index] = 1u;
        }

        const float residual = clampf(obs.residual, 0.0f, 1.0f);
        const float view_cos = clampf(std::fabs(obs.view_cosine), 0.0f, 1.0f);
        state->last_view_cosine = view_cos;

        if (obs.observed) {
            state->base_uncertainty =
                state->base_uncertainty * config_.observed_decay +
                residual * (1.0f - config_.observed_decay);
            state->base_uncertainty += (1.0f - view_cos) * (config_.view_penalty * 0.5f);
            state->observation_count += 1u;
            state->frame_last_seen = frame_counter_;
        } else {
            state->base_uncertainty += config_.unobserved_growth;
        }
        state->base_uncertainty = clampf(state->base_uncertainty, config_.min_uncertainty, config_.max_uncertainty);

        const double fused =
            config_.belief_mix_alpha * clampd(obs.ds_belief, 0.0, 1.0) +
            (1.0 - config_.belief_mix_alpha) * (1.0 - static_cast<double>(state->base_uncertainty));
        fused_sum += clampd(fused, 0.0, 1.0);
        fused_count += 1u;
    }

    for (std::size_t i = 0u; i < states_.size(); ++i) {
        if (i < touched.size() && touched[i] == 0u) {
            states_[i].base_uncertainty = clampf(
                states_[i].base_uncertainty + config_.unobserved_growth,
                config_.min_uncertainty,
                config_.max_uncertainty);
        }
    }

    F8FrameStats stats{};
    stats.updated_count = gaussian_count;
    for (std::size_t i = 0u; i < gaussian_count; ++i) {
        const F8PerGaussianState* state = find(gaussians[i].id);
        if (state != nullptr) {
            gaussians[i].uncertainty = state->base_uncertainty;
        }
        stats.mean_uncertainty += gaussians[i].uncertainty;
    }
    if (gaussian_count > 0u) {
        stats.mean_uncertainty /= static_cast<float>(gaussian_count);
    }
    if (fused_count > 0u) {
        stats.mean_fused_confidence = fused_sum / static_cast<double>(fused_count);
    }

    *out_stats = stats;
    return core::Status::kOk;
}

core::Status F8UncertaintyField::query_uncertainty(
    std::uint32_t gaussian_id,
    float view_cosine,
    float* out_uncertainty) const {
    if (out_uncertainty == nullptr) {
        return core::Status::kInvalidArgument;
    }
    const F8PerGaussianState* state = find(gaussian_id);
    if (state == nullptr) {
        return core::Status::kOutOfRange;
    }
    const float vc = clampf(std::fabs(view_cosine), 0.0f, 1.0f);
    const float uncertainty = clampf(
        state->base_uncertainty + (1.0f - vc) * config_.view_penalty,
        config_.min_uncertainty,
        config_.max_uncertainty);
    *out_uncertainty = uncertainty;
    return core::Status::kOk;
}

core::Status F8UncertaintyField::fused_confidence(
    std::uint32_t gaussian_id,
    float view_cosine,
    double ds_belief,
    double* out_confidence) const {
    if (out_confidence == nullptr) {
        return core::Status::kInvalidArgument;
    }
    float uncertainty = 0.0f;
    core::Status status = query_uncertainty(gaussian_id, view_cosine, &uncertainty);
    if (status != core::Status::kOk) {
        return status;
    }
    const double confidence =
        config_.belief_mix_alpha * clampd(ds_belief, 0.0, 1.0) +
        (1.0 - config_.belief_mix_alpha) * (1.0 - static_cast<double>(uncertainty));
    *out_confidence = clampd(confidence, 0.0, 1.0);
    return core::Status::kOk;
}

core::Status f8_collect_high_uncertainty_indices(
    const GaussianPrimitive* gaussians,
    std::size_t gaussian_count,
    float threshold,
    std::vector<std::uint32_t>* out_indices) {
    if (out_indices == nullptr) {
        return core::Status::kInvalidArgument;
    }
    if (gaussian_count > 0u && gaussians == nullptr) {
        return core::Status::kInvalidArgument;
    }
    threshold = clampf(threshold, 0.0f, 1.0f);

    out_indices->clear();
    for (std::size_t i = 0u; i < gaussian_count; ++i) {
        if (gaussians[i].uncertainty >= threshold) {
            out_indices->push_back(static_cast<std::uint32_t>(i));
        }
    }
    std::sort(out_indices->begin(), out_indices->end(), [&](std::uint32_t lhs, std::uint32_t rhs) {
        if (gaussians[lhs].uncertainty != gaussians[rhs].uncertainty) {
            return gaussians[lhs].uncertainty > gaussians[rhs].uncertainty;
        }
        if (gaussians[lhs].patch_priority != gaussians[rhs].patch_priority) {
            return gaussians[lhs].patch_priority > gaussians[rhs].patch_priority;
        }
        return gaussians[lhs].id < gaussians[rhs].id;
    });
    return core::Status::kOk;
}

}  // namespace innovation
}  // namespace aether
