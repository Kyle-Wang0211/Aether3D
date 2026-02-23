// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_TSDF_LOOP_DETECTOR_H
#define AETHER_TSDF_LOOP_DETECTOR_H

#ifdef __cplusplus

#include "aether/core/status.h"

#include <cstddef>
#include <cstdint>

namespace aether {
namespace tsdf {

struct LoopCandidate {
    int frame_index{-1};
    float overlap_ratio{0.0f};
    float score{0.0f};
};

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
    LoopCandidate* out_candidate);

}  // namespace tsdf
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_TSDF_LOOP_DETECTOR_H
