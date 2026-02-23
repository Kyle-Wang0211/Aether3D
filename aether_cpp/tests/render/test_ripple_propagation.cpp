// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/render/ripple_propagation.h"

#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

int main() {
    int failed = 0;
    using namespace aether::render;

    // -- Test 1: Default RippleConfig values are sane. --
    {
        RippleConfig config{};
        if (config.damping <= 0.0f || config.damping >= 1.0f) {
            std::fprintf(stderr,
                         "default damping should be in (0,1): %f\n",
                         config.damping);
            failed++;
        }
        if (config.max_hops <= 0) {
            std::fprintf(stderr,
                         "default max_hops should be positive: %d\n",
                         config.max_hops);
            failed++;
        }
        if (config.delay_per_hop_s <= 0.0f) {
            std::fprintf(stderr,
                         "default delay_per_hop_s should be positive: %f\n",
                         config.delay_per_hop_s);
            failed++;
        }
    }

    // -- Test 2: build_adjacency for a pair of triangles sharing an edge. --
    //
    //  v0---v1
    //  | \ T0|
    //  |  \  |
    //  |T1 \ |
    //  v3---v2
    //
    //  T0 = (v0, v1, v2), T1 = (v0, v2, v3)
    //  Shared edge: (v0, v2)
    {
        std::uint32_t indices[] = {
            0, 1, 2,   // T0
            0, 2, 3,   // T1
        };
        const std::size_t tri_count = 2;
        const std::size_t max_offsets = tri_count + 1;

        std::vector<std::uint32_t> offsets(max_offsets, 0);
        std::vector<std::uint32_t> neighbors(tri_count * 3, 0);
        std::size_t neighbor_count = 0;

        build_adjacency(indices, tri_count,
                        offsets.data(), neighbors.data(), &neighbor_count);

        // Each triangle should have at least one neighbor (the other triangle).
        if (neighbor_count == 0) {
            std::fprintf(stderr,
                         "build_adjacency should find at least 1 neighbor pair\n");
            failed++;
        }
    }

    // -- Test 3: build_adjacency with a single triangle (no neighbors). --
    {
        std::uint32_t indices[] = {0, 1, 2};
        const std::size_t tri_count = 1;

        std::uint32_t offsets[2] = {0, 0};
        std::uint32_t neighbors[3] = {0, 0, 0};
        std::size_t neighbor_count = 0;

        build_adjacency(indices, tri_count,
                        offsets, neighbors, &neighbor_count);

        if (neighbor_count != 0) {
            std::fprintf(stderr,
                         "single triangle should have 0 neighbors, got %zu\n",
                         neighbor_count);
            failed++;
        }
    }

    // -- Test 4: compute_ripple_amplitudes for triggered triangle. --
    {
        // Two triangles sharing an edge (same setup as Test 2).
        std::uint32_t indices[] = {0, 1, 2, 0, 2, 3};
        const std::size_t tri_count = 2;

        std::uint32_t offsets[3] = {0};
        std::uint32_t neighbors[6] = {0};
        std::size_t neighbor_count = 0;
        build_adjacency(indices, tri_count, offsets, neighbors, &neighbor_count);

        // Trigger T0 at time 0.
        std::uint32_t trigger_id = 0;
        float trigger_time = 0.0f;
        float current_time = 0.01f;

        RippleConfig config{};
        float amplitudes[2] = {0.0f, 0.0f};

        compute_ripple_amplitudes(
            offsets, neighbors, tri_count,
            &trigger_id, 1,
            &trigger_time,
            current_time,
            config,
            amplitudes);

        // The triggered triangle should have a non-zero amplitude.
        if (amplitudes[0] <= 0.0f) {
            std::fprintf(stderr,
                         "triggered triangle amplitude should be > 0: %f\n",
                         amplitudes[0]);
            failed++;
        }
    }

    // -- Test 5: Ripple amplitude decreases with distance (hops). --
    {
        // Three triangles in a chain: T0-T1-T2
        // T0 = (0,1,2), T1 = (1,2,3), T2 = (2,3,4)
        std::uint32_t indices[] = {
            0, 1, 2,
            1, 2, 3,
            2, 3, 4,
        };
        const std::size_t tri_count = 3;

        std::uint32_t offsets[4] = {0};
        std::uint32_t neighbors[9] = {0};
        std::size_t neighbor_count = 0;
        build_adjacency(indices, tri_count, offsets, neighbors, &neighbor_count);

        // Trigger T0 at time 0.
        std::uint32_t trigger_id = 0;
        float trigger_time = 0.0f;

        RippleConfig config{};
        config.damping = 0.5f;
        config.delay_per_hop_s = 0.01f;

        // Evaluate at a time where the ripple has propagated.
        float current_time = 0.1f;
        float amplitudes[3] = {0.0f, 0.0f, 0.0f};

        compute_ripple_amplitudes(
            offsets, neighbors, tri_count,
            &trigger_id, 1,
            &trigger_time,
            current_time,
            config,
            amplitudes);

        // T0 (source) should have >= amplitude than T1 (1 hop), which >= T2 (2 hops).
        if (amplitudes[0] < amplitudes[1]) {
            std::fprintf(stderr,
                         "source amplitude should be >= 1-hop: T0=%f, T1=%f\n",
                         amplitudes[0], amplitudes[1]);
            failed++;
        }
        if (amplitudes[1] < amplitudes[2]) {
            std::fprintf(stderr,
                         "1-hop amplitude should be >= 2-hop: T1=%f, T2=%f\n",
                         amplitudes[1], amplitudes[2]);
            failed++;
        }
    }

    // -- Test 6: No triggers yields zero amplitudes. --
    {
        std::uint32_t indices[] = {0, 1, 2};
        const std::size_t tri_count = 1;

        std::uint32_t offsets[2] = {0, 0};
        std::uint32_t neighbors[1] = {0};
        std::size_t neighbor_count = 0;
        build_adjacency(indices, tri_count, offsets, neighbors, &neighbor_count);

        float amplitudes[1] = {99.0f};
        RippleConfig config{};
        compute_ripple_amplitudes(
            offsets, neighbors, tri_count,
            nullptr, 0,
            nullptr,
            1.0f,
            config,
            amplitudes);

        if (amplitudes[0] != 0.0f) {
            std::fprintf(stderr,
                         "no triggers: amplitude should be 0, got %f\n",
                         amplitudes[0]);
            failed++;
        }
    }

    // -- Test 7: Amplitudes are non-negative. --
    {
        std::uint32_t indices[] = {0, 1, 2, 1, 2, 3};
        const std::size_t tri_count = 2;

        std::uint32_t offsets[3] = {0};
        std::uint32_t neighbors[6] = {0};
        std::size_t neighbor_count = 0;
        build_adjacency(indices, tri_count, offsets, neighbors, &neighbor_count);

        std::uint32_t trigger_id = 0;
        float trigger_time = 0.0f;
        RippleConfig config{};
        float amplitudes[2] = {0.0f, 0.0f};

        compute_ripple_amplitudes(
            offsets, neighbors, tri_count,
            &trigger_id, 1,
            &trigger_time,
            5.0f,
            config,
            amplitudes);

        for (std::size_t i = 0; i < tri_count; ++i) {
            if (amplitudes[i] < 0.0f) {
                std::fprintf(stderr,
                             "amplitude[%zu] should be non-negative: %f\n",
                             i, amplitudes[i]);
                failed++;
            }
        }
    }

    return failed;
}
