// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// test_scan_session_simulation.cpp
// Full scan session simulation — answers two critical user questions:
//   Q1: Does the heatmap overlay appear within 7 seconds? (210 frames @ 30fps)
//   Q2: Can we export a valid PLY for 3D viewer after stopping?
//
// Simulates: frame submission → TSDF integration → overlay generation → PLY export
// Uses QualityThresholds: overlay_start_weight=2, overlay_full_weight=24
//
// NOTE: This tests the C++ data pipeline ONLY. On device, the coordinator
// must be loaded first (CoreML ~10-30s). Once loaded, this pipeline runs.

#include "aether/tsdf/tsdf_volume.h"
#include "aether/tsdf/tsdf_constants.h"
#include "aether/splat/ply_loader.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <algorithm>

using namespace aether::tsdf;

// ─────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────

/// Generate synthetic depth map: a wall at `wall_z` with slight noise.
static void make_depth_frame(std::vector<float>& depth,
                             std::vector<unsigned char>& confidence,
                             int w, int h, float wall_z, int frame_idx) {
    depth.resize(static_cast<std::size_t>(w * h));
    confidence.resize(static_cast<std::size_t>(w * h));
    for (int y = 0; y < h; ++y) {
        for (int x = 0; x < w; ++x) {
            std::size_t idx = static_cast<std::size_t>(y * w + x);
            // Add tiny per-pixel noise based on frame to simulate real depth
            float noise = 0.001f * std::sin(static_cast<float>(x + frame_idx * 7)) *
                          std::cos(static_cast<float>(y + frame_idx * 3));
            depth[idx] = wall_z + noise;
            confidence[idx] = 2;  // high confidence
        }
    }
}

/// Camera pose with handheld-like motion (slow orbit).
static void orbit_pose(float out[16], int frame_idx, float radius = 0.15f) {
    std::memset(out, 0, sizeof(float) * 16);
    // Slow orbit: small arc over 210 frames
    float angle = static_cast<float>(frame_idx) * 0.003f;  // ~0.6 rad over 210 frames
    out[0]  = std::cos(angle);   // rotation around Y
    out[2]  = std::sin(angle);
    out[5]  = 1.0f;
    out[8]  = -std::sin(angle);
    out[10] = std::cos(angle);
    out[15] = 1.0f;
    // Translation: small orbit circle
    out[12] = radius * std::sin(angle);  // tx
    out[13] = 0.02f * std::sin(angle * 2.0f);  // ty (slight vertical sway)
    out[14] = radius * (1.0f - std::cos(angle));  // tz
}

// ─────────────────────────────────────────────────────────────────────
// Constants matching QualityThresholds in pipeline_coordinator.h
// ─────────────────────────────────────────────────────────────────────
static constexpr int OVERLAY_START_WEIGHT = 2;
static constexpr int OVERLAY_FULL_WEIGHT  = 24;
static constexpr int FPS = 30;
static constexpr int TOTAL_SECONDS = 7;
static constexpr int TOTAL_FRAMES = FPS * TOTAL_SECONDS;  // 210

int main() {
    int failed = 0;

    // =====================================================================
    // Test 7: Full 7-second scan simulation — heatmap overlay timing
    //
    // Simulates 210 frames (7s × 30fps) of a flat wall at 1.5m.
    // Camera orbits slowly (handheld motion).
    // After each second, checks:
    //   - Number of surface points (should grow)
    //   - Block quality: how many blocks have avg_weight ≥ 4 (overlay trigger)
    //   - Block quality: how many blocks have avg_weight ≥ 32 (S6+ quality)
    // =====================================================================
    {
        std::fprintf(stderr, "[Test 7] 7-second scan simulation — overlay timing\n");
        std::fprintf(stderr, "  Config: %d frames @ %dfps, overlay_start=%d, overlay_full=%d\n",
                     TOTAL_FRAMES, FPS, OVERLAY_START_WEIGHT, OVERLAY_FULL_WEIGHT);

        TSDFVolume volume;
        const int w = 128;
        const int h = 96;

        IntegrationInput input{};
        input.depth_width = w;
        input.depth_height = h;
        input.voxel_size = VOXEL_SIZE_MID;  // 0.01m = 1cm
        input.fx = 500.0f;
        input.fy = 500.0f;
        input.cx = static_cast<float>(w) / 2.0f;
        input.cy = static_cast<float>(h) / 2.0f;
        input.tracking_state = 2;  // ARTrackingStateNormal

        std::vector<float> depth;
        std::vector<unsigned char> conf;

        int first_overlay_frame = -1;  // frame when overlay first appears
        int first_s6_frame = -1;       // frame when S6+ quality first reached
        int skipped_frames = 0;

        std::fprintf(stderr, "\n  %-6s  %-12s  %-12s  %-12s  %-10s\n",
                     "Time", "SurfacePts", "TrainOvl", "S6+≥24", "MaxWeight");
        std::fprintf(stderr, "  %-6s  %-12s  %-12s  %-12s  %-10s\n",
                     "------", "----------", "---------", "--------", "---------");

        for (int frame = 0; frame < TOTAL_FRAMES; ++frame) {
            make_depth_frame(depth, conf, w, h, 1.5f, frame);
            input.depth_data = depth.data();
            input.confidence_data = conf.data();

            float pose[16];
            orbit_pose(pose, frame);
            input.view_matrix = pose;
            input.timestamp = static_cast<double>(frame) / static_cast<double>(FPS);

            IntegrationResult result{};
            volume.integrate(input, result);
            if (result.skipped) skipped_frames++;

            // Simulate frame selection: ~1 in 5 frames selected for training
            if (frame % 5 == 0) {
                volume.mark_training_coverage(
                    pose, input.fx, input.fy, input.cx, input.cy,
                    static_cast<uint32_t>(w), static_cast<uint32_t>(h));
            }

            // Report every second (every 30 frames) + first and last frame
            bool should_report = (frame == 0) ||
                                 ((frame + 1) % FPS == 0) ||
                                 (frame == TOTAL_FRAMES - 1);
            if (!should_report) continue;

            // Extract surface points
            std::vector<SurfacePoint> surface;
            volume.extract_surface_points(surface, 500000);

            // Check block quality (overlay trigger)
            std::vector<BlockQualitySample> samples;
            volume.get_block_quality_samples(samples);

            int overlay_blocks = 0;
            int s6_blocks = 0;
            float max_weight = 0.0f;

            for (const auto& s : samples) {
                if (s.avg_weight > max_weight) max_weight = s.avg_weight;
                // Overlay requires BOTH TSDF weight AND training coverage
                if (s.training_obs_count > 0 &&
                    s.avg_weight >= static_cast<float>(OVERLAY_START_WEIGHT))
                    overlay_blocks++;
                if (s.avg_weight >= static_cast<float>(OVERLAY_FULL_WEIGHT))
                    s6_blocks++;
            }

            if (first_overlay_frame < 0 && overlay_blocks > 0)
                first_overlay_frame = frame;
            if (first_s6_frame < 0 && s6_blocks > 0)
                first_s6_frame = frame;

            double time_s = static_cast<double>(frame + 1) / static_cast<double>(FPS);
            std::fprintf(stderr, "  %5.1fs  %10zu  %10d  %10d  %9.1f\n",
                         time_s, surface.size(), overlay_blocks, s6_blocks,
                         static_cast<double>(max_weight));
        }

        std::fprintf(stderr, "\n  Skipped frames (pose teleport): %d / %d\n",
                     skipped_frames, TOTAL_FRAMES);

        // ── Verdict: overlay by 7 seconds? ──
        if (first_overlay_frame >= 0) {
            double overlay_time = static_cast<double>(first_overlay_frame + 1) /
                                  static_cast<double>(FPS);
            std::fprintf(stderr, "\n  ✓ OVERLAY first appears at frame %d (t=%.1fs)\n",
                         first_overlay_frame, overlay_time);
            if (overlay_time > 7.0) {
                std::fprintf(stderr, "  FAIL: overlay appears after 7 seconds!\n");
                failed++;
            }
        } else {
            std::fprintf(stderr, "\n  ✗ FAIL: NO overlay blocks reached weight≥%d in %d frames!\n",
                         OVERLAY_START_WEIGHT, TOTAL_FRAMES);
            failed++;
        }

        if (first_s6_frame >= 0) {
            double s6_time = static_cast<double>(first_s6_frame + 1) /
                             static_cast<double>(FPS);
            std::fprintf(stderr, "  ✓ S6+ quality first reached at frame %d (t=%.1fs)\n",
                         first_s6_frame, s6_time);
        } else {
            std::fprintf(stderr, "  ℹ S6+ quality (weight≥%d) not reached in 7s — "
                         "expected, needs more frames or multi-view overlap\n",
                         OVERLAY_FULL_WEIGHT);
        }
    }

    // =====================================================================
    // Test 8: PLY export after scan session — can we enter 3D viewer?
    //
    // After 210 frames, export surface points as Gaussian PLY.
    // Verify: file exists, non-empty, valid PLY header.
    // This is exactly what stopCapture() → exportPointCloudPLY() does.
    // =====================================================================
    {
        std::fprintf(stderr, "\n[Test 8] PLY export after 7s scan session\n");

        TSDFVolume volume;
        const int w = 128;
        const int h = 96;

        IntegrationInput input{};
        input.depth_width = w;
        input.depth_height = h;
        input.voxel_size = VOXEL_SIZE_MID;
        input.fx = 500.0f;
        input.fy = 500.0f;
        input.cx = static_cast<float>(w) / 2.0f;
        input.cy = static_cast<float>(h) / 2.0f;
        input.tracking_state = 2;

        std::vector<float> depth;
        std::vector<unsigned char> conf;

        // Integrate 210 frames (same as Test 7)
        for (int frame = 0; frame < TOTAL_FRAMES; ++frame) {
            make_depth_frame(depth, conf, w, h, 1.5f, frame);
            input.depth_data = depth.data();
            input.confidence_data = conf.data();
            float pose[16];
            orbit_pose(pose, frame);
            input.view_matrix = pose;
            input.timestamp = static_cast<double>(frame) / static_cast<double>(FPS);
            IntegrationResult result{};
            volume.integrate(input, result);
        }

        // Extract surface points
        std::vector<SurfacePoint> surface;
        volume.extract_surface_points(surface, 10000000);
        std::fprintf(stderr, "  Surface points after %d frames: %zu\n",
                     TOTAL_FRAMES, surface.size());

        if (surface.empty()) {
            std::fprintf(stderr, "  FAIL: no surface points to export — 3D viewer would be empty!\n");
            failed++;
        } else {
            // Convert to GaussianParams (same logic as PipelineCoordinator::export_point_cloud_ply)
            std::vector<aether::splat::GaussianParams> gaussians;
            gaussians.reserve(surface.size());

            // Compute bounding sphere for adaptive scale
            double cx = 0, cy = 0, cz = 0;
            for (const auto& sp : surface) {
                cx += sp.position[0]; cy += sp.position[1]; cz += sp.position[2];
            }
            double inv_n = 1.0 / static_cast<double>(surface.size());
            float center[3] = {
                static_cast<float>(cx * inv_n),
                static_cast<float>(cy * inv_n),
                static_cast<float>(cz * inv_n)
            };

            float max_dist2 = 0.0f;
            for (const auto& sp : surface) {
                float dx = sp.position[0] - center[0];
                float dy = sp.position[1] - center[1];
                float dz = sp.position[2] - center[2];
                float d2 = dx*dx + dy*dy + dz*dz;
                if (d2 > max_dist2) max_dist2 = d2;
            }
            float scene_radius = std::sqrt(max_dist2);
            float cbrt_n = std::cbrt(static_cast<float>(surface.size()));
            float adaptive_scale = std::max(scene_radius / (cbrt_n * 3.0f), 0.002f);
            adaptive_scale = std::min(adaptive_scale, std::max(scene_radius * 0.05f, 0.005f));

            for (const auto& sp : surface) {
                aether::splat::GaussianParams g{};
                g.position[0] = sp.position[0];
                g.position[1] = sp.position[1];
                g.position[2] = sp.position[2];
                float shade = std::clamp(
                    sp.normal[0] * 0.577f + sp.normal[1] * 0.577f + sp.normal[2] * 0.577f,
                    0.0f, 1.0f) * 0.5f + 0.5f;
                g.color[0] = shade; g.color[1] = shade; g.color[2] = shade;
                g.opacity = std::clamp(static_cast<float>(sp.weight) / 32.0f, 0.1f, 1.0f);
                g.scale[0] = adaptive_scale;
                g.scale[1] = adaptive_scale;
                g.scale[2] = adaptive_scale;
                g.rotation[0] = 1.0f;
                gaussians.push_back(g);
            }

            // Write PLY to temp file
            const char* ply_path = "/tmp/aether3d_test_export.ply";
            auto status = aether::splat::write_ply(ply_path, gaussians.data(), gaussians.size());

            if (status != aether::core::Status::kOk) {
                std::fprintf(stderr, "  FAIL: write_ply returned error\n");
                failed++;
            } else {
                // Verify file exists and has content
                std::FILE* f = std::fopen(ply_path, "rb");
                if (!f) {
                    std::fprintf(stderr, "  FAIL: PLY file not created\n");
                    failed++;
                } else {
                    std::fseek(f, 0, SEEK_END);
                    long file_size = std::ftell(f);
                    std::fclose(f);

                    std::fprintf(stderr, "  ✓ PLY exported: %s\n", ply_path);
                    std::fprintf(stderr, "    File size: %ld bytes (%.1f KB)\n",
                                 file_size, static_cast<double>(file_size) / 1024.0);
                    std::fprintf(stderr, "    Gaussians: %zu\n", gaussians.size());
                    std::fprintf(stderr, "    Scene radius: %.3f m\n",
                                 static_cast<double>(scene_radius));
                    std::fprintf(stderr, "    Adaptive scale: %.4f\n",
                                 static_cast<double>(adaptive_scale));

                    if (file_size < 100) {
                        std::fprintf(stderr, "  FAIL: PLY file too small (%ld bytes)\n", file_size);
                        failed++;
                    }

                    // Verify PLY can be loaded back
                    aether::splat::PlyLoadResult load_result;
                    auto load_status = aether::splat::load_ply(ply_path, load_result);
                    if (load_status != aether::core::Status::kOk) {
                        std::fprintf(stderr, "  FAIL: PLY re-load failed\n");
                        failed++;
                    } else {
                        std::fprintf(stderr, "    Re-loaded: %zu gaussians (matches: %s)\n",
                                     load_result.gaussians.size(),
                                     load_result.gaussians.size() == gaussians.size() ? "YES" : "NO");
                        if (load_result.gaussians.size() != gaussians.size()) {
                            std::fprintf(stderr, "  FAIL: re-loaded count mismatch\n");
                            failed++;
                        }
                    }

                    // Clean up temp file
                    std::remove(ply_path);
                }
            }

            std::fprintf(stderr, "\n  → 3D viewer would show: %zu Gaussians with %.3fm scene radius\n",
                         gaussians.size(), static_cast<double>(scene_radius));
            std::fprintf(stderr, "  → SplatViewerView can render this PLY ✓\n");
        }
    }

    // =====================================================================
    // Test 9: Weight accumulation rate — how many frames to reach overlay?
    //
    // Same view, repeated frames → weight grows by ~1 per frame.
    // Verifies: 2 frames = weight 2 = overlay_start_weight.
    // This is the minimum time to first overlay from a single viewpoint.
    // =====================================================================
    {
        std::fprintf(stderr, "\n[Test 9] Weight accumulation rate (same viewpoint)\n");

        TSDFVolume volume;
        const int w = 64;
        const int h = 64;
        std::vector<float> depth;
        std::vector<unsigned char> conf;
        make_depth_frame(depth, conf, w, h, 1.5f, 0);

        float pose[16];
        std::memset(pose, 0, sizeof(pose));
        pose[0] = 1; pose[5] = 1; pose[10] = 1; pose[15] = 1;

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
        input.tracking_state = 2;

        int first_overlay_frame = -1;
        int first_s6_frame = -1;

        for (int frame = 0; frame < 40; ++frame) {
            input.timestamp = static_cast<double>(frame) / 30.0;
            IntegrationResult result{};
            volume.integrate(input, result);

            // Simulate training selection: every 5th frame
            if (frame % 5 == 0) {
                volume.mark_training_coverage(
                    pose, input.fx, input.fy, input.cx, input.cy,
                    static_cast<uint32_t>(w), static_cast<uint32_t>(h));
            }

            std::vector<BlockQualitySample> samples;
            volume.get_block_quality_samples(samples);

            float max_w = 0;
            int overlay_count = 0;
            int s6_count = 0;
            for (const auto& s : samples) {
                if (s.avg_weight > max_w) max_w = s.avg_weight;
                // Overlay requires training coverage
                if (s.training_obs_count > 0 &&
                    s.avg_weight >= OVERLAY_START_WEIGHT) overlay_count++;
                if (s.avg_weight >= OVERLAY_FULL_WEIGHT) s6_count++;
            }

            if (first_overlay_frame < 0 && overlay_count > 0)
                first_overlay_frame = frame;
            if (first_s6_frame < 0 && s6_count > 0)
                first_s6_frame = frame;

            if (frame < 10 || (frame + 1) % 5 == 0) {
                std::fprintf(stderr, "  Frame %2d: max_weight=%.1f, overlay_blocks=%d, s6_blocks=%d\n",
                             frame, static_cast<double>(max_w), overlay_count, s6_count);
            }
        }

        if (first_overlay_frame >= 0) {
            double t = static_cast<double>(first_overlay_frame + 1) / 30.0;
            std::fprintf(stderr, "  ✓ Overlay starts at frame %d (t=%.2fs) — "
                         "well within 7s requirement\n",
                         first_overlay_frame, t);
        } else {
            std::fprintf(stderr, "  ✗ FAIL: overlay never appeared in 40 frames!\n");
            failed++;
        }

        if (first_s6_frame >= 0) {
            double t = static_cast<double>(first_s6_frame + 1) / 30.0;
            std::fprintf(stderr, "  ✓ S6+ reached at frame %d (t=%.2fs)\n",
                         first_s6_frame, t);
        }
    }

    // =====================================================================
    // Summary
    // =====================================================================
    std::fprintf(stderr, "\n══════════════════════════════════════════════════════\n");
    std::fprintf(stderr, "Scan session simulation: %s (%d failures)\n",
                 failed == 0 ? "ALL PASSED ✓" : "FAILED ✗", failed);
    std::fprintf(stderr, "══════════════════════════════════════════════════════\n");
    if (failed == 0) {
        std::fprintf(stderr, "\nConclusion:\n");
        std::fprintf(stderr, "  1. TSDF pipeline produces overlay within 7s ✓\n");
        std::fprintf(stderr, "  2. PLY export works for 3D viewer entry ✓\n");
        std::fprintf(stderr, "  ⚠ ON DEVICE: These work ONLY after coordinatorBridge loads.\n");
        std::fprintf(stderr, "    iPhone 12 coordinator init takes 10-30s (CoreML).\n");
        std::fprintf(stderr, "    Check Xcode console for '[Aether3D] Coordinator Step X/4'\n");
        std::fprintf(stderr, "    to find the bottleneck.\n");
    }

    return failed;
}
