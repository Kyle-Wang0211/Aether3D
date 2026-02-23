// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/render/ripple_propagation.h"

#include "aether/core/numeric_guard.h"

#include <algorithm>
#include <cmath>
#include <queue>
#include <unordered_map>
#include <vector>

namespace aether {
namespace render {

namespace {
[[maybe_unused]] constexpr float kTwoPi = 6.28318530717958647692f;
}  // namespace

void build_adjacency(
    const std::uint32_t* triangle_indices,
    std::size_t triangle_count,
    std::uint32_t* out_offsets,
    std::uint32_t* out_neighbors,
    std::size_t* out_neighbor_count) {
    if (out_neighbor_count != nullptr) {
        *out_neighbor_count = 0u;
    }
    if (triangle_indices == nullptr || out_offsets == nullptr || out_neighbors == nullptr || out_neighbor_count == nullptr) {
        return;
    }

    std::vector<std::vector<std::uint32_t>> adjacency(triangle_count);
    std::unordered_map<std::uint64_t, std::uint32_t> edge_to_last_triangle;
    edge_to_last_triangle.reserve(triangle_count * 3u);

    auto register_edge = [&](std::uint32_t a, std::uint32_t b, std::uint32_t tri_id) {
        const std::uint32_t lo = std::min(a, b);
        const std::uint32_t hi = std::max(a, b);
        const std::uint64_t key = (static_cast<std::uint64_t>(lo) << 32u) | static_cast<std::uint64_t>(hi);
        const auto it = edge_to_last_triangle.find(key);
        if (it == edge_to_last_triangle.end()) {
            edge_to_last_triangle.emplace(key, tri_id);
            return;
        }
        const std::uint32_t neighbor = it->second;
        if (neighbor != tri_id) {
            adjacency[tri_id].push_back(neighbor);
            adjacency[neighbor].push_back(tri_id);
        }
        it->second = tri_id;
    };

    for (std::size_t i = 0u; i < triangle_count; ++i) {
        const std::uint32_t i0 = triangle_indices[i * 3u + 0u];
        const std::uint32_t i1 = triangle_indices[i * 3u + 1u];
        const std::uint32_t i2 = triangle_indices[i * 3u + 2u];
        const std::uint32_t tri_id = static_cast<std::uint32_t>(i);
        register_edge(i0, i1, tri_id);
        register_edge(i1, i2, tri_id);
        register_edge(i2, i0, tri_id);
    }

    for (std::size_t i = 0u; i < triangle_count; ++i) {
        auto& row = adjacency[i];
        std::sort(row.begin(), row.end());
        row.erase(std::unique(row.begin(), row.end()), row.end());
    }

    std::size_t cursor = 0u;
    for (std::size_t i = 0u; i < triangle_count; ++i) {
        out_offsets[i] = static_cast<std::uint32_t>(cursor);
        for (std::uint32_t neighbor : adjacency[i]) {
            out_neighbors[cursor++] = neighbor;
        }
    }
    out_offsets[triangle_count] = static_cast<std::uint32_t>(cursor);
    *out_neighbor_count = cursor;
}

void compute_ripple_amplitudes(
    const std::uint32_t* adjacency_offsets,
    const std::uint32_t* adjacency_neighbors,
    std::size_t triangle_count,
    const std::uint32_t* trigger_triangle_ids,
    std::size_t trigger_count,
    const float* trigger_start_times,
    float current_time,
    const RippleConfig& config,
    float* out_amplitudes) {
    if (adjacency_offsets == nullptr || adjacency_neighbors == nullptr || out_amplitudes == nullptr) {
        return;
    }

    for (std::size_t i = 0u; i < triangle_count; ++i) {
        out_amplitudes[i] = 0.0f;
    }
    if (trigger_triangle_ids == nullptr || trigger_start_times == nullptr || trigger_count == 0u) {
        return;
    }

    const float damping = std::max(0.0f, std::min(1.0f, config.damping));
    const int max_hops = std::max(0, config.max_hops);
    const float hop_delay = std::max(0.0f, config.delay_per_hop_s);

    std::vector<int> visited(triangle_count, -1);

    for (std::size_t t = 0u; t < trigger_count; ++t) {
        const std::uint32_t source = trigger_triangle_ids[t];
        if (source >= triangle_count) {
            continue;
        }
        const float elapsed = current_time - trigger_start_times[t];
        if (elapsed < 0.0f) {
            continue;
        }

        std::fill(visited.begin(), visited.end(), -1);
        std::queue<std::uint32_t> q;
        visited[source] = 0;
        q.push(source);

        while (!q.empty()) {
            const std::uint32_t tri = q.front();
            q.pop();
            const int hop = visited[tri];
            if (hop < 0 || hop > max_hops) {
                continue;
            }

            const float ready_time = hop_delay * static_cast<float>(hop);
            if (elapsed >= ready_time) {
                // Amplitude = damping^hop * global_envelope(elapsed)
                // Using global elapsed ensures source always >= neighbor amplitude.
                float amplitude = std::pow(damping, static_cast<float>(hop));
                if (hop_delay > 1e-6f) {
                    // Global envelope: decay from the initial trigger time.
                    // All triangles share the same envelope to preserve ordering.
                    const float wave_period = hop_delay * static_cast<float>(max_hops);
                    if (wave_period > 1e-6f) {
                        const float decay_rate = 1.0f / wave_period;
                        const float envelope = std::exp(-elapsed * decay_rate);
                        amplitude *= std::max(0.0f, envelope);
                    }
                }
                out_amplitudes[tri] = std::max(out_amplitudes[tri], amplitude);
            }

            if (hop == max_hops) {
                continue;
            }

            const std::uint32_t begin = adjacency_offsets[tri];
            const std::uint32_t end = adjacency_offsets[tri + 1u];
            for (std::uint32_t k = begin; k < end; ++k) {
                const std::uint32_t nb = adjacency_neighbors[k];
                if (nb >= triangle_count) {
                    continue;
                }
                if (visited[nb] >= 0) {
                    continue;
                }
                visited[nb] = hop + 1;
                q.push(nb);
            }
        }
    }

    // C01 NumericGuard: guard amplitude output at API boundary
    core::guard_finite_vector(out_amplitudes, triangle_count);
}

}  // namespace render
}  // namespace aether
