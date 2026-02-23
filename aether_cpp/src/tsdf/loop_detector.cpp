// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/tsdf/loop_detector.h"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <unordered_set>

namespace aether {
namespace tsdf {
namespace {

float overlap_ratio(
    const std::uint64_t* a,
    std::size_t na,
    const std::uint64_t* b,
    std::size_t nb) {
    if (a == nullptr || b == nullptr || na == 0u || nb == 0u) {
        return 0.0f;
    }

    const bool a_smaller = na <= nb;
    const std::uint64_t* small = a_smaller ? a : b;
    const std::uint64_t* large = a_smaller ? b : a;
    const std::size_t nsmall = a_smaller ? na : nb;
    const std::size_t nlarge = a_smaller ? nb : na;

    std::unordered_set<std::uint64_t> lookup;
    lookup.reserve(nsmall * 2u + 1u);
    for (std::size_t i = 0u; i < nsmall; ++i) {
        lookup.insert(small[i]);
    }

    std::size_t inter = 0u;
    for (std::size_t i = 0u; i < nlarge; ++i) {
        if (lookup.find(large[i]) != lookup.end()) {
            inter += 1u;
        }
    }

    const std::size_t denom = std::min(na, nb);
    if (denom == 0u) {
        return 0.0f;
    }
    return static_cast<float>(inter) / static_cast<float>(denom);
}

}  // namespace

core::Status loop_detect_best(
    const std::uint64_t* current_blocks,
    std::size_t current_count,
    const std::uint64_t* history_blocks,
    const std::uint32_t* history_offsets,
    std::size_t history_frame_count,
    int skip_recent,
    float overlap_threshold,
    float yaw_sigma,
    float time_tau,
    const float* yaw_deltas,
    const float* time_deltas,
    LoopCandidate* out_candidate) {
    if (out_candidate == nullptr || history_offsets == nullptr) {
        return core::Status::kInvalidArgument;
    }
    if (current_count > 0u && current_blocks == nullptr) {
        return core::Status::kInvalidArgument;
    }
    if (history_offsets[history_frame_count] > 0u && history_blocks == nullptr) {
        return core::Status::kInvalidArgument;
    }

    *out_candidate = LoopCandidate{};

    const int skip = std::max(0, skip_recent);
    const float yaw_scale = (yaw_sigma > 1e-6f) ? yaw_sigma : 1.0f;
    const float time_scale = (time_tau > 1e-6f) ? time_tau : 1.0f;

    float best_score = 0.0f;
    int best_index = -1;
    float best_overlap = 0.0f;

    for (std::size_t i = 0u; i < history_frame_count; ++i) {
        if (static_cast<int>(history_frame_count - i) <= skip) {
            continue;
        }
        const std::size_t begin = history_offsets[i];
        const std::size_t end = history_offsets[i + 1u];
        if (end < begin) {
            return core::Status::kInvalidArgument;
        }

        const float overlap = overlap_ratio(
            current_blocks,
            current_count,
            history_blocks + begin,
            end - begin);
        if (overlap < overlap_threshold) {
            continue;
        }

        const float yaw = (yaw_deltas != nullptr) ? std::fabs(yaw_deltas[i]) : 0.0f;
        const float dt = (time_deltas != nullptr) ? std::fabs(time_deltas[i]) : 0.0f;
        const float score = overlap * std::exp(-yaw / yaw_scale) * std::exp(-dt / time_scale);
        if (score > best_score) {
            best_score = score;
            best_index = static_cast<int>(i);
            best_overlap = overlap;
        }
    }

    out_candidate->frame_index = best_index;
    out_candidate->overlap_ratio = best_overlap;
    out_candidate->score = best_score;
    return core::Status::kOk;
}

}  // namespace tsdf
}  // namespace aether
