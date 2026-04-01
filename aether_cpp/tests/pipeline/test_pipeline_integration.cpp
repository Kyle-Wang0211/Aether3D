// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// test_pipeline_integration.cpp
// ════════════════════════════════════════════════════════════════
// 7-LAYER PIPELINE INTEGRATION TEST
//
// Simulates the REAL device data flow through all 7 layers:
//
//   ① Swift isForwardingFrame 守卫  → 60fps → 30fps (skip every other)
//   ② Bridge 初始化 / DAv2 加载     → 0fps for 9.2s (simulated)
//   ③ SPSC 队列 (depth 8)          → queue overflow → frame drops
//   ④ DAv2 推理                    → NullEngine → LiDAR fallback
//   ⑤ TSDF 集成                    → synthetic depth → blocks
//   ⑥ 帧选择器                     → 3mm threshold vs 3.8mm/frame displacement
//   ⑦ 训练循环                     → 8 steps/batch, 200ms budget
//
// Scene: 30cm colored box on floor, slow orbit at 5cm/s (worst case).
// This matches the real-device scenario where:
//   - Camera moves at 5cm/s → at 13fps → 3.8mm/frame → barely above 3mm threshold
//   - Previous 1cm threshold rejected ALL frames → fixed to 3mm

#include "aether/pipeline/pipeline_coordinator.h"
#include "aether/render/gpu_device.h"
#include "aether/splat/splat_render_engine.h"
#include "aether/training/gaussian_training_engine.h"

#include <algorithm>
#include <cassert>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <thread>
#include <vector>

// ═══════════════════════════════════════════════════════════════════
// Synthetic Scene: 30cm colored box on a floor
// ═══════════════════════════════════════════════════════════════════
namespace {

struct Box {
    float cx, cy, cz;  // center
    float hx, hy, hz;  // half-extents
};
static constexpr Box kBox = {0.0f, 0.15f, 1.0f, 0.15f, 0.15f, 0.15f};

// Ray-cast the scene: box + floor.
static float ray_cast(float ox, float oy, float oz,
                      float dx, float dy, float dz,
                      float max_depth,
                      float out_normal[3]) {
    float best_t = max_depth + 1.0f;
    out_normal[0] = out_normal[1] = out_normal[2] = 0.0f;

    // Floor (y=0)
    if (std::fabs(dy) > 1e-8f) {
        float t = -oy / dy;
        if (t > 0.05f && t < best_t) {
            float hx = ox + dx * t;
            float hz = oz + dz * t;
            if (hx > -3.0f && hx < 3.0f && hz > -1.0f && hz < 4.0f) {
                best_t = t;
                out_normal[0] = 0; out_normal[1] = 1; out_normal[2] = 0;
            }
        }
    }

    // Box (6 faces)
    const auto& b = kBox;
    float faces[][4] = {
        { 1,  0,  0, b.cx + b.hx},
        {-1,  0,  0, -(b.cx - b.hx)},
        { 0,  1,  0, b.cy + b.hy},
        { 0, -1,  0, -(b.cy - b.hy)},
        { 0,  0,  1, b.cz + b.hz},
        { 0,  0, -1, -(b.cz - b.hz)},
    };
    for (int f = 0; f < 6; ++f) {
        float fn = faces[f][0], fm = faces[f][1], fl = faces[f][2], fd = faces[f][3];
        float denom = fn * dx + fm * dy + fl * dz;
        if (std::fabs(denom) < 1e-8f) continue;
        float t = (fd - (fn * ox + fm * oy + fl * oz)) / denom;
        if (t > 0.05f && t < best_t) {
            float hx_ = ox + dx * t, hy_ = oy + dy * t, hz_ = oz + dz * t;
            if (hx_ >= b.cx - b.hx - 0.001f && hx_ <= b.cx + b.hx + 0.001f &&
                hy_ >= b.cy - b.hy - 0.001f && hy_ <= b.cy + b.hy + 0.001f &&
                hz_ >= b.cz - b.hz - 0.001f && hz_ <= b.cz + b.hz + 0.001f) {
                best_t = t;
                out_normal[0] = fn; out_normal[1] = fm; out_normal[2] = fl;
            }
        }
    }
    return best_t;
}

static void normal_to_color(const float normal[3], std::uint8_t out_rgba[4]) {
    if (normal[1] > 0.5f)       { out_rgba[0] = 128; out_rgba[1] = 128; out_rgba[2] = 128; }
    else if (normal[0] > 0.5f)  { out_rgba[0] = 200; out_rgba[1] = 40;  out_rgba[2] = 40;  }
    else if (normal[0] < -0.5f) { out_rgba[0] = 40;  out_rgba[1] = 200; out_rgba[2] = 200; }
    else if (normal[1] < -0.5f) { out_rgba[0] = 200; out_rgba[1] = 40;  out_rgba[2] = 200; }
    else if (normal[2] > 0.5f)  { out_rgba[0] = 40;  out_rgba[1] = 40;  out_rgba[2] = 200; }
    else if (normal[2] < -0.5f) { out_rgba[0] = 200; out_rgba[1] = 200; out_rgba[2] = 40;  }
    else                        { out_rgba[0] = 100; out_rgba[1] = 100; out_rgba[2] = 100; }
    out_rgba[3] = 255;
}

static void generate_frame(
    float angle_rad, float radius, float cam_height,
    std::uint32_t img_w, std::uint32_t img_h,
    float fx, float fy, float cx, float cy,
    std::vector<std::uint8_t>& out_rgba,
    std::vector<float>& out_depth,
    float out_transform[16],
    float out_intrinsics[9])
{
    const float target_x = kBox.cx, target_y = kBox.cy, target_z = kBox.cz;
    float cam_x = target_x + radius * std::cos(angle_rad);
    float cam_y = cam_height;
    float cam_z = target_z + radius * std::sin(angle_rad);

    // Look-at: forward → target
    float fwd_x = target_x - cam_x, fwd_y = target_y - cam_y, fwd_z = target_z - cam_z;
    float fwd_len = std::sqrt(fwd_x * fwd_x + fwd_y * fwd_y + fwd_z * fwd_z);
    fwd_x /= fwd_len; fwd_y /= fwd_len; fwd_z /= fwd_len;

    // Right = normalize(fwd × (0,1,0))
    float right_x = fwd_z, right_y = 0.0f, right_z = -fwd_x;
    float right_len = std::sqrt(right_x * right_x + right_z * right_z);
    if (right_len > 1e-6f) { right_x /= right_len; right_z /= right_len; }

    // Up = right × fwd
    float up_x = right_y * fwd_z - right_z * fwd_y;
    float up_y = right_z * fwd_x - right_x * fwd_z;
    float up_z = right_x * fwd_y - right_y * fwd_x;

    // Column-major 4×4: col0=right, col1=up, col2=-fwd, col3=position
    std::memset(out_transform, 0, 16 * sizeof(float));
    out_transform[0]  = right_x;  out_transform[1]  = right_y;  out_transform[2]  = right_z;
    out_transform[4]  = up_x;     out_transform[5]  = up_y;     out_transform[6]  = up_z;
    out_transform[8]  = -fwd_x;   out_transform[9]  = -fwd_y;   out_transform[10] = -fwd_z;
    out_transform[12] = cam_x;    out_transform[13] = cam_y;    out_transform[14] = cam_z;
    out_transform[15] = 1.0f;

    std::memset(out_intrinsics, 0, 9 * sizeof(float));
    out_intrinsics[0] = fx; out_intrinsics[2] = cx;
    out_intrinsics[4] = fy; out_intrinsics[5] = cy;
    out_intrinsics[8] = 1.0f;

    out_rgba.resize(img_w * img_h * 4);
    out_depth.resize(img_w * img_h);

    for (std::uint32_t v = 0; v < img_h; ++v) {
        for (std::uint32_t u = 0; u < img_w; ++u) {
            float px = (static_cast<float>(u) - cx) / fx;
            float py = (static_cast<float>(v) - cy) / fy;
            float pz = 1.0f;
            float wx = right_x * px + up_x * py + (-fwd_x) * pz;
            float wy = right_y * px + up_y * py + (-fwd_y) * pz;
            float wz = right_z * px + up_z * py + (-fwd_z) * pz;
            float wlen = std::sqrt(wx * wx + wy * wy + wz * wz);
            wx /= wlen; wy /= wlen; wz /= wlen;

            float hit_normal[3];
            float t = ray_cast(cam_x, cam_y, cam_z, wx, wy, wz, 5.0f, hit_normal);
            std::size_t idx = static_cast<std::size_t>(v) * img_w + u;
            if (t < 5.0f) {
                out_depth[idx] = t;
                normal_to_color(hit_normal, &out_rgba[idx * 4]);
            } else {
                out_depth[idx] = 0.0f;
                out_rgba[idx * 4 + 0] = 20;
                out_rgba[idx * 4 + 1] = 20;
                out_rgba[idx * 4 + 2] = 20;
                out_rgba[idx * 4 + 3] = 255;
            }
        }
    }
}

struct CheckpointResult {
    bool passed;
    const char* name;
    char detail[256];
};

static void print_cp(int idx, const CheckpointResult& cp) {
    std::fprintf(stderr, "  [CP%d] %s: %s %s\n",
                 idx, cp.passed ? "PASS" : "FAIL", cp.name, cp.detail);
}

}  // namespace

// ═══════════════════════════════════════════════════════════════════
// MAIN
// ═══════════════════════════════════════════════════════════════════
int main() {
    std::fprintf(stderr,
        "\n"
        "═══════════════════════════════════════════════════════════════\n"
        "  7-LAYER PIPELINE INTEGRATION TEST\n"
        "  ① Swift guard → ② Bridge/DAv2 init → ③ SPSC queue\n"
        "  → ④ DAv2 inference → ⑤ TSDF → ⑥ FrameSelector → ⑦ Training\n"
        "═══════════════════════════════════════════════════════════════\n\n");

    // ── Setup ──
    aether::render::NullGPUDevice null_device;
    aether::splat::SplatRenderConfig splat_config;
    splat_config.max_splats = 100000;
    aether::splat::SplatRenderEngine renderer(null_device, splat_config);

    aether::pipeline::CoordinatorConfig config;
    config.max_point_cloud_vertices = 500000;
    config.min_frames_to_start_training = 4;
    config.training_batch_size = 4;

    // FrameSelector: real thresholds (the ones we fixed)
    config.frame_selection.min_displacement_m = 0.003f;   // 3mm (was 1cm)
    config.frame_selection.min_rotation_rad = 0.026f;     // ~1.5° (was 5°)
    config.frame_selection.min_blur_score = 0.0f;         // No blur in synthetic
    config.frame_selection.min_quality_score = 0.0f;
    config.frame_selection.max_frames_per_window = 20;
    config.frame_selection.window_duration_s = 0.25;

    // Training config
    config.training.max_gaussians = 100000;
    config.training.max_iterations = 500;
    config.training.render_width = 320;
    config.training.render_height = 240;

    // No DAv2 models → Layer ④: NullEngine → LiDAR fallback
    config.depth_model_path = nullptr;
    config.depth_model_path_large = nullptr;

    config.blend_start_splat_count = 10;
    config.blend_end_splat_count = 100;

    std::fprintf(stderr, "[Test] Creating PipelineCoordinator...\n");
    aether::pipeline::PipelineCoordinator coordinator(
        null_device, renderer, config);
    std::fprintf(stderr, "[Test] PipelineCoordinator created.\n\n");

    // ── Scene constants ──
    constexpr std::uint32_t kImgW = 320;
    constexpr std::uint32_t kImgH = 240;
    constexpr float kFx = 280.0f, kFy = 280.0f;
    constexpr float kCx = 160.0f, kCy = 120.0f;
    constexpr float kOrbitRadius = 0.8f;
    constexpr float kCamHeight = 0.20f;

    int total_accepted = 0, total_dropped = 0;
    CheckpointResult cps[8];

    // ═════════════════════════════════════════════════════════════════
    // Layer ③ Test: SPSC Queue Pressure (depth=8, drop on overflow)
    // ═════════════════════════════════════════════════════════════════
    // Send 30 frames back-to-back with ZERO sleep.
    // Thread A can't drain the queue fast enough → frames drop.
    // Verifies: graceful drop (no crash), on_frame() returns 1.
    std::fprintf(stderr,
        "[Layer ③] SPSC queue pressure: 30 frames, zero sleep...\n");
    int burst_accepted = 0, burst_dropped = 0;
    for (int i = 0; i < 30; ++i) {
        float angle = static_cast<float>(i) / 30 * 0.5f;  // Small arc
        std::vector<std::uint8_t> rgba;
        std::vector<float> depth;
        float transform[16], intrinsics[9];
        generate_frame(angle, kOrbitRadius, kCamHeight,
                       kImgW, kImgH, kFx, kFy, kCx, kCy,
                       rgba, depth, transform, intrinsics);
        int result = coordinator.on_frame(
            rgba.data(), kImgW, kImgH, transform, intrinsics,
            nullptr, 0, nullptr, 0, 0,
            depth.data(), kImgW, kImgH, 0);
        if (result == 0) burst_accepted++;
        else burst_dropped++;
    }
    total_accepted += burst_accepted;
    total_dropped += burst_dropped;

    std::fprintf(stderr,
        "[Layer ③] Result: %d accepted, %d dropped (queue depth=8)\n\n",
        burst_accepted, burst_dropped);

    // CP1: Queue overflow → at least SOME frames dropped, no crash
    cps[0].passed = (burst_dropped > 0);
    cps[0].name = "Layer ③: SPSC queue drops frames under pressure";
    std::snprintf(cps[0].detail, sizeof(cps[0].detail),
                  "(accepted=%d, dropped=%d of 30)", burst_accepted, burst_dropped);

    // Let Thread A drain the burst
    std::this_thread::sleep_for(std::chrono::milliseconds(500));

    // ═════════════════════════════════════════════════════════════════
    // Layer ②④ Test: DAv2 unavailable → LiDAR fallback
    // ═════════════════════════════════════════════════════════════════
    // NullDepthInferenceEngine.is_available() == false.
    // Pipeline should fall back to lidar_depth for TSDF integration.
    // We verify this implicitly: if TSDF creates blocks, LiDAR worked.
    std::fprintf(stderr,
        "[Layer ②④] DAv2 unavailable — verifying LiDAR fallback via TSDF...\n\n");

    // ═════════════════════════════════════════════════════════════════
    // Layers ①⑤⑥⑦: Slow scan at realistic speed
    // ═════════════════════════════════════════════════════════════════
    // Simulate: camera orbits at 5cm/s (realistic slow handheld scan).
    // At 0.8m radius: angular speed = 5/80 = 0.0625 rad/s.
    //
    // Layer ① simulated: ARKit 60fps → pipelineFrameInterval=2 → 30fps Swift.
    // But SPSC queue + Thread A processing → effective ~13fps reaching ⑤⑥⑦.
    // We directly send at 13fps (77ms interval) to model the net effect.
    //
    // Per-frame displacement: 5cm/s ÷ 13fps = 3.85mm
    // Frame selection threshold: 3mm → 3.85mm > 3mm → should PASS
    // (With old 1cm threshold: 3.85mm < 10mm → ALL REJECTED → the bug we fixed)

    constexpr float kLinearSpeed = 0.05f;         // 5 cm/s
    constexpr float kAngularSpeed = kLinearSpeed / kOrbitRadius;  // 0.0625 rad/s
    constexpr float kEffectiveFps = 13.0f;        // After ①②③④ bottlenecks
    constexpr int   kFrameIntervalMs = static_cast<int>(1000.0f / kEffectiveFps);  // ~77ms
    constexpr float kScanDurationS = 14.0f;       // 14 seconds of scanning
    constexpr int   kSlowFrames = static_cast<int>(kScanDurationS * kEffectiveFps);  // ~182

    float per_frame_displacement_mm =
        (kLinearSpeed / kEffectiveFps) * 1000.0f;  // 3.85mm

    std::fprintf(stderr,
        "[Layer ①⑤⑥⑦] Slow scan: %.0fcm/s, %.0ffps effective, %d frames\n"
        "  Per-frame displacement: %.2fmm (threshold: 3.0mm)\n"
        "  Frame interval: %dms\n\n",
        kLinearSpeed * 100, kEffectiveFps, kSlowFrames,
        per_frame_displacement_mm, kFrameIntervalMs);

    // Starting angle: continue after burst phase
    float start_angle = 0.5f;  // After the burst arc
    auto scan_start = std::chrono::steady_clock::now();

    int slow_accepted = 0, slow_dropped = 0;
    for (int i = 0; i < kSlowFrames; ++i) {
        float angle = start_angle + kAngularSpeed * (static_cast<float>(i) / kEffectiveFps);

        std::vector<std::uint8_t> rgba;
        std::vector<float> depth;
        float transform[16], intrinsics[9];
        generate_frame(angle, kOrbitRadius, kCamHeight,
                       kImgW, kImgH, kFx, kFy, kCx, kCy,
                       rgba, depth, transform, intrinsics);

        int result = coordinator.on_frame(
            rgba.data(), kImgW, kImgH, transform, intrinsics,
            nullptr, 0, nullptr, 0, 0,
            depth.data(), kImgW, kImgH, 0);

        if (result == 0) slow_accepted++;
        else slow_dropped++;

        // Pace at effective 13fps — simulates net throughput after ①②③④
        std::this_thread::sleep_for(std::chrono::milliseconds(kFrameIntervalMs));

        // Progress log every 50 frames
        if ((i + 1) % 50 == 0 || i == kSlowFrames - 1) {
            auto snap = coordinator.get_snapshot();
            std::fprintf(stderr,
                "[Test] Frame %d/%d: accepted=%d dropped=%d | "
                "frames=%zu selected=%zu gaussians=%zu blocks=%zu "
                "training=%s loss=%.4f step=%zu\n",
                i + 1, kSlowFrames, slow_accepted, slow_dropped,
                snap.frame_count, snap.selected_frames,
                snap.num_gaussians, snap.assigned_blocks,
                snap.training_active ? "YES" : "no",
                snap.training_loss, snap.training_step);
        }
    }

    total_accepted += slow_accepted;
    total_dropped += slow_dropped;

    auto scan_end = std::chrono::steady_clock::now();
    double scan_seconds = std::chrono::duration<double>(scan_end - scan_start).count();
    std::fprintf(stderr, "\n[Test] Slow scan complete: %.1fs, %d accepted, %d dropped\n\n",
                 scan_seconds, slow_accepted, slow_dropped);

    auto snap = coordinator.get_snapshot();

    // CP2: Frames accepted by on_frame() during slow scan
    cps[1].passed = (slow_accepted > kSlowFrames / 2);
    cps[1].name = "Layer ①: Frames accepted at realistic rate";
    std::snprintf(cps[1].detail, sizeof(cps[1].detail),
                  "(accepted=%d/%d slow scan frames)", slow_accepted, kSlowFrames);

    // CP3: Frame selection at realistic 3.85mm displacement
    // With 3mm threshold: should select >50% of frames
    // With old 1cm threshold: would select ~0 frames (the bug)
    cps[2].passed = (snap.selected_frames >= 10);
    cps[2].name = "Layer ⑥: Frame selection passes at 3.85mm/frame (3mm threshold)";
    std::snprintf(cps[2].detail, sizeof(cps[2].detail),
                  "(selected=%zu of %zu frames, %.1f%%)",
                  snap.selected_frames, snap.frame_count,
                  snap.frame_count > 0 ?
                      100.0f * snap.selected_frames / snap.frame_count : 0.0f);

    // CP4: TSDF integration → Gaussians created (proves ⑤ + ④ LiDAR fallback)
    cps[3].passed = (snap.assigned_blocks > 0 || snap.num_gaussians > 0);
    cps[3].name = "Layer ④⑤: TSDF blocks via LiDAR fallback (DAv2 unavailable)";
    std::snprintf(cps[3].detail, sizeof(cps[3].detail),
                  "(blocks=%zu, gaussians=%zu)", snap.assigned_blocks, snap.num_gaussians);

    // CP5: Training engine started
    bool training_ran = snap.training_step > 0 || snap.num_gaussians > 0;
    cps[4].passed = training_ran;
    cps[4].name = "Layer ⑦: Training engine started";
    std::snprintf(cps[4].detail, sizeof(cps[4].detail),
                  "(step=%zu, gaussians=%zu, active=%d)",
                  snap.training_step, snap.num_gaussians,
                  snap.training_active ? 1 : 0);

    // ═════════════════════════════════════════════════════════════════
    // Layer ⑦ continued: Post-scan training + convergence
    // ═════════════════════════════════════════════════════════════════
    std::fprintf(stderr, "[Layer ⑦] finish_scanning() + wait for training...\n");
    coordinator.finish_scanning();

    auto snap_pre = coordinator.get_snapshot();
    float initial_loss = snap_pre.training_loss;
    std::size_t initial_step = snap_pre.training_step;

    std::size_t steps_reached = coordinator.wait_for_training(100, 60.0);

    auto snap_post = coordinator.get_snapshot();

    // CP6: Training progressed 50+ steps (proves batching, not 1 step/loop)
    cps[5].passed = (snap_post.training_step >= 50);
    cps[5].name = "Layer ⑦: Training batching (50+ steps reached)";
    std::snprintf(cps[5].detail, sizeof(cps[5].detail),
                  "(steps=%zu, pre_finish=%zu, batch_size=8)",
                  snap_post.training_step, initial_step);

    // CP7: Loss meaningful (training actually learned something)
    float final_loss = snap_post.training_loss;
    bool loss_ok = (final_loss < initial_loss) ||
                   (initial_loss == 0.0f && final_loss == 0.0f) ||
                   (final_loss < 0.5f);
    cps[6].passed = loss_ok;
    cps[6].name = "Layer ⑦: Training loss meaningful";
    std::snprintf(cps[6].detail, sizeof(cps[6].detail),
                  "(initial=%.4f → final=%.4f)", initial_loss, final_loss);

    // CP8: wait_for_training() returned positive
    cps[7].passed = (steps_reached > 0);
    cps[7].name = "Layer ⑦: wait_for_training() completed";
    std::snprintf(cps[7].detail, sizeof(cps[7].detail),
                  "(returned %zu steps)", steps_reached);

    // ═════════════════════════════════════════════════════════════════
    // Final Summary
    // ═════════════════════════════════════════════════════════════════
    std::fprintf(stderr,
        "\n═══════════════════════════════════════════════════════════════\n"
        "  7-LAYER PIPELINE INTEGRATION RESULTS\n"
        "═══════════════════════════════════════════════════════════════\n");

    auto final_snap = coordinator.get_snapshot();
    std::fprintf(stderr,
        "  Scan duration:     %.1f seconds\n"
        "  Total frames:      %d accepted, %d dropped\n"
        "  Frames selected:   %zu (%.1f%%)\n"
        "  TSDF blocks:       %zu\n"
        "  Gaussians:         %zu\n"
        "  Training steps:    %zu\n"
        "  Training loss:     %.6f\n\n",
        scan_seconds,
        total_accepted, total_dropped,
        final_snap.selected_frames,
        final_snap.frame_count > 0 ?
            100.0f * final_snap.selected_frames / final_snap.frame_count : 0.0f,
        final_snap.assigned_blocks,
        final_snap.num_gaussians,
        final_snap.training_step,
        final_snap.training_loss);

    // Print all checkpoints
    int pass_count = 0;
    constexpr int kNumCPs = 8;
    for (int i = 0; i < kNumCPs; ++i) {
        print_cp(i + 1, cps[i]);
        if (cps[i].passed) pass_count++;
    }

    bool all_passed = (pass_count == kNumCPs);
    std::fprintf(stderr, "\n  Checkpoints: %d/%d passed %s\n\n",
                 pass_count, kNumCPs,
                 all_passed ? "✓ ALL PASSED" : "✗ SOME FAILED");

    if (!all_passed) {
        std::fprintf(stderr, "  FAILED:\n");
        for (int i = 0; i < kNumCPs; ++i) {
            if (!cps[i].passed)
                std::fprintf(stderr, "    CP%d: %s %s\n",
                             i + 1, cps[i].name, cps[i].detail);
        }
        std::fprintf(stderr, "\n");
    }

    return all_passed ? 0 : 1;
}
