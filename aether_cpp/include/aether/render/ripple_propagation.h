// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_CPP_RENDER_RIPPLE_PROPAGATION_H
#define AETHER_CPP_RENDER_RIPPLE_PROPAGATION_H

#ifdef __cplusplus

#include <cstddef>
#include <cstdint>

namespace aether {
namespace render {

struct RippleConfig {
    float damping{0.85f};
    int max_hops{8};
    float delay_per_hop_s{0.06f};
};

void build_adjacency(
    const std::uint32_t* triangle_indices,
    std::size_t triangle_count,
    std::uint32_t* out_offsets,
    std::uint32_t* out_neighbors,
    std::size_t* out_neighbor_count);

void compute_ripple_amplitudes(
    const std::uint32_t* adjacency_offsets,
    const std::uint32_t* adjacency_neighbors,
    std::size_t triangle_count,
    const std::uint32_t* trigger_triangle_ids,
    std::size_t trigger_count,
    const float* trigger_start_times,
    float current_time,
    const RippleConfig& config,
    float* out_amplitudes);

}  // namespace render
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_CPP_RENDER_RIPPLE_PROPAGATION_H
