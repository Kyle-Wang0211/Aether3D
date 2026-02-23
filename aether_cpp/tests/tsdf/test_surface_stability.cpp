// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/tsdf/tsdf_volume.h"
#include "aether/tsdf/tsdf_constants.h"

#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

int main() {
    int failed = 0;
    using namespace aether::tsdf;

    // -- Test 1: Create volume, verify initial state via runtime_state. --
    {
        TSDFVolume volume;
        TSDFRuntimeState state{};
        volume.runtime_state(&state);
        if (state.frame_count != 0) {
            std::fprintf(stderr, "initial frame_count should be 0, got %llu\n",
                         static_cast<unsigned long long>(state.frame_count));
            failed++;
        }
        if (state.has_last_pose) {
            std::fprintf(stderr, "initial has_last_pose should be false\n");
            failed++;
        }
    }

    // -- Test 2: Integrate a single flat depth frame and verify success. --
    {
        TSDFVolume volume;

        const int w = 32;
        const int h = 32;
        std::vector<float> depth(w * h, 1.5f);
        std::vector<unsigned char> confidence(w * h, 2);

        // Identity-like view matrix.
        float view[16] = {
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1,
        };

        IntegrationInput input{};
        input.depth_data = depth.data();
        input.depth_width = w;
        input.depth_height = h;
        input.confidence_data = confidence.data();
        input.voxel_size = VOXEL_SIZE_MID;
        input.fx = 500.0f;
        input.fy = 500.0f;
        input.cx = static_cast<float>(w) / 2.0f;
        input.cy = static_cast<float>(h) / 2.0f;
        input.view_matrix = view;
        input.timestamp = 1.0;
        input.tracking_state = 2;

        IntegrationResult result{};
        int rc = volume.integrate(input, result);
        if (rc != 0) {
            std::fprintf(stderr, "integrate returned error code %d\n", rc);
            failed++;
        }
    }

    // -- Test 3: Two identical integrations should produce stable result. --
    {
        TSDFVolume volume;

        const int w = 16;
        const int h = 16;
        std::vector<float> depth(w * h, 2.0f);
        std::vector<unsigned char> confidence(w * h, 2);
        float view[16] = {
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1,
        };

        IntegrationInput input{};
        input.depth_data = depth.data();
        input.depth_width = w;
        input.depth_height = h;
        input.confidence_data = confidence.data();
        input.voxel_size = VOXEL_SIZE_MID;
        input.fx = 300.0f;
        input.fy = 300.0f;
        input.cx = static_cast<float>(w) / 2.0f;
        input.cy = static_cast<float>(h) / 2.0f;
        input.view_matrix = view;
        input.tracking_state = 2;

        // First integration at t=1.0
        input.timestamp = 1.0;
        IntegrationResult r1{};
        volume.integrate(input, r1);

        // Second identical integration at t=2.0
        input.timestamp = 2.0;
        IntegrationResult r2{};
        volume.integrate(input, r2);

        // After two identical depth frames, the volume should have been updated
        // successfully both times (no skipping).
        TSDFRuntimeState state{};
        volume.runtime_state(&state);
        if (state.frame_count < 2) {
            std::fprintf(stderr,
                         "expected frame_count >= 2 after two integrations, got %llu\n",
                         static_cast<unsigned long long>(state.frame_count));
            failed++;
        }
    }

    // -- Test 4: Reset clears all state. --
    {
        TSDFVolume volume;

        const int w = 8;
        const int h = 8;
        std::vector<float> depth(w * h, 1.0f);
        std::vector<unsigned char> confidence(w * h, 2);
        float view[16] = {
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1,
        };

        IntegrationInput input{};
        input.depth_data = depth.data();
        input.depth_width = w;
        input.depth_height = h;
        input.confidence_data = confidence.data();
        input.voxel_size = VOXEL_SIZE_MID;
        input.fx = 200.0f;
        input.fy = 200.0f;
        input.cx = 4.0f;
        input.cy = 4.0f;
        input.view_matrix = view;
        input.timestamp = 1.0;
        input.tracking_state = 2;

        IntegrationResult result{};
        volume.integrate(input, result);

        volume.reset();

        TSDFRuntimeState state{};
        volume.runtime_state(&state);
        if (state.frame_count != 0) {
            std::fprintf(stderr,
                         "frame_count should be 0 after reset, got %llu\n",
                         static_cast<unsigned long long>(state.frame_count));
            failed++;
        }
        if (state.has_last_pose) {
            std::fprintf(stderr, "has_last_pose should be false after reset\n");
            failed++;
        }
    }

    // -- Test 5: Save and restore runtime state round-trips. --
    {
        TSDFVolume volume;

        const int w = 8;
        const int h = 8;
        std::vector<float> depth(w * h, 1.0f);
        std::vector<unsigned char> confidence(w * h, 2);
        float view[16] = {
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1,
        };

        IntegrationInput input{};
        input.depth_data = depth.data();
        input.depth_width = w;
        input.depth_height = h;
        input.confidence_data = confidence.data();
        input.voxel_size = VOXEL_SIZE_MID;
        input.fx = 200.0f;
        input.fy = 200.0f;
        input.cx = 4.0f;
        input.cy = 4.0f;
        input.view_matrix = view;
        input.timestamp = 1.0;
        input.tracking_state = 2;

        IntegrationResult result{};
        volume.integrate(input, result);

        TSDFRuntimeState saved{};
        volume.runtime_state(&saved);

        TSDFVolume volume2;
        volume2.restore_runtime_state(saved);

        TSDFRuntimeState restored{};
        volume2.runtime_state(&restored);

        if (restored.frame_count != saved.frame_count) {
            std::fprintf(stderr,
                         "frame_count mismatch after restore: expected %llu, got %llu\n",
                         static_cast<unsigned long long>(saved.frame_count),
                         static_cast<unsigned long long>(restored.frame_count));
            failed++;
        }
    }

    return failed;
}
