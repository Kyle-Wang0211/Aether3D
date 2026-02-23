// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/innovation/f6_conflict_dynamic_rejection.h"

#include <algorithm>

namespace aether {
namespace innovation {
namespace {

double clamp01(double v) {
    if (v < 0.0) {
        return 0.0;
    }
    if (v > 1.0) {
        return 1.0;
    }
    return v;
}

}  // namespace

F6ConflictDynamicRejector::F6ConflictDynamicRejector(F6RejectorConfig config)
    : config_(config) {}

void F6ConflictDynamicRejector::reset() {
    states_.clear();
}

F6PerGaussianState* F6ConflictDynamicRejector::find_or_create_state(
    std::uint32_t gaussian_id,
    std::uint64_t host_unit_id) {
    auto it = std::lower_bound(states_.begin(), states_.end(), gaussian_id, [](const F6PerGaussianState& lhs, std::uint32_t rhs_id) {
        return lhs.gaussian_id < rhs_id;
    });
    if (it != states_.end() && it->gaussian_id == gaussian_id) {
        it->host_unit_id = host_unit_id;
        return &(*it);
    }
    F6PerGaussianState s{};
    s.gaussian_id = gaussian_id;
    s.host_unit_id = host_unit_id;
    it = states_.insert(it, s);
    return &(*it);
}

const F6PerGaussianState* F6ConflictDynamicRejector::find_state(std::uint32_t gaussian_id) const {
    auto it = std::lower_bound(states_.begin(), states_.end(), gaussian_id, [](const F6PerGaussianState& lhs, std::uint32_t rhs_id) {
        return lhs.gaussian_id < rhs_id;
    });
    if (it != states_.end() && it->gaussian_id == gaussian_id) {
        return &(*it);
    }
    return nullptr;
}

core::Status F6ConflictDynamicRejector::process_frame(
    const F6ObservationPair* pairs,
    std::size_t pair_count,
    GaussianPrimitive* gaussians,
    std::size_t gaussian_count,
    F6FrameMetrics* out_metrics) {
    if (pair_count > 0u && pairs == nullptr) {
        return core::Status::kInvalidArgument;
    }
    if (gaussian_count > 0u && gaussians == nullptr) {
        return core::Status::kInvalidArgument;
    }
    if (out_metrics == nullptr) {
        return core::Status::kInvalidArgument;
    }
    if (!(config_.conflict_threshold >= 0.0 && config_.conflict_threshold <= 1.0) ||
        !(config_.release_ratio > 0.0 && config_.release_ratio <= 1.0) ||
        config_.sustain_frames == 0u || config_.recover_frames == 0u ||
        !(config_.ema_alpha > 0.0 && config_.ema_alpha <= 1.0) ||
        !(config_.score_gain > 0.0) ||
        !(config_.score_decay > 0.0)) {
        return core::Status::kInvalidArgument;
    }

    F6FrameMetrics metrics{};
    for (std::size_t i = 0u; i < pair_count; ++i) {
        const auto& pair = pairs[i];
        const evidence::DSMassCombineResult combined =
            evidence::DSMassFusion::dempster_combine(pair.predicted.sealed(), pair.observed.sealed());
        const double conflict = clamp01(combined.conflict);

        F6PerGaussianState* state = find_or_create_state(pair.gaussian_id, pair.host_unit_id);
        state->last_conflict = conflict;
        if (state->conflict_ema <= 0.0) {
            state->conflict_ema = conflict;
        } else {
            state->conflict_ema = config_.ema_alpha * conflict + (1.0 - config_.ema_alpha) * state->conflict_ema;
        }
        metrics.evaluated_count++;
        metrics.mean_conflict += conflict;

        const double high = config_.conflict_threshold;
        const double low = config_.conflict_threshold * config_.release_ratio;
        // Current-frame evidence gets priority so dynamic objects can recover
        // promptly when conflict drops, while EMA still stabilizes ambiguous frames.
        if (conflict > high) {
            state->dynamic_score += (state->conflict_ema - high) * config_.score_gain;
            state->conflict_streak += 1u;
            state->stable_streak = 0u;
            if (!state->dynamic &&
                (state->conflict_streak >= config_.sustain_frames ||
                 state->dynamic_score >= static_cast<double>(config_.sustain_frames))) {
                state->dynamic = true;
                metrics.marked_dynamic_count += 1u;
            }
            continue;
        }

        if (conflict <= low) {
            state->dynamic_score = std::max(
                0.0,
                state->dynamic_score - (high - state->conflict_ema) * config_.score_decay);
            state->stable_streak += 1u;
            if (state->dynamic && state->stable_streak >= config_.recover_frames) {
                state->dynamic = false;
                state->conflict_streak = 0u;
                metrics.restored_static_count += 1u;
            }
            continue;
        }

        if (state->conflict_ema > high) {
            state->dynamic_score += (state->conflict_ema - high) * config_.score_gain * 0.5;
            state->conflict_streak += 1u;
            state->stable_streak = 0u;
            if (!state->dynamic &&
                (state->conflict_streak >= config_.sustain_frames ||
                 state->dynamic_score >= static_cast<double>(config_.sustain_frames))) {
                state->dynamic = true;
                metrics.marked_dynamic_count += 1u;
            }
        } else if (state->conflict_ema <= low) {
            state->dynamic_score = std::max(
                0.0,
                state->dynamic_score - (high - state->conflict_ema) * config_.score_decay);
            state->stable_streak += 1u;
            if (state->dynamic && state->stable_streak >= config_.recover_frames) {
                state->dynamic = false;
                state->conflict_streak = 0u;
                metrics.restored_static_count += 1u;
            }
        } else {
            const double mid_pull = std::max(0.0, state->conflict_ema - low);
            state->dynamic_score = std::max(
                0.0,
                state->dynamic_score - mid_pull * config_.score_decay * 0.5);
            state->stable_streak = 0u;
        }
    }

    if (metrics.evaluated_count > 0u) {
        metrics.mean_conflict /= static_cast<double>(metrics.evaluated_count);
    }

    for (std::size_t i = 0u; i < gaussian_count; ++i) {
        const F6PerGaussianState* state = find_state(gaussians[i].id);
        if (state != nullptr) {
            set_gaussian_dynamic(gaussians[i], state->dynamic);
        }
    }

    *out_metrics = metrics;
    return core::Status::kOk;
}

core::Status f6_collect_static_binding_indices(
    const GaussianPrimitive* gaussians,
    std::size_t gaussian_count,
    std::vector<std::uint32_t>* out_indices) {
    if (out_indices == nullptr) {
        return core::Status::kInvalidArgument;
    }
    if (gaussian_count > 0u && gaussians == nullptr) {
        return core::Status::kInvalidArgument;
    }

    out_indices->clear();
    out_indices->reserve(gaussian_count);
    for (std::size_t i = 0u; i < gaussian_count; ++i) {
        if (!gaussian_is_dynamic(gaussians[i])) {
            out_indices->push_back(static_cast<std::uint32_t>(i));
        }
    }
    return core::Status::kOk;
}

}  // namespace innovation
}  // namespace aether
