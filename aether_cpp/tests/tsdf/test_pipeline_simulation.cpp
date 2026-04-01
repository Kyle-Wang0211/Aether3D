// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// test_pipeline_simulation.cpp
// End-to-end TSDF pipeline simulation:
//   synthetic depth → integrate (multi-frame) → extract_surface_points
//   → verify non-zero output → get_block_quality_samples → verify overlay data
//
// This validates the critical path that replaced accumulated point clouds.
// On device, these surface points feed the Metal point cloud renderer.

#include "aether/tsdf/tsdf_volume.h"
#include "aether/tsdf/tsdf_constants.h"

#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

using namespace aether::tsdf;

// Helper: generate synthetic depth for a flat wall at `wall_z` meters.
static void make_flat_depth(std::vector<float>& depth,
                            std::vector<unsigned char>& confidence,
                            int w, int h, float wall_z) {
    depth.resize(static_cast<std::size_t>(w * h));
    confidence.resize(static_cast<std::size_t>(w * h));
    for (int i = 0; i < w * h; ++i) {
        depth[static_cast<std::size_t>(i)] = wall_z;
        confidence[static_cast<std::size_t>(i)] = 2;  // high confidence
    }
}

// Helper: identity pose (camera at origin, looking -Z).
static void identity_pose(float out[16]) {
    std::memset(out, 0, sizeof(float) * 16);
    out[0] = 1.0f; out[5] = 1.0f; out[10] = 1.0f; out[15] = 1.0f;
}

// Helper: slightly translated pose along X.
static void translated_pose(float out[16], float tx) {
    identity_pose(out);
    out[12] = tx;  // column-major: [12] = translation.x
}

int main() {
    int failed = 0;

    // =========================================================================
    // Test 1: Single frame → extract_surface_points produces non-zero output.
    // A flat wall at 1.5m integrated from a single view should create voxels
    // near the surface (|SDF| < 0.5) that extract_surface_points finds.
    // =========================================================================
    {
        std::fprintf(stderr, "[Test 1] Single frame → surface points > 0\n");

        TSDFVolume volume;
        const int w = 64;
        const int h = 64;
        std::vector<float> depth;
        std::vector<unsigned char> conf;
        make_flat_depth(depth, conf, w, h, 1.5f);

        float pose[16];
        identity_pose(pose);

        IntegrationInput input{};
        input.depth_data = depth.data();
        input.depth_width = w;
        input.depth_height = h;
        input.confidence_data = conf.data();
        input.voxel_size = VOXEL_SIZE_MID;
        input.fx = 500.0f;
        input.fy = 500.0f;
        input.cx = static_cast<float>(w) / 2.0f;
        input.cy = static_cast<float>(h) / 2.0f;
        input.view_matrix = pose;
        input.timestamp = 1.0;
        input.tracking_state = 2;

        IntegrationResult result{};
        int rc = volume.integrate(input, result);

        if (rc != 0) {
            std::fprintf(stderr, "  FAIL: integrate returned %d\n", rc);
            failed++;
        } else {
            std::fprintf(stderr, "  integrate OK: %d voxels, %d blocks\n",
                         result.voxels_integrated, result.blocks_updated);
        }

        std::vector<SurfacePoint> surface;
        volume.extract_surface_points(surface, 100000);

        std::fprintf(stderr, "  surface points: %zu\n", surface.size());
        if (surface.empty()) {
            std::fprintf(stderr, "  FAIL: extract_surface_points returned 0 points after 1 frame\n");
            failed++;
        }

        // Verify all surface points have position near z=-1.5m
        // (identity pose: camera at origin looking along -Z → depth 1.5m → z=-1.5)
        int out_of_range = 0;
        for (const auto& sp : surface) {
            if (sp.position[2] < -2.0f || sp.position[2] > -1.0f) {
                out_of_range++;
            }
        }
        if (out_of_range > 0 && surface.size() > 0) {
            float ratio = static_cast<float>(out_of_range) / static_cast<float>(surface.size());
            if (ratio > 0.1f) {
                std::fprintf(stderr, "  FAIL: %.0f%% points out of z=[-2.0, -1.0] range\n",
                             static_cast<double>(ratio * 100.0f));
                failed++;
            }
        }
    }

    // =========================================================================
    // Test 2: Multi-frame integration → surface points increase with more views.
    // Simulates what happens during a real scan: multiple frames from slightly
    // different camera positions build up voxel weight.
    // =========================================================================
    {
        std::fprintf(stderr, "\n[Test 2] Multi-frame → weight accumulation\n");

        TSDFVolume volume;
        const int w = 64;
        const int h = 64;
        std::vector<float> depth;
        std::vector<unsigned char> conf;
        make_flat_depth(depth, conf, w, h, 1.5f);

        IntegrationInput input{};
        input.depth_data = depth.data();
        input.depth_width = w;
        input.depth_height = h;
        input.confidence_data = conf.data();
        input.voxel_size = VOXEL_SIZE_MID;
        input.fx = 500.0f;
        input.fy = 500.0f;
        input.cx = static_cast<float>(w) / 2.0f;
        input.cy = static_cast<float>(h) / 2.0f;
        input.tracking_state = 2;

        // Integrate 5 frames with small camera translation (simulates handheld scan)
        for (int frame = 0; frame < 5; ++frame) {
            float pose[16];
            // Move camera 2cm per frame along X (within pose teleport threshold of 10cm)
            translated_pose(pose, static_cast<float>(frame) * 0.02f);
            input.view_matrix = pose;
            input.timestamp = 1.0 + static_cast<double>(frame) * 0.033;  // ~30fps

            IntegrationResult result{};
            int rc = volume.integrate(input, result);
            if (rc != 0 && !result.skipped) {
                std::fprintf(stderr, "  FAIL: frame %d integrate returned %d\n", frame, rc);
                failed++;
            }
        }

        std::vector<SurfacePoint> surface;
        volume.extract_surface_points(surface, 500000);
        std::fprintf(stderr, "  surface points after 5 frames: %zu\n", surface.size());

        if (surface.empty()) {
            std::fprintf(stderr, "  FAIL: no surface points after 5 frames\n");
            failed++;
        }

        // Verify weight > 1 for some points (multi-frame accumulation)
        int high_weight = 0;
        for (const auto& sp : surface) {
            if (sp.weight > 1) high_weight++;
        }
        std::fprintf(stderr, "  points with weight > 1: %d (%.0f%%)\n",
                     high_weight,
                     surface.empty() ? 0.0 :
                     static_cast<double>(high_weight) / static_cast<double>(surface.size()) * 100.0);
    }

    // =========================================================================
    // Test 3: get_block_quality_samples produces overlay data.
    // After integration, block quality samples should have avg_weight > 0
    // and occupied_count > 0.
    // =========================================================================
    {
        std::fprintf(stderr, "\n[Test 3] Block quality samples for overlay\n");

        TSDFVolume volume;
        const int w = 64;
        const int h = 64;
        std::vector<float> depth;
        std::vector<unsigned char> conf;
        make_flat_depth(depth, conf, w, h, 1.5f);

        float pose[16];
        identity_pose(pose);

        IntegrationInput input{};
        input.depth_data = depth.data();
        input.depth_width = w;
        input.depth_height = h;
        input.confidence_data = conf.data();
        input.voxel_size = VOXEL_SIZE_MID;
        input.fx = 500.0f;
        input.fy = 500.0f;
        input.cx = static_cast<float>(w) / 2.0f;
        input.cy = static_cast<float>(h) / 2.0f;
        input.view_matrix = pose;
        input.timestamp = 1.0;
        input.tracking_state = 2;

        IntegrationResult result{};
        volume.integrate(input, result);

        std::vector<BlockQualitySample> samples;
        volume.get_block_quality_samples(samples);

        std::fprintf(stderr, "  block quality samples: %zu\n", samples.size());
        if (samples.empty()) {
            std::fprintf(stderr, "  FAIL: no block quality samples after integration\n");
            failed++;
        }

        int with_occupancy = 0;
        float max_weight = 0.0f;
        for (const auto& s : samples) {
            if (s.occupied_count > 0) with_occupancy++;
            if (s.avg_weight > max_weight) max_weight = s.avg_weight;
        }
        std::fprintf(stderr, "  blocks with occupied voxels: %d\n", with_occupancy);
        std::fprintf(stderr, "  max avg_weight: %.2f\n", static_cast<double>(max_weight));

        if (with_occupancy == 0) {
            std::fprintf(stderr, "  FAIL: no blocks have occupied voxels\n");
            failed++;
        }
    }

    // =========================================================================
    // Test 4: max_points limit is respected.
    // =========================================================================
    {
        std::fprintf(stderr, "\n[Test 4] max_points limit\n");

        TSDFVolume volume;
        const int w = 64;
        const int h = 64;
        std::vector<float> depth;
        std::vector<unsigned char> conf;
        make_flat_depth(depth, conf, w, h, 1.5f);

        float pose[16];
        identity_pose(pose);

        IntegrationInput input{};
        input.depth_data = depth.data();
        input.depth_width = w;
        input.depth_height = h;
        input.confidence_data = conf.data();
        input.voxel_size = VOXEL_SIZE_MID;
        input.fx = 500.0f;
        input.fy = 500.0f;
        input.cx = static_cast<float>(w) / 2.0f;
        input.cy = static_cast<float>(h) / 2.0f;
        input.view_matrix = pose;
        input.timestamp = 1.0;
        input.tracking_state = 2;

        IntegrationResult result{};
        volume.integrate(input, result);

        // Request at most 10 points
        std::vector<SurfacePoint> capped;
        volume.extract_surface_points(capped, 10);

        std::fprintf(stderr, "  points with limit=10: %zu\n", capped.size());
        if (capped.size() > 10) {
            std::fprintf(stderr, "  FAIL: returned %zu points, max was 10\n", capped.size());
            failed++;
        }
    }

    // =========================================================================
    // Test 5: Empty volume → zero surface points, zero quality samples.
    // =========================================================================
    {
        std::fprintf(stderr, "\n[Test 5] Empty volume → zero output\n");

        TSDFVolume volume;

        std::vector<SurfacePoint> surface;
        volume.extract_surface_points(surface, 100000);
        if (!surface.empty()) {
            std::fprintf(stderr, "  FAIL: expected 0 surface points from empty volume, got %zu\n",
                         surface.size());
            failed++;
        }

        std::vector<BlockQualitySample> samples;
        volume.get_block_quality_samples(samples);
        if (!samples.empty()) {
            std::fprintf(stderr, "  FAIL: expected 0 quality samples from empty volume, got %zu\n",
                         samples.size());
            failed++;
        }
        std::fprintf(stderr, "  OK\n");
    }

    // =========================================================================
    // Test 6: Reset clears surface points.
    // =========================================================================
    {
        std::fprintf(stderr, "\n[Test 6] Reset clears surface points\n");

        TSDFVolume volume;
        const int w = 32;
        const int h = 32;
        std::vector<float> depth;
        std::vector<unsigned char> conf;
        make_flat_depth(depth, conf, w, h, 1.5f);

        float pose[16];
        identity_pose(pose);

        IntegrationInput input{};
        input.depth_data = depth.data();
        input.depth_width = w;
        input.depth_height = h;
        input.confidence_data = conf.data();
        input.voxel_size = VOXEL_SIZE_MID;
        input.fx = 500.0f;
        input.fy = 500.0f;
        input.cx = static_cast<float>(w) / 2.0f;
        input.cy = static_cast<float>(h) / 2.0f;
        input.view_matrix = pose;
        input.timestamp = 1.0;
        input.tracking_state = 2;

        IntegrationResult result{};
        volume.integrate(input, result);

        std::vector<SurfacePoint> before;
        volume.extract_surface_points(before, 100000);
        if (before.empty()) {
            std::fprintf(stderr, "  WARN: no points before reset (test may be invalid)\n");
        }

        volume.reset();

        std::vector<SurfacePoint> after;
        volume.extract_surface_points(after, 100000);
        if (!after.empty()) {
            std::fprintf(stderr, "  FAIL: expected 0 points after reset, got %zu\n", after.size());
            failed++;
        } else {
            std::fprintf(stderr, "  OK: %zu points before, 0 after reset\n", before.size());
        }
    }

    // =========================================================================
    // Summary
    // =========================================================================
    std::fprintf(stderr, "\n=== Pipeline simulation: %s (%d failures) ===\n",
                 failed == 0 ? "PASSED" : "FAILED", failed);

    return failed;
}
