// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/pipeline/pipeline_coordinator.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>

#ifdef __APPLE__
#include <sys/sysctl.h>
#endif

#include "aether/splat/ply_loader.h"
#include "aether/training/dav2_initializer.h"
#include "aether/training/mvs_initializer.h"
#include "aether/tsdf/adaptive_resolution.h"

namespace aether {
namespace pipeline {

// ─── sRGB → Linear LUT (256 entries, built at static init) ───
namespace {
struct SRGBToLinearLUT {
    float table[256];
    SRGBToLinearLUT() noexcept {
        for (int i = 0; i < 256; ++i) {
            float s = static_cast<float>(i) / 255.0f;
            table[i] = s <= 0.04045f ? s / 12.92f
                                     : std::pow((s + 0.055f) / 1.055f, 2.4f);
        }
    }
};
static const SRGBToLinearLUT g_srgb_lut;
}  // namespace

// ═══════════════════════════════════════════════════════════════════════
// Construction / Destruction
// ═══════════════════════════════════════════════════════════════════════

PipelineCoordinator::PipelineCoordinator(
    render::GPUDevice& device,
    splat::SplatRenderEngine& renderer,
    const CoordinatorConfig& config) noexcept
    : device_(device),
      renderer_(renderer),
      config_(config),
      frame_selector_(config.frame_selection),
      thermal_predictor_(config.thermal) {

    // ─── Initialize DAv2 Dual Depth Inference Engines (C++ core layer) ───
    // Replaces Swift-layer DepthAnythingV2Bridge.
    // On iOS: runs on Neural Engine via CoreML.
    //
    // Dual-model cross-validation architecture:
    //   Small (~48MB): runs every frame, ~31ms on A14, ~25ms on A16
    //   Large (~638MB): runs every N frames, ~80ms on A14, higher quality
    //   Cross-validation: consensus depth from both models = more robust
    //
    // If model_path is nullptr or model fails to load: graceful fallback.
    // Both fail → MVS-only initialization (no crash).

    // ── Small model (primary, every frame) ──
    if (config.depth_model_path) {
        depth_engine_small_ = create_depth_inference_engine(
            config.depth_model_path, "Small");
        if (depth_engine_small_ && depth_engine_small_->is_available()) {
            std::fprintf(stderr,
                "[Aether3D] DAv2 Small engine: available (%ux%u, Neural Engine)\n",
                depth_engine_small_->model_input_width(),
                depth_engine_small_->model_input_height());
        } else {
            std::fprintf(stderr,
                "[Aether3D] DAv2 Small engine: load failed at %s\n",
                config.depth_model_path);
            depth_engine_small_.reset();
        }
    } else {
        std::fprintf(stderr,
            "[Aether3D] DAv2 Small engine: no model path configured\n");
    }

    // ── Large model (cross-validation, every N frames) ──
    // Secondary RAM check in C++ (belt-and-suspenders with Swift gate).
    // iPhone 12 (A14, 4GB): Large model ANE compilation fails, CPU fallback
    // causes memory starvation + ARKit tracking loss. Block it here too.
    {
        bool large_blocked_by_memory = false;
#ifdef __APPLE__
        std::size_t ram_bytes = 0;
        std::size_t ram_size = sizeof(ram_bytes);
        if (sysctlbyname("hw.memsize", &ram_bytes, &ram_size, nullptr, 0) == 0) {
            double ram_gb = static_cast<double>(ram_bytes) / (1024.0 * 1024.0 * 1024.0);
            std::fprintf(stderr,
                "[Aether3D] C++ RAM check: %.2f GB (Large model threshold: 5.5 GB)\n",
                ram_gb);
            if (ram_gb < 5.5) {
                large_blocked_by_memory = true;
                std::fprintf(stderr,
                    "[Aether3D] C++ RAM gate: BLOCKING Large model (%.2fGB < 5.5GB)\n",
                    ram_gb);
            }
        }
#endif
        if (config.depth_model_path_large && !large_blocked_by_memory) {
            depth_engine_large_ = create_depth_inference_engine(
                config.depth_model_path_large, "Large");
            if (depth_engine_large_ && depth_engine_large_->is_available()) {
                std::fprintf(stderr,
                    "[Aether3D] DAv2 Large engine: available (%ux%u, interval=%u)\n",
                    depth_engine_large_->model_input_width(),
                    depth_engine_large_->model_input_height(),
                    config.large_model_interval);
            } else {
                std::fprintf(stderr,
                    "[Aether3D] DAv2 Large engine: load failed at %s\n",
                    config.depth_model_path_large);
                depth_engine_large_.reset();
            }
        } else {
            if (large_blocked_by_memory && config.depth_model_path_large) {
                std::fprintf(stderr,
                    "[Aether3D] DAv2 Large engine: BLOCKED by C++ RAM gate "
                    "(path was provided but device has insufficient RAM)\n");
            } else {
                std::fprintf(stderr,
                    "[Aether3D] DAv2 Large engine: no model path configured "
                    "(single-model mode)\n");
            }
        }
    }

    if (!depth_engine_small_ && !depth_engine_large_) {
        std::fprintf(stderr,
            "[Aether3D] DAv2: both models unavailable → fallback to MVS-only\n");
    }

    // Initialize TSDF volume (replaces point cloud accumulation + quality grid)
    tsdf_volume_ = std::make_unique<tsdf::TSDFVolume>();

    start_threads();
}

PipelineCoordinator::~PipelineCoordinator() noexcept {
    stop_threads();
    delete training_engine_;
}

// ═══════════════════════════════════════════════════════════════════════
// Main Thread API
// ═══════════════════════════════════════════════════════════════════════

int PipelineCoordinator::on_frame(
    const std::uint8_t* rgba, std::uint32_t w, std::uint32_t h,
    const float* transform, const float* intrinsics,
    const float* feature_xyz, std::uint32_t feature_count,
    const float* ne_depth, std::uint32_t ne_depth_w, std::uint32_t ne_depth_h,
    const float* lidar_depth, std::uint32_t lidar_w, std::uint32_t lidar_h,
    int thermal_state) noexcept {

    if (!running_.load(std::memory_order_relaxed)) return 1;

    // Update thermal state
    thermal_predictor_.set_thermal_state(thermal_state);

    // Build FrameInput envelope
    FrameInput input;
    const std::size_t pixel_count = static_cast<std::size_t>(w) * h * 4;
    input.rgba.assign(rgba, rgba + pixel_count);
    input.width = w;
    input.height = h;
    std::memcpy(input.transform, transform, 16 * sizeof(float));
    std::memcpy(input.intrinsics, intrinsics, 9 * sizeof(float));

    const std::uint32_t clamped_features = std::min(feature_count, 1024u);
    if (feature_xyz && clamped_features > 0) {
        std::memcpy(input.feature_points, feature_xyz,
                    clamped_features * 3 * sizeof(float));
    }
    input.feature_count = clamped_features;

    // Neural Engine depth (every frame from DAv2)
    if (ne_depth && ne_depth_w > 0 && ne_depth_h > 0) {
        const std::size_t depth_size = static_cast<std::size_t>(ne_depth_w) * ne_depth_h;
        input.ne_depth.assign(ne_depth, ne_depth + depth_size);
        input.ne_depth_w = ne_depth_w;
        input.ne_depth_h = ne_depth_h;
    }

    // LiDAR depth (optional)
    if (lidar_depth && lidar_w > 0 && lidar_h > 0) {
        const std::size_t lidar_size = static_cast<std::size_t>(lidar_w) * lidar_h;
        input.lidar_depth.assign(lidar_depth, lidar_depth + lidar_size);
        input.lidar_w = lidar_w;
        input.lidar_h = lidar_h;
    }

    input.thermal_state = thermal_state;

    auto now = std::chrono::steady_clock::now();
    input.timestamp = std::chrono::duration<double>(now.time_since_epoch()).count();

    // Non-blocking enqueue (drop on overflow)
    if (!frame_queue_.try_push(std::move(input))) {
        auto drops = frame_drop_count_.fetch_add(1, std::memory_order_relaxed) + 1;
        auto total = frame_counter_.load(std::memory_order_relaxed);
        if (drops <= 5 || (drops % 30 == 0)) {
            std::fprintf(stderr,
                "[Aether3D] Frame DROPPED (%u/%u total, %.1f%% loss)\n",
                drops, total, total > 0 ? 100.0f * drops / total : 0.0f);
        }
        return 1;
    }

    frame_counter_.fetch_add(1, std::memory_order_relaxed);
    return 0;
}

EvidenceSnapshot PipelineCoordinator::get_snapshot() const noexcept {
    // const_cast safe: read_buffer() only reads the reader slot
    auto& self = const_cast<PipelineCoordinator&>(*this);
    return self.evidence_snapshot_.read_buffer();
}

PipelineCoordinator::RenderSnapshot PipelineCoordinator::get_render_snapshot() noexcept {
    // ── 区域化动画: update fly-in animations before rendering ──
    update_region_animations(0.016);  // ~60fps dt

    const auto& pc = pointcloud_buffer_.read_buffer();
    RenderSnapshot snap;
    snap.pc_vertices = pc.vertices.empty() ? nullptr : pc.vertices.data();
    snap.pc_count = pc.vertices.size();
    snap.pc_alpha = pc.blend_alpha;
    snap.tsdf_block_count = pc.tsdf_block_count;

    // Merge staging → cpu_buffer before reading.
    // Training thread writes via push_splats() which goes to staging_buffer_.
    // begin_frame() merges staging into cpu_buffer_ (+ uploads to GPU).
    // Without this call, the Swift OIR rendering path never sees splat data
    // because GaussianSplatViewController's beginFrame() only runs in the viewer.
    renderer_.begin_frame();

    const auto& packed = renderer_.packed_data();
    snap.packed_splats = packed.empty() ? nullptr : packed.data();
    snap.splat_count = packed.size();

    // Quality overlay (triple-buffered alongside point cloud, thread-safe)
    snap.overlay_vertices = pc.overlay.empty()
        ? nullptr : pc.overlay.data();
    snap.overlay_count = pc.overlay.size();

    return snap;
}

void PipelineCoordinator::finish_scanning() noexcept {
    // Freeze TSDF integration — prevents Thread A from modifying
    // TSDF volume while main thread reads it during PLY export.
    features_frozen_.store(true, std::memory_order_release);
    scanning_active_.store(false, std::memory_order_release);

    // Frame drop diagnostic summary
    auto total = frame_counter_.load(std::memory_order_relaxed);
    auto drops = frame_drop_count_.load(std::memory_order_relaxed);
    std::fprintf(stderr,
        "[Aether3D] Scan finished: %u frames accepted, %u dropped (%.1f%% loss)\n",
        total, drops, total > 0 ? 100.0f * drops / (total + drops) : 0.0f);
}

void PipelineCoordinator::set_thermal_state(int level) noexcept {
    thermal_predictor_.set_thermal_state(level);
}

void PipelineCoordinator::request_enhance(std::size_t extra_iterations) noexcept {
    enhance_iters_.fetch_add(extra_iterations, std::memory_order_relaxed);
}

core::Status PipelineCoordinator::export_ply(const char* path) noexcept {
    if (!training_started_.load(std::memory_order_acquire) || !training_engine_)
        return core::Status::kInvalidArgument;

    // Lock to prevent data race with training thread's train_step().
    // Training thread also locks this mutex around each train_step call.
    std::lock_guard<std::mutex> lock(training_export_mutex_);

    // Diagnostic: log color statistics before export
    std::vector<splat::GaussianParams> diag_splats;
    training_engine_->export_gaussians(diag_splats);
    if (!diag_splats.empty()) {
        float min_r = 1e9f, max_r = -1e9f, sum_r = 0;
        float min_g = 1e9f, max_g = -1e9f, sum_g = 0;
        float min_b = 1e9f, max_b = -1e9f, sum_b = 0;
        float min_o = 1e9f, max_o = -1e9f, sum_o = 0;
        std::size_t neg_count = 0;
        for (const auto& s : diag_splats) {
            float r = s.color[0], g = s.color[1], b = s.color[2];
            float o = s.opacity;
            if (r < min_r) min_r = r; if (r > max_r) max_r = r; sum_r += r;
            if (g < min_g) min_g = g; if (g > max_g) max_g = g; sum_g += g;
            if (b < min_b) min_b = b; if (b > max_b) max_b = b; sum_b += b;
            if (o < min_o) min_o = o; if (o > max_o) max_o = o; sum_o += o;
            if (r < 0 || g < 0 || b < 0) neg_count++;
        }
        float n = static_cast<float>(diag_splats.size());
        std::fprintf(stderr, "[Aether3D][Export] %zu gaussians | "
                     "color R[%.3f,%.3f] avg=%.3f | G[%.3f,%.3f] avg=%.3f | "
                     "B[%.3f,%.3f] avg=%.3f | opacity[%.3f,%.3f] avg=%.3f | "
                     "neg_colors=%zu\n",
                     diag_splats.size(),
                     min_r, max_r, sum_r / n,
                     min_g, max_g, sum_g / n,
                     min_b, max_b, sum_b / n,
                     min_o, max_o, sum_o / n,
                     neg_count);
    }

    return training_engine_->export_ply(path);
}

std::size_t PipelineCoordinator::wait_for_training(
    std::size_t min_steps, double timeout_seconds) noexcept
{
    if (!training_started_.load(std::memory_order_acquire) || !training_engine_) {
        // Training hasn't started — wait briefly for it to initialize.
        // Check training_started_ (acquire) BEFORE training_engine_ to establish
        // happens-before with Thread C's release after creating the engine.
        auto deadline = std::chrono::steady_clock::now() +
            std::chrono::milliseconds(static_cast<int>(timeout_seconds * 1000));
        while (!training_started_.load(std::memory_order_acquire) &&
               std::chrono::steady_clock::now() < deadline) {
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
        }
        if (!training_started_.load(std::memory_order_relaxed) || !training_engine_) {
            std::fprintf(stderr,
                "[Aether3D][Coordinator] wait_for_training: training never started\n");
            return 0;
        }
    }

    auto start_time = std::chrono::steady_clock::now();
    auto deadline = start_time +
        std::chrono::milliseconds(static_cast<int>(timeout_seconds * 1000));

    std::size_t current_step = 0;
    while (std::chrono::steady_clock::now() < deadline) {
        auto progress = training_engine_->progress();
        current_step = progress.step;

        if (current_step >= min_steps) {
            auto elapsed = std::chrono::duration<double>(
                std::chrono::steady_clock::now() - start_time).count();
            std::fprintf(stderr,
                "[Aether3D][Coordinator] wait_for_training: reached %zu steps in %.1fs "
                "(loss=%.4f, gaussians=%zu)\n",
                current_step, elapsed, progress.loss, progress.num_gaussians);
            return current_step;
        }

        // Check if training completed (all iterations done)
        if (progress.is_complete) {
            std::fprintf(stderr,
                "[Aether3D][Coordinator] wait_for_training: training completed at %zu steps "
                "(loss=%.4f)\n", current_step, progress.loss);
            return current_step;
        }

        // Sleep briefly to avoid spinning
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }

    // Timeout
    auto elapsed = std::chrono::duration<double>(
        std::chrono::steady_clock::now() - start_time).count();
    std::fprintf(stderr,
        "[Aether3D][Coordinator] wait_for_training: timeout after %.1fs at %zu/%zu steps\n",
        elapsed, current_step, min_steps);
    return current_step;
}

core::Status PipelineCoordinator::export_point_cloud_ply(const char* path) noexcept {
    if (!tsdf_volume_) return core::Status::kInvalidArgument;

    // Safety: ensure Thread A has stopped TSDF access.
    // finish_scanning() sets features_frozen_=true (release). Thread A checks it
    // (acquire) at the top of each iteration and skips all TSDF operations.
    if (!features_frozen_.load(std::memory_order_acquire)) {
        // Caller forgot to call finish_scanning() — force-freeze now.
        features_frozen_.store(true, std::memory_order_release);
    }
    // Wait for Thread A to finish any in-progress TSDF work.
    // Thread A sets tsdf_idle_=false before TSDF ops, true after.
    // Typical wait: <1ms (Thread A's TSDF work is <100ms per frame).
    // Timeout: 500ms (safety bound — should never be hit).
    for (int i = 0; i < 500 && !tsdf_idle_.load(std::memory_order_acquire); ++i) {
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }

    // Extract surface points from TSDF volume (now safe — Thread A is not accessing)
    std::vector<tsdf::SurfacePoint> surface_points;
    tsdf_volume_->extract_surface_points(surface_points, 10000000);  // 10M max

    if (surface_points.empty()) return core::Status::kInvalidArgument;

    const std::size_t N = surface_points.size();

    // ─── Compute scene bounding sphere for adaptive scale ───
    double cx = 0, cy = 0, cz = 0;
    for (const auto& sp : surface_points) {
        cx += sp.position[0];
        cy += sp.position[1];
        cz += sp.position[2];
    }
    double inv_n = 1.0 / static_cast<double>(N);
    float center_x = static_cast<float>(cx * inv_n);
    float center_y = static_cast<float>(cy * inv_n);
    float center_z = static_cast<float>(cz * inv_n);

    float max_dist2 = 0.0f;
    for (const auto& sp : surface_points) {
        float dx = sp.position[0] - center_x;
        float dy = sp.position[1] - center_y;
        float dz = sp.position[2] - center_z;
        float d2 = dx * dx + dy * dy + dz * dz;
        if (d2 > max_dist2) max_dist2 = d2;
    }
    float scene_radius = std::sqrt(max_dist2);

    float cbrt_n = std::cbrt(static_cast<float>(N));
    float adaptive_scale = std::max(scene_radius / (cbrt_n * 3.0f), 0.002f);
    adaptive_scale = std::min(adaptive_scale, std::max(scene_radius * 0.05f, 0.005f));
    if (scene_radius < 1e-4f) adaptive_scale = 0.02f;

    std::fprintf(stderr, "[Aether3D][Export] TSDF surface: N=%zu radius=%.3f "
                 "adaptive_scale=%.4f\n",
                 N, scene_radius, adaptive_scale);

    // Convert SurfacePoint → GaussianParams
    std::vector<splat::GaussianParams> gaussians;
    gaussians.reserve(N);

    for (const auto& sp : surface_points) {
        splat::GaussianParams g{};
        g.position[0] = sp.position[0];
        g.position[1] = sp.position[1];
        g.position[2] = sp.position[2];
        // Normal-based grayscale shading
        float shade = std::clamp(
            sp.normal[0] * 0.577f + sp.normal[1] * 0.577f + sp.normal[2] * 0.577f,
            0.0f, 1.0f) * 0.5f + 0.5f;
        g.color[0] = shade;
        g.color[1] = shade;
        g.color[2] = shade;
        g.opacity = std::clamp(static_cast<float>(sp.weight) / 32.0f, 0.1f, 1.0f);
        g.scale[0] = adaptive_scale;
        g.scale[1] = adaptive_scale;
        g.scale[2] = adaptive_scale;
        g.rotation[0] = 1.0f;
        g.rotation[1] = 0.0f;
        g.rotation[2] = 0.0f;
        g.rotation[3] = 0.0f;
        gaussians.push_back(g);
    }

    return splat::write_ply(path, gaussians.data(), gaussians.size());
}

bool PipelineCoordinator::is_training_active() const noexcept {
    return training_started_.load(std::memory_order_relaxed);
}

bool PipelineCoordinator::is_gpu_training() const noexcept {
    // training_started_ acquire synchronizes with Thread C's release after
    // creating training_engine_. Without this, the raw pointer read is a
    // data race (Thread C writes, main thread reads, no barrier).
    if (!training_started_.load(std::memory_order_acquire)) return false;
    if (!training_engine_) return false;
    return training_engine_->is_gpu_training();
}

training::TrainingProgress PipelineCoordinator::training_progress() const noexcept {
    if (!training_started_.load(std::memory_order_acquire)) return training::TrainingProgress{};
    if (!training_engine_) return training::TrainingProgress{};
    return training_engine_->progress();
}

// ═══════════════════════════════════════════════════════════════════════
// D4: Temporal Region State ("破镜重圆" Progressive Reveal)
// ═══════════════════════════════════════════════════════════════════════

std::size_t PipelineCoordinator::trained_region_count() const noexcept {
    if (!training_started_.load(std::memory_order_acquire)) return 0;
    if (!training_engine_) return 0;
    return training_engine_->temporal_region_count();
}

const training::TemporalRegion* PipelineCoordinator::get_region_state(
    std::size_t region_idx) const noexcept
{
    if (!training_started_.load(std::memory_order_acquire)) return nullptr;
    if (!training_engine_) return nullptr;
    return training_engine_->get_temporal_region(region_idx);
}

// ═══════════════════════════════════════════════════════════════════════
// Thread A: Frame Ingestion
// ═══════════════════════════════════════════════════════════════════════

void PipelineCoordinator::frame_thread_func() noexcept {
    FrameInput input;

    while (running_.load(std::memory_order_relaxed)) {
        if (!frame_queue_.try_pop(input)) {
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
            continue;
        }

        // ─── Thermal recommendation ───
        auto thermal = thermal_predictor_.evaluate(input.timestamp);

        // ─── Brightness analysis (low-light detection) ───
        float brightness = compute_brightness(
            input.rgba.data(), input.width, input.height);
        bool is_low_light = brightness < config_.low_light_brightness_threshold;
        low_light_mode_.store(is_low_light, std::memory_order_relaxed);

        // ─── Blur score ───
        float blur = compute_blur_score(
            input.rgba.data(), input.width, input.height);

        // Low-light: tighten blur threshold
        float blur_threshold = config_.frame_selection.min_blur_score;
        if (is_low_light) {
            blur_threshold *= config_.low_light_blur_strictness;
        }

        // ─── DAv2 Dual-Model Depth Inference (C++ core layer) ───
        // Architecture:
        //   Small: submit every frame, poll previous result (~1 frame latency)
        //   Large: submit every N frames, poll previous result (~N frame latency)
        //   Cross-validation: when both have results, merge via consensus
        // This replaces Swift-layer DepthAnythingV2Bridge.estimateAsync().

        // Small model: every frame (fast, primary)
        if (depth_engine_small_) {
            depth_engine_small_->submit_async(
                input.rgba.data(), input.width, input.height);

            DepthInferenceResult small_result;
            if (depth_engine_small_->poll_result(small_result) &&
                !small_result.depth_map.empty()) {
                latest_small_depth_ = std::move(small_result);
                has_small_depth_ = true;
            }
        }

        // Large model: every N frames (high quality, cross-validation)
        if (depth_engine_large_) {
            frame_counter_for_large_++;
            if (frame_counter_for_large_ >= config_.large_model_interval) {
                frame_counter_for_large_ = 0;
                depth_engine_large_->submit_async(
                    input.rgba.data(), input.width, input.height);
            }

            DepthInferenceResult large_result;
            if (depth_engine_large_->poll_result(large_result) &&
                !large_result.depth_map.empty()) {
                latest_large_depth_ = std::move(large_result);
                has_large_depth_ = true;
            }
        }

        // Cross-validate and produce consensus depth
        DepthInferenceResult consensus_depth;
        bool have_depth = cross_validate_depth(
            latest_small_depth_, latest_large_depth_,
            has_small_depth_, has_large_depth_,
            consensus_depth);
        if (have_depth) {
            input.ne_depth = std::move(consensus_depth.depth_map);
            input.ne_depth_w = consensus_depth.width;
            input.ne_depth_h = consensus_depth.height;
        }

        // ── Diagnostic: DAv2 depth pipeline status (first 10 frames + every 60th) ──
        {
            static std::uint32_t depth_diag_counter = 0;
            depth_diag_counter++;
            if (depth_diag_counter <= 10 || depth_diag_counter % 60 == 0) {
                std::fprintf(stderr,
                    "[Aether3D] Frame %u: DAv2 small=%s large=%s | "
                    "has_small=%d has_large=%d | depth=%s %ux%u | "
                    "ne_depth=%zu metric_scale=%.2f\n",
                    depth_diag_counter,
                    depth_engine_small_ ? "loaded" : "NULL",
                    depth_engine_large_ ? "loaded" : "NULL",
                    has_small_depth_ ? 1 : 0,
                    has_large_depth_ ? 1 : 0,
                    have_depth ? "YES" : "NO",
                    input.ne_depth_w, input.ne_depth_h,
                    input.ne_depth.size(),
                    dav2_metric_scale_);
            }
        }

        // ─── DAv2 Metric Scale Estimation ───
        // DAv2 outputs relative depth [0,1]. We need a metric multiplier.
        //
        // Two calibration sources (priority order):
        //   1. LiDAR direct: scale = mean(lidar_metric) / mean(dav2_relative)
        //      Instant, no camera movement needed. Available on LiDAR devices.
        //   2. ARKit baseline: scale = heuristic(camera_displacement, mean_relative)
        //      Requires ≥2cm camera movement. Fallback for non-LiDAR devices.
        {
            // ── Source 1: LiDAR-based instant calibration (Risk C fix) ──
            // When we have both DAv2 relative depth AND LiDAR metric depth,
            // compute scale directly. No camera movement required.
            // This fires on the very first frame with both sources available.
            if (!lidar_scale_bootstrapped_ && !input.ne_depth.empty() &&
                !input.lidar_depth.empty() && input.lidar_w > 0 && input.lidar_h > 0) {

                // Mean LiDAR metric depth (skip invalid values)
                double lidar_sum = 0.0;
                std::size_t lidar_cnt = 0;
                const std::size_t lidar_total =
                    static_cast<std::size_t>(input.lidar_w) * input.lidar_h;
                for (std::size_t i = 0; i < lidar_total; i += 4) {
                    float d = input.lidar_depth[i];
                    if (d > 0.1f && d < 8.0f && std::isfinite(d)) {
                        lidar_sum += d;
                        lidar_cnt++;
                    }
                }

                // Mean DAv2 relative depth (skip extremes)
                double dav2_sum = 0.0;
                std::size_t dav2_cnt = 0;
                for (std::size_t i = 0; i < input.ne_depth.size(); i += 8) {
                    float d = input.ne_depth[i];
                    if (d > 0.02f && d < 0.98f) {
                        dav2_sum += d;
                        dav2_cnt++;
                    }
                }

                if (lidar_cnt > 50 && dav2_cnt > 50) {
                    float mean_metric = static_cast<float>(lidar_sum / lidar_cnt);
                    float mean_relative = static_cast<float>(dav2_sum / dav2_cnt);
                    if (mean_relative > 0.01f) {
                        float lidar_scale = mean_metric / mean_relative;
                        if (lidar_scale > 0.1f && lidar_scale < 50.0f) {
                            dav2_metric_scale_ = lidar_scale;
                            scale_samples_.clear();
                            scale_samples_.push_back(lidar_scale);
                            lidar_scale_bootstrapped_ = true;
                            std::fprintf(stderr,
                                "[Aether3D] DAv2 metric scale: LiDAR-bootstrapped "
                                "= %.3f (mean_metric=%.2fm mean_rel=%.3f)\n",
                                lidar_scale, mean_metric, mean_relative);
                        }
                    }
                }
            }

            // ── Source 2: ARKit baseline estimation (original, for non-LiDAR) ──
            float cam_x = input.transform[12];
            float cam_y = input.transform[13];
            float cam_z = input.transform[14];

            if (has_prev_cam_ && !input.ne_depth.empty()) {
                float dx = cam_x - prev_cam_x_;
                float dy = cam_y - prev_cam_y_;
                float dz = cam_z - prev_cam_z_;
                float baseline = std::sqrt(dx * dx + dy * dy + dz * dz);

                if (baseline > 0.02f) {  // Only use meaningful movement (>2cm)
                    // Mean relative depth (skip near-zero and near-one)
                    double sum = 0.0;
                    std::size_t count = 0;
                    for (std::size_t i = 0; i < input.ne_depth.size(); i += 8) {
                        float d = input.ne_depth[i];
                        if (d > 0.02f && d < 0.98f) {
                            sum += d;
                            count++;
                        }
                    }
                    float mean_rel = count > 0 ? static_cast<float>(sum / count) : 0.5f;

                    // Heuristic: typical indoor scanning, mean scene depth ≈ baseline × 10-15
                    float expected_depth = std::max(baseline * 10.0f, 0.3f);
                    float scale = expected_depth / mean_rel;
                    if (scale > 0.1f && scale < 50.0f) {
                        scale_samples_.push_back(scale);
                        // Use running median (last 30 estimates)
                        if (scale_samples_.size() > 30) {
                            scale_samples_.erase(scale_samples_.begin());
                        }
                        auto tmp = scale_samples_;
                        std::sort(tmp.begin(), tmp.end());
                        dav2_metric_scale_ = tmp[tmp.size() / 2];
                    }
                }
            }
            prev_cam_x_ = cam_x;
            prev_cam_y_ = cam_y;
            prev_cam_z_ = cam_z;
            has_prev_cam_ = true;
        }

        // ─── Depth source selection ───
        // Priority: DAv2 (Neural Engine) → LiDAR (hardware) → none.
        // LiDAR is standalone fallback when DAv2 is unavailable.
        const float* depth_source = nullptr;
        std::uint32_t depth_w = 0, depth_h = 0;
        float depth_confidence = 1.0f;
        bool depth_is_metric = false;  // LiDAR depth is already metric

        if (!input.ne_depth.empty()) {
            // DAv2 relative depth [0,1] — needs metric scaling
            depth_source = input.ne_depth.data();
            depth_w = input.ne_depth_w;
            depth_h = input.ne_depth_h;
            depth_is_metric = false;

            // Low-light: reduce depth confidence
            if (is_low_light) {
                depth_confidence = std::clamp(
                    brightness / 100.0f,
                    config_.low_light_depth_weight_min, 1.0f);
            }
        } else if (!input.lidar_depth.empty()) {
            // LiDAR depth is already in meters — standalone fallback
            depth_source = input.lidar_depth.data();
            depth_w = input.lidar_w;
            depth_h = input.lidar_h;
            depth_is_metric = true;
            depth_confidence = 1.0f;
        }

        // ═══════════════════════════════════════════════════════════════
        // TSDF Integration (replaces point cloud accumulation + quality grid)
        // ═══════════════════════════════════════════════════════════════
        // Depth → metric → TSDF integrate → surface extraction + overlay.
        // Saves ~285MB vs old accumulation (480MB → 200MB TSDF).
        // TSDF provides: visualization, quality tracking, multi-frame fusion.
        //
        // Guard: skip after finish_scanning() to prevent data race with export.
        PointCloudData pc_data;
        const bool have_usable_depth = depth_source && depth_w > 0 && depth_h > 0;

        // Signal that Thread A is entering TSDF-access critical section.
        // export_point_cloud_ply() waits for tsdf_idle_ before reading.
        tsdf_idle_.store(false, std::memory_order_release);

        if (!features_frozen_.load(std::memory_order_acquire) && have_usable_depth) {
            no_depth_consecutive_ = 0;  // Depth available — reset consecutive counter

            // ── Step 1: Relative → metric depth (skip for LiDAR, already metric) ──
            const std::size_t depth_pixel_count =
                static_cast<std::size_t>(depth_w) * depth_h;
            std::vector<float> metric_depth(depth_pixel_count);
            if (depth_is_metric) {
                std::memcpy(metric_depth.data(), depth_source,
                            depth_pixel_count * sizeof(float));
            } else {
                for (std::size_t i = 0; i < depth_pixel_count; ++i) {
                    metric_depth[i] = depth_source[i] * dav2_metric_scale_;
                }
            }

            // ── Step 2: TSDF integrate ──
            // Compute adaptive voxel size from mean depth
            float mean_depth = 0.0f;
            {
                double sum = 0.0;
                std::size_t cnt = 0;
                for (std::size_t i = 0; i < depth_pixel_count; i += 16) {
                    float d = metric_depth[i];
                    if (d > 0.1f && d < 5.0f && std::isfinite(d)) {
                        sum += d;
                        cnt++;
                    }
                }
                mean_depth = cnt > 0 ? static_cast<float>(sum / cnt) : 1.0f;
            }
            float voxel_size = tsdf::continuous_voxel_size(
                mean_depth, 0.5f, false,
                tsdf::default_continuous_resolution_config());

            // Scale intrinsics from image resolution to depth map resolution
            const float sx = static_cast<float>(depth_w) / static_cast<float>(input.width);
            const float sy = static_cast<float>(depth_h) / static_cast<float>(input.height);

            tsdf::IntegrationInput tsdf_input;
            tsdf_input.depth_data = metric_depth.data();
            tsdf_input.depth_width = static_cast<int>(depth_w);
            tsdf_input.depth_height = static_cast<int>(depth_h);
            tsdf_input.voxel_size = voxel_size;
            tsdf_input.fx = input.intrinsics[0] * sx;
            tsdf_input.fy = input.intrinsics[4] * sy;
            tsdf_input.cx = input.intrinsics[2] * sx;
            tsdf_input.cy = input.intrinsics[5] * sy;
            tsdf_input.view_matrix = input.transform;
            tsdf_input.timestamp = input.timestamp;
            tsdf_input.tracking_state = 2;  // ARKit normal tracking

            tsdf::IntegrationResult tsdf_result;
            tsdf_volume_->integrate(tsdf_input, tsdf_result);

            // ── Step 3: Surface point extraction ──
            // DISABLED: Point cloud Pass 1 is disabled in Metal pipeline.
            // Skip expensive extract_surface_points() to save ~40% CPU.
            // Surface points were only used for visualization; the quality
            // overlay (Step 4) now provides the scanning feedback instead.
            // pc_data.vertices remains empty → pcCount=0 in Metal.

            // TSDF block count = scan coverage metric (replaces surface point count)
            pc_data.tsdf_block_count = tsdf_volume_->active_block_count();

            // ── Step 4: Generate quality overlay from TSDF block weights ──
            generate_overlay_vertices(pc_data);

            // ── Diagnostic: TSDF integration progress ──
            {
                static std::uint32_t tsdf_diag = 0;
                tsdf_diag++;
                if (tsdf_diag <= 10 || tsdf_diag % 60 == 0) {
                    std::fprintf(stderr,
                        "[Aether3D] TSDF[%u]: voxels=%d blocks=%d surface=%zu "
                        "features=%u voxel_size=%.3f success=%d depth_metric=%d\n",
                        tsdf_diag,
                        tsdf_result.voxels_integrated,
                        tsdf_result.blocks_updated,
                        pc_data.vertices.size(),
                        input.feature_count,
                        voxel_size,
                        tsdf_result.success ? 1 : 0,
                        depth_is_metric ? 1 : 0);
                }
            }
        } else {
            // No depth available — log diagnostic
            no_depth_consecutive_++;
            static std::uint32_t no_depth_diag = 0;
            no_depth_diag++;
            if (no_depth_diag <= 10 || no_depth_diag % 60 == 0) {
                std::fprintf(stderr,
                    "[Aether3D] Frame[%u]: NO DEPTH — ne_depth=%zu lidar=%zu "
                    "features=%u frozen=%d consecutive=%u\n",
                    no_depth_diag,
                    input.ne_depth.size(),
                    input.lidar_depth.size(),
                    input.feature_count,
                    features_frozen_.load(std::memory_order_relaxed) ? 1 : 0,
                    no_depth_consecutive_);
            }

            // Still generate overlay from existing TSDF data — heatmap must
            // persist even when no new depth arrives this frame. The overlay
            // reflects training coverage so far, not just this frame's depth.
            if (!features_frozen_.load(std::memory_order_acquire)) {
                generate_overlay_vertices(pc_data);
            }

            // ── Risk A defense: ARKit feature point fallback overlay ──
            // If TSDF has no data (overlay is empty) AND we have feature points,
            // generate "needs-depth" red overlay tiles at feature point locations.
            // This ensures the user gets SOME visual feedback even when both
            // DAv2 and LiDAR are completely unavailable (e.g., DAv2 model missing
            // from bundle on non-LiDAR device like iPhone SE/mini).
            if (pc_data.overlay.empty() && input.feature_count > 0 &&
                !features_frozen_.load(std::memory_order_acquire)) {
                const std::size_t max_fallback = std::min(
                    static_cast<std::size_t>(input.feature_count),
                    kMaxOverlayPoints);
                for (std::size_t i = 0; i < max_fallback; ++i) {
                    OverlayVertex ov;
                    ov.position[0] = input.feature_points[i * 3 + 0];
                    ov.position[1] = input.feature_points[i * 3 + 1];
                    ov.position[2] = input.feature_points[i * 3 + 2];
                    ov.normal[0] = 0.0f;
                    ov.normal[1] = 1.0f;   // Default up (feature points lack normals)
                    ov.normal[2] = 0.0f;
                    ov.size = 0.015f;       // 1.5cm half-size (smaller than TSDF tiles)
                    ov.quality = 0.0f;      // Pure red → "needs scanning + depth"
                    pc_data.overlay.push_back(ov);
                }
                if (no_depth_consecutive_ == 5) {
                    std::fprintf(stderr,
                        "[Aether3D] WARNING: 5 consecutive frames without depth! "
                        "Using ARKit feature point fallback overlay (%zu tiles). "
                        "Check: DepthAnythingV2Small.mlmodelc in app bundle?\n",
                        pc_data.overlay.size());
                }
            }
        }

        // TSDF access complete — signal idle so export_point_cloud_ply() can proceed.
        tsdf_idle_.store(true, std::memory_order_release);

        // ─── ARKit feature points (ALWAYS rendered, independent of depth) ───
        if (!features_frozen_.load(std::memory_order_acquire) &&
            input.feature_count > 0) {
            for (std::uint32_t i = 0; i < input.feature_count; ++i) {
                float px = input.feature_points[i * 3 + 0];
                float py = input.feature_points[i * 3 + 1];
                float pz = input.feature_points[i * 3 + 2];

                PointCloudVertex v;
                v.position[0] = px;
                v.position[1] = py;
                v.position[2] = pz;

                // Reproject 3D → 2D to sample real color from camera image
                float dwx = px - input.transform[12];
                float dwy = py - input.transform[13];
                float dwz = pz - input.transform[14];
                float cam_x = input.transform[0]*dwx + input.transform[1]*dwy + input.transform[2]*dwz;
                float cam_y = input.transform[4]*dwx + input.transform[5]*dwy + input.transform[6]*dwz;
                float cam_z = input.transform[8]*dwx + input.transform[9]*dwy + input.transform[10]*dwz;

                if (cam_z > 0.1f) {
                    float u = input.intrinsics[0] * cam_x / cam_z + input.intrinsics[2];
                    float vv = input.intrinsics[4] * cam_y / cam_z + input.intrinsics[5];
                    auto iu = static_cast<std::uint32_t>(u + 0.5f);
                    auto iv = static_cast<std::uint32_t>(vv + 0.5f);
                    if (iu < input.width && iv < input.height) {
                        const std::uint8_t* px_data = input.rgba.data() + (iv * input.width + iu) * 4;
                        v.color[0] = g_srgb_lut.table[px_data[2]];  // R (BGRA→RGB)
                        v.color[1] = g_srgb_lut.table[px_data[1]];  // G
                        v.color[2] = g_srgb_lut.table[px_data[0]];  // B
                    } else {
                        v.color[0] = v.color[1] = v.color[2] = 0.5f;
                    }
                } else {
                    v.color[0] = v.color[1] = v.color[2] = 0.5f;
                }
                v.size = 4.0f;
                v.alpha = 0.85f;
                pc_data.vertices.push_back(v);
            }
        }

        // ─── Point Cloud → 3DGS blend control ───
        std::size_t splat_count = renderer_.splat_count();
        float alpha = 1.0f;
        if (splat_count > static_cast<std::size_t>(config_.blend_start_splat_count)) {
            float blend_range = config_.blend_end_splat_count - config_.blend_start_splat_count;
            float blend_progress = static_cast<float>(
                splat_count - static_cast<std::size_t>(config_.blend_start_splat_count));
            alpha = 1.0f - std::clamp(blend_progress / blend_range, 0.0f, 1.0f);
        }
        pc_data.blend_alpha = alpha;
        pointcloud_alpha_.store(alpha, std::memory_order_relaxed);

        // Publish point cloud to GPU (triple buffer)
        auto& pc_buf = pointcloud_buffer_.write_buffer();
        pc_buf = std::move(pc_data);
        pointcloud_buffer_.publish();

        // ─── Frame Selection for Training ───
        bool frame_selected = false;
        if (scanning_active_.load(std::memory_order_relaxed)) {
            capture::FrameCandidate candidate;
            candidate.rgba_ptr = input.rgba.data();
            candidate.width = input.width;
            candidate.height = input.height;
            std::memcpy(candidate.transform, input.transform, sizeof(candidate.transform));
            candidate.intrinsics[0] = input.intrinsics[0];
            candidate.intrinsics[1] = input.intrinsics[4];
            candidate.intrinsics[2] = input.intrinsics[2];
            candidate.intrinsics[3] = input.intrinsics[5];
            candidate.timestamp = input.timestamp;
            candidate.quality_score = 1.0f;  // Evidence-free: always high
            candidate.blur_score = blur;

            auto sel_result = frame_selector_.evaluate(candidate);

            // ─── Frame selection diagnostic (first 20 frames + every 60th) ───
            // Gate codes: 0=selected, 1=quality, 2=blur, 3=motion, 4=rate
            {
                static std::uint32_t sel_diag_counter = 0;
                sel_diag_counter++;
                auto total_selected = selected_frame_count_.load(std::memory_order_relaxed);
                bool s6 = has_s6_quality_.load(std::memory_order_relaxed);
                if (sel_diag_counter <= 20 || sel_diag_counter % 60 == 0 ||
                    (!s6 && total_selected <= 10)) {
                    std::fprintf(stderr,
                        "[Aether3D][FrameSel] frame=%u blur=%.3f "
                        "selected=%s gate=%d | total=%zu S6+=%s "
                        "ne_depth=%s\n",
                        sel_diag_counter,
                        blur,
                        sel_result.selected ? "YES" : "NO",
                        sel_result.reject_gate,
                        total_selected,
                        s6 ? "YES" : "no",
                        input.ne_depth.empty() ? "NO" : "YES");
                }
            }

            // Note: blur check is already inside frame_selector_.evaluate() (Gate 2).
            // Removing redundant external check — the selector's threshold is authoritative.
            if (sel_result.selected) {
                // Package selected frame for training thread
                SelectedFrame sf;
                sf.rgba = std::move(input.rgba);  // Move ~8MB instead of copying
                sf.width = input.width;
                sf.height = input.height;
                std::memcpy(sf.transform, input.transform, sizeof(sf.transform));
                sf.intrinsics[0] = input.intrinsics[0];
                sf.intrinsics[1] = input.intrinsics[4];
                sf.intrinsics[2] = input.intrinsics[2];
                sf.intrinsics[3] = input.intrinsics[5];
                sf.quality_score = is_low_light ? config_.low_quality_loss_weight : 1.0f;
                sf.is_test_frame = sel_result.is_test_frame;
                // Bug 0.26 fix: pass temporal metadata to training thread
                sf.timestamp = input.timestamp;
                sf.frame_index = frame_counter_.load(std::memory_order_relaxed);

                // Carry DAv2 depth to training thread (key for initialization)
                if (!input.ne_depth.empty()) {
                    sf.ne_depth = input.ne_depth;
                    sf.ne_depth_w = input.ne_depth_w;
                    sf.ne_depth_h = input.ne_depth_h;
                }

                // Carry LiDAR metric depth to training (120% enhancement, Pro only)
                if (!input.lidar_depth.empty() && input.lidar_w > 0 && input.lidar_h > 0) {
                    sf.lidar_depth = input.lidar_depth;
                    sf.lidar_w = input.lidar_w;
                    sf.lidar_h = input.lidar_h;
                }

                selected_queue_.try_push(std::move(sf));
                selected_frame_count_.fetch_add(1, std::memory_order_relaxed);
                frame_selected = true;

                // Mark TSDF blocks covered by this training frame → heatmap
                if (tsdf_volume_) {
                    tsdf_volume_->mark_training_coverage(
                        input.transform,
                        input.intrinsics[0], input.intrinsics[4],
                        input.intrinsics[2], input.intrinsics[5],
                        input.width, input.height);
                }
            }
        }

        // ─── Build Observation → Thread B ───
        ObservationBatch obs;
        obs.frame_index = frame_counter_.load(std::memory_order_relaxed);
        obs.blur_score = blur;
        obs.brightness = brightness;
        obs.depth_confidence = depth_confidence;
        std::memcpy(obs.transform, input.transform, sizeof(obs.transform));
        std::memcpy(obs.intrinsics, input.intrinsics, sizeof(obs.intrinsics));
        obs.frame_selected = frame_selected;

        // Compute depth stats
        if (depth_source && depth_w > 0 && depth_h > 0) {
            double sum = 0.0;
            std::size_t count = 0;
            const std::size_t total = static_cast<std::size_t>(depth_w) * depth_h;
            for (std::size_t i = 0; i < total; ++i) {
                float d = depth_source[i];
                if (d > 0.0f && std::isfinite(d)) {
                    sum += d;
                    count++;
                }
            }
            if (count > 0) {
                obs.depth_mean = static_cast<float>(sum / count);
                double var_sum = 0.0;
                for (std::size_t i = 0; i < total; ++i) {
                    float d = depth_source[i];
                    if (d > 0.0f && std::isfinite(d)) {
                        double diff = d - obs.depth_mean;
                        var_sum += diff * diff;
                    }
                }
                obs.depth_variance = static_cast<float>(var_sum / count);
            }
        }

        evidence_queue_.try_push(std::move(obs));
    }
}

// ═══════════════════════════════════════════════════════════════════════
// Thread B: Evidence + Quality
// ═══════════════════════════════════════════════════════════════════════

void PipelineCoordinator::evidence_thread_func() noexcept {
    ObservationBatch obs;

    while (running_.load(std::memory_order_relaxed)) {
        if (!evidence_queue_.try_pop(obs)) {
            std::this_thread::sleep_for(std::chrono::milliseconds(5));
            continue;
        }

        evidence_frame_count_++;

        // ─── Quality accumulation ───
        // Weighted quality based on blur, brightness, and depth confidence
        float quality = obs.blur_score * obs.depth_confidence;
        if (obs.brightness < config_.low_light_brightness_threshold) {
            quality *= 0.7f;  // Penalize low-light frames in quality score
        }
        accumulated_quality_ = accumulated_quality_ * 0.95f + quality * 0.05f;

        // ─── Coverage estimation (simplified spatial hashing) ───
        // Extract camera position from transform
        float cam_x = obs.transform[12];
        float cam_y = obs.transform[13];
        float cam_z = obs.transform[14];

        // Simple coverage: unique spatial cells visited
        // (Full evidence grid integration happens later)
        if (obs.frame_selected) {
            // Each selected frame with good depth adds ~2% coverage
            accumulated_coverage_ = std::min(1.0f, accumulated_coverage_ + 0.02f);
        }

        // ─── Low-light quality tracking ───
        if (obs.brightness < config_.low_light_brightness_threshold &&
            obs.blur_score < config_.frame_selection.min_blur_score) {
            consecutive_low_quality_++;
        } else {
            consecutive_low_quality_ = 0;
        }

        // ─── Publish snapshot ───
        auto& snapshot = evidence_snapshot_.write_buffer();
        snapshot.coverage = accumulated_coverage_;
        snapshot.overall_quality = accumulated_quality_;
        snapshot.frame_count = evidence_frame_count_;
        snapshot.selected_frames = selected_frame_count_.load(std::memory_order_relaxed);
        snapshot.min_frames_needed = config_.min_frames_to_start_training;
        snapshot.thermal_level = thermal_predictor_.current_level();
        snapshot.scan_complete = !scanning_active_.load(std::memory_order_relaxed);
        snapshot.has_s6_quality = has_s6_quality_.load(std::memory_order_relaxed);

        // Guard: training_engine_ is a raw pointer written by Thread C.
        // training_started_ (atomic, release by Thread C after creating engine)
        // provides the happens-before guarantee for the pointer read.
        if (training_started_.load(std::memory_order_acquire) && training_engine_) {
            auto progress = training_engine_->progress();
            snapshot.training_active = !progress.is_complete;
            snapshot.num_gaussians = progress.num_gaussians;
            snapshot.converged_regions = progress.converged_regions;
            snapshot.total_regions = progress.total_regions;
            float total = static_cast<float>(progress.total_steps);
            snapshot.training_progress = total > 0 ?
                static_cast<float>(progress.step) / total : 0.0f;
        }

        // ── 区域化训練状態 (破镜重圆) ──
        {
            // Quick read under regions_mutex_ (lock-free would be ideal but
            // regions_mutex_ contention is negligible — training thread only
            // holds it briefly when transitioning region states).
            std::lock_guard<std::mutex> rlock(regions_mutex_);
            snapshot.training_region_total = static_cast<std::uint32_t>(training_regions_.size());
            std::uint32_t completed = 0;
            std::uint16_t active_id = 0xFFFF;
            float active_progress = 0.0f;
            bool animating = false;

            for (const auto& r : training_regions_) {
                if (r.state == TrainingRegion::State::kConverged ||
                    r.state == TrainingRegion::State::kRevealed) {
                    completed++;
                }
                if (r.state == TrainingRegion::State::kTraining) {
                    active_id = r.region_id;
                    active_progress = r.max_steps > 0
                        ? static_cast<float>(r.current_step) / static_cast<float>(r.max_steps)
                        : 0.0f;
                }
                if (r.state == TrainingRegion::State::kRevealed) {
                    animating = true;
                }
            }

            snapshot.training_region_completed = completed;
            snapshot.active_region_id = active_id;
            snapshot.active_region_progress = active_progress;
            snapshot.is_animating = animating;
            snapshot.staged_count = static_cast<std::uint32_t>(staged_regions_.size());
        }

        evidence_snapshot_.publish();
    }
}

// ═══════════════════════════════════════════════════════════════════════
// Thread C: Per-Region Training (区域化训练)
// ═══════════════════════════════════════════════════════════════════════
// Architecture: continuously collect frames → pull regions from queue →
// filter frames by frustum-AABB → initialize within AABB → train →
// publish splats as hidden → next region.
//
// This replaces the old global training approach. Each region trains
// independently with only its visible frames, producing focused Gaussians.

/// Check if a camera frustum can see an AABB (conservative test).
/// Uses frustum half-angles derived from intrinsics [fx, fy, cx, cy].
static bool frustum_intersects_aabb(
    const float transform[16],
    const float intrinsics[4],
    std::uint32_t img_w, std::uint32_t img_h,
    const float aabb_min[3], const float aabb_max[3]) noexcept
{
    // Camera position from column-major transform (last column)
    float cam_x = transform[12];
    float cam_y = transform[13];
    float cam_z = transform[14];

    // Quick distance test: if AABB center is > 15m from camera, skip
    float cx = (aabb_min[0] + aabb_max[0]) * 0.5f;
    float cy = (aabb_min[1] + aabb_max[1]) * 0.5f;
    float cz = (aabb_min[2] + aabb_max[2]) * 0.5f;
    float dx = cam_x - cx, dy = cam_y - cy, dz = cam_z - cz;
    float dist_sq = dx*dx + dy*dy + dz*dz;
    if (dist_sq > 225.0f) return false;  // 15m max

    // Project AABB corners into camera space and check if any is in view
    // Camera-to-world transform → invert to get world-to-camera
    // For orthonormal rotation: R^-1 = R^T, t^-1 = -R^T * t
    float r00 = transform[0], r01 = transform[4], r02 = transform[8];
    float r10 = transform[1], r11 = transform[5], r12 = transform[9];
    float r20 = transform[2], r21 = transform[6], r22 = transform[10];
    float tx = transform[12], ty = transform[13], tz = transform[14];

    float fx = intrinsics[0], fy = intrinsics[1];
    float ppx = intrinsics[2], ppy = intrinsics[3];

    // Check 8 AABB corners
    float corners[8][3];
    for (int i = 0; i < 8; ++i) {
        corners[i][0] = (i & 1) ? aabb_max[0] : aabb_min[0];
        corners[i][1] = (i & 2) ? aabb_max[1] : aabb_min[1];
        corners[i][2] = (i & 4) ? aabb_max[2] : aabb_min[2];
    }

    bool any_in_front = false;
    for (int i = 0; i < 8; ++i) {
        // World to camera: p_cam = R^T * (p_world - t)
        float wx = corners[i][0] - tx;
        float wy = corners[i][1] - ty;
        float wz = corners[i][2] - tz;
        float cam_lx = r00 * wx + r10 * wy + r20 * wz;
        float cam_ly = r01 * wx + r11 * wy + r21 * wz;
        float cam_lz = r02 * wx + r12 * wy + r22 * wz;

        // ARKit convention: camera looks along -Z
        float depth = -cam_lz;
        if (depth <= 0.05f) continue;

        any_in_front = true;

        // Project to pixel coordinates
        float u = fx * (cam_lx / depth) + ppx;
        float v = fy * (cam_ly / depth) + ppy;

        // Generous margin (50% of image size for partial visibility)
        float margin_x = static_cast<float>(img_w) * 0.5f;
        float margin_y = static_cast<float>(img_h) * 0.5f;

        if (u > -margin_x && u < static_cast<float>(img_w) + margin_x &&
            v > -margin_y && v < static_cast<float>(img_h) + margin_y) {
            return true;
        }
    }

    // If no corners in front, camera is inside or behind the AABB
    // Check if camera is inside the AABB (always visible)
    if (!any_in_front) {
        if (cam_x >= aabb_min[0] && cam_x <= aabb_max[0] &&
            cam_y >= aabb_min[1] && cam_y <= aabb_max[1] &&
            cam_z >= aabb_min[2] && cam_z <= aabb_max[2]) {
            return true;
        }
    }

    return false;
}

/// Filter DAv2 initial points to keep only those within an AABB.
static void filter_points_in_aabb(
    std::vector<splat::GaussianParams>& points,
    const float aabb_min[3], const float aabb_max[3]) noexcept
{
    auto it = std::remove_if(points.begin(), points.end(),
        [&](const splat::GaussianParams& g) {
            return g.position[0] < aabb_min[0] || g.position[0] > aabb_max[0] ||
                   g.position[1] < aabb_min[1] || g.position[1] > aabb_max[1] ||
                   g.position[2] < aabb_min[2] || g.position[2] > aabb_max[2];
        });
    points.erase(it, points.end());
}

void PipelineCoordinator::training_thread_func() noexcept {
    std::vector<SelectedFrame> all_frames;
    SelectedFrame sf;

    // ── Memory cap: prevent OOM ──
    // Each frame is ~8MB RGBA. Cap at 30 frames (~240MB) for 4GB devices.
    constexpr std::size_t kMaxTrainingFrames = 30;

    std::size_t last_reported_frame_count = 0;

    while (running_.load(std::memory_order_relaxed)) {
        // ── Step 1: Continuously collect selected frames ──
        while (selected_queue_.try_pop(sf)) {
            all_frames.push_back(std::move(sf));
            if (all_frames.size() > kMaxTrainingFrames) {
                all_frames.erase(all_frames.begin());
            }
        }

        // Diagnostic: frame collection progress
        if (all_frames.size() != last_reported_frame_count) {
            last_reported_frame_count = all_frames.size();
            std::fprintf(stderr,
                "[Aether3D][TrainThread] frames=%zu  S6+=%s\n",
                all_frames.size(),
                has_s6_quality_.load(std::memory_order_relaxed) ? "YES" : "no");
        }

        // ── Step 2: Pull next pending region from queue ──
        TrainingRegion* region = nullptr;
        {
            std::lock_guard<std::mutex> lock(regions_mutex_);
            if (!region_queue_.empty()) {
                auto rid = region_queue_.front();
                for (auto& r : training_regions_) {
                    if (r.region_id == rid &&
                        r.state == TrainingRegion::State::kPending) {
                        region = &r;
                        break;
                    }
                }
                if (region) {
                    region->state = TrainingRegion::State::kTraining;
                    region_queue_.pop_front();
                }
            }
        }

        if (!region || all_frames.empty()) {
            // No region ready or no frames yet — wait and retry
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
            continue;
        }

        // ── Step 3: Assign frames to this region (frustum-AABB test) ──
        region->frame_indices.clear();
        for (std::size_t i = 0; i < all_frames.size(); ++i) {
            const auto& f = all_frames[i];
            if (frustum_intersects_aabb(
                    f.transform, f.intrinsics,
                    f.width, f.height,
                    region->extended_aabb_min, region->extended_aabb_max)) {
                region->frame_indices.push_back(i);
            }
        }

        std::fprintf(stderr,
            "[Aether3D][TrainThread] Region %u: %zu/%zu frames visible, "
            "AABB=(%.2f,%.2f,%.2f)-(%.2f,%.2f,%.2f)\n",
            static_cast<unsigned>(region->region_id),
            region->frame_indices.size(), all_frames.size(),
            region->aabb_min[0], region->aabb_min[1], region->aabb_min[2],
            region->aabb_max[0], region->aabb_max[1], region->aabb_max[2]);

        if (region->frame_indices.size() < 2) {
            // Not enough visible frames — mark as failed, move on
            std::lock_guard<std::mutex> lock(regions_mutex_);
            region->state = TrainingRegion::State::kFailed;
            std::fprintf(stderr,
                "[Aether3D][TrainThread] Region %u FAILED: only %zu frames\n",
                static_cast<unsigned>(region->region_id),
                region->frame_indices.size());
            continue;
        }

        // ── Step 4: Train this region ──
        train_single_region(*region, all_frames);

        // ── Step 5: Handle enhance requests between regions ──
        std::size_t extra = enhance_iters_.exchange(0, std::memory_order_relaxed);
        if (extra > 0 && training_engine_) {
            for (std::size_t i = 0; i < extra && running_.load(std::memory_order_relaxed); ++i) {
                {
                    std::lock_guard<std::mutex> lock(training_export_mutex_);
                    training_engine_->train_step();
                }
                if ((i & 0xF) == 0xF) {
                    std::this_thread::sleep_for(std::chrono::milliseconds(1));
                }
            }
        }

        // Cleanup training engine after region is done
        if (training_engine_) {
            delete training_engine_;
            training_engine_ = nullptr;
        }
        training_started_.store(false, std::memory_order_release);
    }
}

void PipelineCoordinator::train_single_region(
    TrainingRegion& region,
    const std::vector<SelectedFrame>& all_frames) noexcept
{
    // ─── Phase 1: Initialize points within region AABB ───
    // Only use frames assigned to this region.
    std::vector<SelectedFrame> region_frames;
    region_frames.reserve(region.frame_indices.size());
    for (auto idx : region.frame_indices) {
        if (idx < all_frames.size()) {
            region_frames.push_back(all_frames[idx]);
        }
    }

    std::vector<splat::GaussianParams> initial_points;

    // Step 1a: DAv2 initialization (primary path)
    bool has_dav2 = false;
    for (const auto& f : region_frames) {
        if (!f.ne_depth.empty()) { has_dav2 = true; break; }
    }

    if (has_dav2) {
        training::DAv2Config dav2_config;
        training::dav2_initialize(
            region_frames.data(), region_frames.size(),
            dav2_config, initial_points);

        // Filter: keep only points within extended AABB
        filter_points_in_aabb(initial_points,
            region.extended_aabb_min, region.extended_aabb_max);

        std::fprintf(stderr,
            "[Aether3D][Region %u] DAv2 init: %zu points (AABB-filtered) "
            "from %zu frames\n",
            static_cast<unsigned>(region.region_id),
            initial_points.size(), region_frames.size());
    }

    // Step 1b: MVS supplement if DAv2 insufficient
    if (initial_points.size() < 5000) {
        float dav2_metric_scale = training::estimate_metric_scale(
            region_frames.data(), region_frames.size());

        std::vector<training::MVSFrame> mvs_frames;
        for (const auto& frame : region_frames) {
            if (!frame.is_test_frame) {
                training::MVSFrame mf;
                mf.rgba = frame.rgba.data();
                mf.width = frame.width;
                mf.height = frame.height;
                std::memcpy(mf.transform, frame.transform, 16 * sizeof(float));
                std::memcpy(mf.intrinsics, frame.intrinsics, 4 * sizeof(float));
                if (!frame.ne_depth.empty()) {
                    mf.dav2_depth = frame.ne_depth.data();
                    mf.dav2_w = frame.ne_depth_w;
                    mf.dav2_h = frame.ne_depth_h;
                    mf.dav2_scale = dav2_metric_scale;
                }
                mvs_frames.push_back(mf);
            }
        }

        if (mvs_frames.size() >= 3) {
            std::vector<splat::GaussianParams> mvs_points;
            training::MVSConfig mvs_config;
            mvs_config.depth_width = config_.training.render_width / 2;
            mvs_config.depth_height = config_.training.render_height / 2;
            training::mvs_initialize(
                mvs_frames.data(), mvs_frames.size(),
                mvs_config, mvs_points);

            // Filter MVS points to AABB
            filter_points_in_aabb(mvs_points,
                region.extended_aabb_min, region.extended_aabb_max);

            initial_points.insert(initial_points.end(),
                                  mvs_points.begin(), mvs_points.end());
            std::fprintf(stderr,
                "[Aether3D][Region %u] MVS supplement: +%zu points\n",
                static_cast<unsigned>(region.region_id),
                mvs_points.size());
        }
    }

    // Step 1c: Random fallback (within AABB)
    if (initial_points.size() < 100) {
        constexpr std::size_t kFallbackCount = 1000;
        std::fprintf(stderr,
            "[Aether3D][Region %u] Fallback: %zu → %zu random points in AABB\n",
            static_cast<unsigned>(region.region_id),
            initial_points.size(), kFallbackCount);
        initial_points.resize(kFallbackCount);
        float scale = 0.005f;
        for (std::size_t i = 0; i < kFallbackCount; ++i) {
            auto& g = initial_points[i];
            // Random within extended AABB
            float t0 = static_cast<float>(std::rand()) / RAND_MAX;
            float t1 = static_cast<float>(std::rand()) / RAND_MAX;
            float t2 = static_cast<float>(std::rand()) / RAND_MAX;
            g.position[0] = region.extended_aabb_min[0] +
                t0 * (region.extended_aabb_max[0] - region.extended_aabb_min[0]);
            g.position[1] = region.extended_aabb_min[1] +
                t1 * (region.extended_aabb_max[1] - region.extended_aabb_min[1]);
            g.position[2] = region.extended_aabb_min[2] +
                t2 * (region.extended_aabb_max[2] - region.extended_aabb_min[2]);
            g.color[0] = g.color[1] = g.color[2] = 0.5f;
            g.opacity = 0.5f;
            g.scale[0] = g.scale[1] = g.scale[2] = scale;
            g.rotation[0] = 1.0f;
            g.rotation[1] = g.rotation[2] = g.rotation[3] = 0.0f;
        }
    }

    // ─── Phase 2: Create Training Engine ───
    training_engine_ = new training::GaussianTrainingEngine(
        device_, config_.training);
    training_engine_->set_initial_point_cloud(
        initial_points.data(), initial_points.size());

    // Add region's visible frames
    for (const auto& frame : region_frames) {
        if (!frame.is_test_frame) {
            const float* depth_ptr = frame.ne_depth.empty()
                ? nullptr : frame.ne_depth.data();
            const float* lidar_ptr = frame.lidar_depth.empty()
                ? nullptr : frame.lidar_depth.data();
            training_engine_->add_training_frame(
                frame.rgba.data(), frame.width, frame.height,
                frame.transform, frame.intrinsics,
                frame.quality_score,
                frame.timestamp, frame.frame_index,
                depth_ptr, frame.ne_depth_w, frame.ne_depth_h,
                lidar_ptr, frame.lidar_w, frame.lidar_h);
        }
    }

    training_started_.store(true, std::memory_order_release);
    std::fprintf(stderr,
        "[Aether3D][Region %u] Training START: %zu initial splats, "
        "%zu frames\n",
        static_cast<unsigned>(region.region_id),
        initial_points.size(), region_frames.size());

    // ─── Phase 3: Training Loop (convergence-aware) ───
    // Per-region budget: adaptive based on block count.
    // More blocks = more complexity = more iterations needed.
    region.max_steps = std::clamp(
        static_cast<std::uint32_t>(region.block_count) * 100u,
        2000u, 5000u);

    constexpr std::size_t kSplatPublishInterval = 10;
    constexpr std::size_t kConvergenceWindow = 200;
    constexpr float kConvergenceThreshold = 0.001f;
    float loss_window_start = 1e9f;
    std::size_t window_start_step = 0;

    for (std::uint32_t step = 0;
         step < region.max_steps && running_.load(std::memory_order_relaxed);
         ++step) {

        // Thermal check
        auto thermal = thermal_predictor_.evaluate(
            std::chrono::duration<double>(
                std::chrono::steady_clock::now().time_since_epoch()).count());

        if (thermal.training_rate < 0.01f) {
            // Thermal throttle: pause training
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
            --step;  // Don't count paused steps
            continue;
        }

        // Execute training step
        training_engine_->set_thermal_state(
            static_cast<int>(thermal.effective_level));
        core::Status status;
        {
            std::lock_guard<std::mutex> lock(training_export_mutex_);
            status = training_engine_->train_step();
        }

        if (!core::is_ok(status)) {
            static std::uint32_t fail_count = 0;
            if (++fail_count <= 5) {
                std::fprintf(stderr,
                    "[Aether3D][Region %u] train_step FAILED step=%u\n",
                    static_cast<unsigned>(region.region_id), step);
            }
            continue;
        }

        region.current_step = step + 1;
        auto prog = training_engine_->progress();

        // Track best loss
        if (prog.loss < region.best_loss) {
            region.best_loss = prog.loss;
        }

        // Periodic splat publishing for real-time visual feedback
        if ((step + 1) % kSplatPublishInterval == 0) {
            std::vector<splat::GaussianParams> current_splats;
            {
                std::lock_guard<std::mutex> lock(training_export_mutex_);
                training_engine_->export_gaussians(current_splats);
            }

            if (!current_splats.empty()) {
                // Convert to uint8 region IDs for GPU (legacy path)
                std::vector<std::uint8_t> rids(current_splats.size(),
                    static_cast<std::uint8_t>(
                        std::min(static_cast<unsigned>(region.region_id), 31u)));
                renderer_.push_splats_with_regions(
                    current_splats.data(), rids.data(), current_splats.size());
            }

            if ((step + 1) % 100 == 0) {
                std::fprintf(stderr,
                    "[Aether3D][Region %u] Step %u/%u | loss=%.4f | "
                    "best=%.4f | gaussians=%zu\n",
                    static_cast<unsigned>(region.region_id),
                    step + 1, region.max_steps,
                    prog.loss, region.best_loss, prog.num_gaussians);
            }
        }

        // ── Convergence detection: 200-step window, loss change < 0.001 ──
        if (step - window_start_step >= kConvergenceWindow) {
            float loss_delta = std::abs(loss_window_start - prog.loss);
            if (loss_delta < kConvergenceThreshold && step > 500) {
                std::fprintf(stderr,
                    "[Aether3D][Region %u] CONVERGED at step %u "
                    "(delta=%.5f < %.3f)\n",
                    static_cast<unsigned>(region.region_id),
                    step, loss_delta, kConvergenceThreshold);
                region.current_step = step + 1;
                break;
            }
            // Reset window
            loss_window_start = prog.loss;
            window_start_step = step;
        } else if (step == 0) {
            loss_window_start = prog.loss;
            window_start_step = 0;
        }

        // Thermal rate throttle + yield
        {
            float rate = std::clamp(thermal.training_rate, 0.05f, 1.0f);
            int delay_ms = static_cast<int>(5.0f / rate);
            delay_ms = std::clamp(delay_ms, 1, 100);
            std::this_thread::sleep_for(
                std::chrono::milliseconds(delay_ms));
        }
    }

    // ─── Phase 4: Publish final splats (hidden, waiting for viewer_entered) ───
    region.gaussian_count = static_cast<std::uint32_t>(
        training_engine_->progress().num_gaussians);
    publish_region_splats(region);
}

void PipelineCoordinator::publish_region_splats(
    TrainingRegion& region) noexcept
{
    if (!training_engine_) return;

    std::vector<splat::GaussianParams> splats;
    {
        std::lock_guard<std::mutex> lock(training_export_mutex_);
        training_engine_->export_gaussians(splats);
    }

    if (splats.empty()) {
        std::lock_guard<std::mutex> lock(regions_mutex_);
        region.state = TrainingRegion::State::kFailed;
        std::fprintf(stderr,
            "[Aether3D][Region %u] publish FAILED: no splats exported\n",
            static_cast<unsigned>(region.region_id));
        return;
    }

    // Push splats with this region's ID
    // Initially hidden — fade controlled by animation orchestrator
    std::vector<std::uint8_t> region_ids(splats.size(),
        static_cast<std::uint8_t>(
            std::min(static_cast<unsigned>(region.region_id), 31u)));

    renderer_.push_splats_with_regions(
        splats.data(), region_ids.data(), splats.size());

    // Set initial fade to 0 (hidden) for this region
    // Dynamic: grows to accommodate any number of regions
    {
        std::size_t needed = static_cast<std::size_t>(region.region_id) + 1;
        std::vector<float> fade_alphas(needed, 1.0f);  // Default: visible
        fade_alphas[region.region_id] = 0.0f;           // This region: hidden
        renderer_.set_region_fade_alphas(fade_alphas.data(), needed);
    }

    // Mark region as converged and stage for animation
    {
        std::lock_guard<std::mutex> lock(regions_mutex_);
        region.state = TrainingRegion::State::kConverged;
        staged_regions_.push_back(region.region_id);
    }

    std::fprintf(stderr,
        "[Aether3D][Region %u] CONVERGED: %zu splats published (hidden), "
        "loss=%.4f, steps=%u — staged for fly-in\n",
        static_cast<unsigned>(region.region_id),
        splats.size(), region.best_loss, region.current_step);
}

// ═══════════════════════════════════════════════════════════════════════
// Frame Processing Helpers
// ═══════════════════════════════════════════════════════════════════════

float PipelineCoordinator::compute_brightness(
    const std::uint8_t* rgba, std::uint32_t w, std::uint32_t h) noexcept {
    if (!rgba || w == 0 || h == 0) return 128.0f;

    // Sample every 16th pixel for speed (~0.05ms for 1920x1080)
    const std::size_t total = static_cast<std::size_t>(w) * h;
    const std::size_t step = 16;
    double sum = 0.0;
    std::size_t count = 0;

    for (std::size_t i = 0; i < total; i += step) {
        const std::uint8_t* p = rgba + i * 4;
        // Luminance approximation: 0.299R + 0.587G + 0.114B
        sum += 0.299 * p[0] + 0.587 * p[1] + 0.114 * p[2];
        count++;
    }

    return count > 0 ? static_cast<float>(sum / count) : 128.0f;
}

float PipelineCoordinator::compute_blur_score(
    const std::uint8_t* rgba, std::uint32_t w, std::uint32_t h) noexcept {
    if (!rgba || w < 4 || h < 4) return 0.0f;

    // Tenengrad variance (gradient magnitude via Sobel, noise-robust)
    // Sample grayscale from green channel (highest SNR in Bayer pattern)
    const std::size_t stride = w * 4;
    double gradient_sum = 0.0;
    std::size_t count = 0;

    // Sample every 4th pixel for speed
    for (std::uint32_t y = 1; y < h - 1; y += 4) {
        for (std::uint32_t x = 1; x < w - 1; x += 4) {
            // Sobel Gx, Gy on green channel (index 1)
            auto g = [&](std::uint32_t px, std::uint32_t py) -> float {
                return static_cast<float>(rgba[py * stride + px * 4 + 1]);
            };

            float gx = -g(x-1, y-1) + g(x+1, y-1)
                        - 2*g(x-1, y) + 2*g(x+1, y)
                        - g(x-1, y+1) + g(x+1, y+1);

            float gy = -g(x-1, y-1) - 2*g(x, y-1) - g(x+1, y-1)
                        + g(x-1, y+1) + 2*g(x, y+1) + g(x+1, y+1);

            gradient_sum += gx * gx + gy * gy;
            count++;
        }
    }

    if (count == 0) return 0.0f;

    // Normalize to [0, 1] range
    // Typical sharp image: ~2000-5000, blurry: <500
    double avg_gradient = gradient_sum / count;
    return std::clamp(static_cast<float>(avg_gradient / 5000.0), 0.0f, 1.0f);
}

// ═══════════════════════════════════════════════════════════════════════
// DAv2 Dual-Model Cross-Validation
// ═══════════════════════════════════════════════════════════════════════
// When both Small and Large models produce depth maps:
//   1. Resample Large depth to Small resolution (or vice versa) for comparison
//   2. For each pixel: compute relative delta = |d_small - d_large| / max(d_small, d_large)
//   3. Consensus pixels (delta < 15%): use weighted average (0.3×Small + 0.7×Large)
//   4. Divergent pixels (delta >= 15%): use Large depth (higher quality, more parameters)
//   5. Result: consensus depth map with higher confidence where models agree
//
// When only one model is available: pass through its depth (no cross-validation).
// When neither is available: returns false → MVS-only path.

bool PipelineCoordinator::cross_validate_depth(
    const DepthInferenceResult& small_result,
    const DepthInferenceResult& large_result,
    bool have_small, bool have_large,
    DepthInferenceResult& consensus_out) noexcept
{
    // ── Single-model passthrough ──
    if (have_small && !have_large) {
        consensus_out = small_result;  // Copy (relative depth, already [0,1])
        return true;
    }
    if (!have_small && have_large) {
        consensus_out = large_result;
        return true;
    }
    if (!have_small && !have_large) {
        return false;
    }

    // ── Dual-model cross-validation ──
    // Use Small's resolution as output (it runs every frame, lower latency).
    // Resample Large depth map to Small's dimensions via bilinear interpolation.
    const std::uint32_t out_w = small_result.width;
    const std::uint32_t out_h = small_result.height;
    if (out_w == 0 || out_h == 0) return false;

    const std::size_t count = static_cast<std::size_t>(out_w) * out_h;
    consensus_out.depth_map.resize(count);
    consensus_out.width = out_w;
    consensus_out.height = out_h;

    const float scale_x = static_cast<float>(large_result.width) / out_w;
    const float scale_y = static_cast<float>(large_result.height) / out_h;

    constexpr float kDivergenceThreshold = 0.15f;  // 15% relative delta
    constexpr float kSmallWeight = 0.3f;
    constexpr float kLargeWeight = 0.7f;

    std::size_t consensus_count = 0;
    std::size_t divergent_count = 0;

    for (std::uint32_t y = 0; y < out_h; ++y) {
        for (std::uint32_t x = 0; x < out_w; ++x) {
            const std::size_t idx = y * out_w + x;
            float d_small = small_result.depth_map[idx];

            // Bilinear sample from Large depth map
            float lx = x * scale_x;
            float ly = y * scale_y;
            auto lx0 = static_cast<std::uint32_t>(lx);
            auto ly0 = static_cast<std::uint32_t>(ly);
            std::uint32_t lx1 = std::min(lx0 + 1, large_result.width - 1);
            std::uint32_t ly1 = std::min(ly0 + 1, large_result.height - 1);
            lx0 = std::min(lx0, large_result.width - 1);
            ly0 = std::min(ly0, large_result.height - 1);

            float fx = lx - static_cast<float>(lx0);
            float fy = ly - static_cast<float>(ly0);

            float d00 = large_result.depth_map[ly0 * large_result.width + lx0];
            float d10 = large_result.depth_map[ly0 * large_result.width + lx1];
            float d01 = large_result.depth_map[ly1 * large_result.width + lx0];
            float d11 = large_result.depth_map[ly1 * large_result.width + lx1];

            float d_large = d00 * (1 - fx) * (1 - fy) + d10 * fx * (1 - fy) +
                            d01 * (1 - fx) * fy + d11 * fx * fy;

            // Relative divergence
            float max_d = std::max(d_small, d_large);
            float delta = (max_d > 1e-6f)
                ? std::fabs(d_small - d_large) / max_d
                : 0.0f;

            if (delta < kDivergenceThreshold) {
                // Consensus: weighted average (Large model has more parameters → higher weight)
                consensus_out.depth_map[idx] = kSmallWeight * d_small + kLargeWeight * d_large;
                consensus_count++;
            } else {
                // Divergent: trust Large model (higher quality)
                consensus_out.depth_map[idx] = d_large;
                divergent_count++;
            }
        }
    }

    // Log cross-validation stats periodically (every ~30 frames)
    static std::uint32_t cv_log_counter = 0;
    if (cv_log_counter++ % 30 == 0) {
        float consensus_pct = 100.0f * consensus_count / count;
        std::fprintf(stderr,
            "[Aether3D] DAv2 cross-validation: %ux%u | consensus=%.1f%% divergent=%.1f%%\n",
            out_w, out_h, consensus_pct, 100.0f - consensus_pct);
    }

    return true;
}

// ═══════════════════════════════════════════════════════════════════════
// TSDF-driven Quality Overlay
// ═══════════════════════════════════════════════════════════════════════

void PipelineCoordinator::generate_overlay_vertices(PointCloudData& pc_data) noexcept {
    pc_data.overlay.clear();
    if (!tsdf_volume_) return;

    // ── THROTTLE: regenerate overlay periodically ──
    // Priority: fastest S6+ convergence + instant visual feedback.
    // 100ms keeps quality overlay responsive when camera moves to new areas.
    // Overlay generation itself costs only ~0.5ms, so 100ms is safe.
    const auto now = std::chrono::steady_clock::now();
    const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
        now - overlay_last_gen_time_);
    if (elapsed.count() < 100 && !overlay_cache_.empty()) {
        pc_data.overlay = overlay_cache_;
        return;
    }
    overlay_last_gen_time_ = now;

    // Z-convention is now fixed at the source: unproject() uses z_cam = -d
    // and world_to_camera() negates z_cam. TSDF block centers are in correct
    // ARKit world space — no per-frame reflection needed.

    std::vector<tsdf::BlockQualitySample> samples;
    tsdf_volume_->get_block_quality_samples(samples);

    // ── S6+ Detection: signal training thread when quality is sufficient ──
    // This is the SOLE gate for training start — no frame count involved.
    // Once ANY block reaches S6+ (quality ≥ 0.85), training can begin for it.
    if (!has_s6_quality_.load(std::memory_order_relaxed)) {
        for (const auto& s : samples) {
            if (s.occupied_count > 0 && s.composite_quality >= 0.85f) {
                has_s6_quality_.store(true, std::memory_order_release);
                std::fprintf(stderr,
                    "[Aether3D] S6+ DETECTED: block at (%.2f,%.2f,%.2f) quality=%.3f "
                    "— training gate OPEN\n",
                    s.center[0], s.center[1], s.center[2], s.composite_quality);
                break;
            }
        }
    }

    for (const auto& s : samples) {
        if (pc_data.overlay.size() >= kMaxOverlayPoints) break;

        // Skip blocks with no occupied voxels or negligible weight
        if (s.occupied_count == 0) continue;
        if (s.avg_weight < 1.0f) continue;

        // Skip blocks that have reached S6+ quality (fully transparent).
        // Quality is monotonically increasing (Lyapunov guarantee).
        if (s.composite_quality >= 0.95f) continue;

        OverlayVertex ov;
        ov.position[0] = s.center[0];
        ov.position[1] = s.center[1];
        ov.position[2] = s.center[2];
        ov.normal[0] = s.normal[0];
        ov.normal[1] = s.normal[1];
        ov.normal[2] = s.normal[2];
        ov.size = 0.04f;  // 4cm half-size = block_world/2 → quad fills entire 8cm block face (no gaps, no overlap)
        ov.quality = s.composite_quality;
        pc_data.overlay.push_back(ov);
    }

    // Cache for subsequent frames within throttle window
    overlay_cache_ = pc_data.overlay;

    // ── 区域化训练: form regions from S6+ blocks ──
    // Connected-component clustering of S6+ blocks every overlay cycle.
    form_training_regions(samples);
}

// ═══════════════════════════════════════════════════════════════════════
// 区域化訓練: Region Formation + Animation
// ═══════════════════════════════════════════════════════════════════════

void PipelineCoordinator::signal_viewer_entered() noexcept {
    viewer_entered_.store(true, std::memory_order_release);
    std::fprintf(stderr, "[Aether3D] Viewer entered — starting region fly-in animations\n");
}

void PipelineCoordinator::form_training_regions(
    const std::vector<tsdf::BlockQualitySample>& samples) noexcept {

    // Collect unassigned S6+ blocks
    std::vector<tsdf::BlockIndex> s6_blocks;
    // Adaptive voxel size: use mid-range as representative for block indexing.
    // Individual blocks may have different actual voxel sizes (near/mid/far),
    // but for spatial hashing and neighbor detection we use a uniform grid.
    constexpr float voxel_size = tsdf::VOXEL_SIZE_MID;  // 0.01m
    const float block_world_size = voxel_size * static_cast<float>(tsdf::BLOCK_SIZE);

    // Current time for region timestamp (blocks just reached S6+ in this cycle)
    double detection_time = std::chrono::duration<double>(
        std::chrono::steady_clock::now().time_since_epoch()).count();

    for (const auto& s : samples) {
        if (s.occupied_count == 0) continue;
        if (s.composite_quality < 0.85f) continue;

        // Convert world center to block index
        tsdf::BlockIndex idx(
            static_cast<int32_t>(std::floor(s.center[0] / block_world_size)),
            static_cast<int32_t>(std::floor(s.center[1] / block_world_size)),
            static_cast<int32_t>(std::floor(s.center[2] / block_world_size)));

        auto key = block_hash_key(idx);
        if (assigned_blocks_.count(key) > 0) continue;

        s6_blocks.push_back(idx);
    }

    if (s6_blocks.empty()) return;

    // ── 26-connected component clustering ──
    // Build adjacency via spatial hashing, then BFS flood fill.
    std::unordered_set<std::int64_t> s6_set;
    std::unordered_map<std::int64_t, std::size_t> s6_idx_map;
    for (std::size_t i = 0; i < s6_blocks.size(); ++i) {
        auto key = block_hash_key(s6_blocks[i]);
        s6_set.insert(key);
        s6_idx_map[key] = i;
    }

    std::vector<bool> visited(s6_blocks.size(), false);
    // 26-neighbor offsets (face + edge + corner adjacency)
    static const int dx[] = {-1,-1,-1,-1,-1,-1,-1,-1,-1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1};
    static const int dy[] = {-1,-1,-1, 0, 0, 0, 1, 1, 1,-1,-1,-1, 0, 0, 1, 1, 1,-1,-1,-1, 0, 0, 0, 1, 1, 1};
    static const int dz[] = {-1, 0, 1,-1, 0, 1,-1, 0, 1,-1, 0, 1,-1, 1,-1, 0, 1,-1, 0, 1,-1, 0, 1,-1, 0, 1};

    std::vector<std::vector<std::size_t>> components;

    for (std::size_t i = 0; i < s6_blocks.size(); ++i) {
        if (visited[i]) continue;

        // BFS flood fill
        std::vector<std::size_t> component;
        std::deque<std::size_t> queue;
        queue.push_back(i);
        visited[i] = true;

        while (!queue.empty()) {
            auto cur = queue.front();
            queue.pop_front();
            component.push_back(cur);

            const auto& blk = s6_blocks[cur];
            for (int n = 0; n < 26; ++n) {
                tsdf::BlockIndex neighbor(blk.x + dx[n], blk.y + dy[n], blk.z + dz[n]);
                auto nkey = block_hash_key(neighbor);
                auto it = s6_idx_map.find(nkey);
                if (it != s6_idx_map.end() && !visited[it->second]) {
                    visited[it->second] = true;
                    queue.push_back(it->second);
                }
            }
        }

        if (component.size() >= 5) {
            components.push_back(std::move(component));
        }
    }

    if (components.empty()) return;

    // ── Create TrainingRegion for each component ──
    std::lock_guard<std::mutex> lock(regions_mutex_);

    for (const auto& comp : components) {
        if (next_region_id_ >= 65535) break;  // Safety (uint16 max)

        TrainingRegion region;
        region.region_id = next_region_id_++;
        region.block_count = static_cast<std::uint32_t>(comp.size());

        // Compute AABB and centroid
        float amin[3] = {1e9f, 1e9f, 1e9f};
        float amax[3] = {-1e9f, -1e9f, -1e9f};
        double sum[3] = {0, 0, 0};

        for (auto idx : comp) {
            const auto& blk = s6_blocks[idx];
            float wx = blk.x * block_world_size + block_world_size * 0.5f;
            float wy = blk.y * block_world_size + block_world_size * 0.5f;
            float wz = blk.z * block_world_size + block_world_size * 0.5f;

            amin[0] = std::min(amin[0], wx - block_world_size * 0.5f);
            amin[1] = std::min(amin[1], wy - block_world_size * 0.5f);
            amin[2] = std::min(amin[2], wz - block_world_size * 0.5f);
            amax[0] = std::max(amax[0], wx + block_world_size * 0.5f);
            amax[1] = std::max(amax[1], wy + block_world_size * 0.5f);
            amax[2] = std::max(amax[2], wz + block_world_size * 0.5f);

            sum[0] += wx;
            sum[1] += wy;
            sum[2] += wz;

            region.blocks.push_back(blk);
            assigned_blocks_.insert(block_hash_key(blk));
        }

        double n = static_cast<double>(comp.size());
        region.centroid[0] = static_cast<float>(sum[0] / n);
        region.centroid[1] = static_cast<float>(sum[1] / n);
        region.centroid[2] = static_cast<float>(sum[2] / n);

        std::memcpy(region.aabb_min, amin, sizeof(amin));
        std::memcpy(region.aabb_max, amax, sizeof(amax));

        // Extended AABB: 2 blocks wider for seamless boundary stitching
        float ext = 2.0f * block_world_size;
        region.extended_aabb_min[0] = amin[0] - ext;
        region.extended_aabb_min[1] = amin[1] - ext;
        region.extended_aabb_min[2] = amin[2] - ext;
        region.extended_aabb_max[0] = amax[0] + ext;
        region.extended_aabb_max[1] = amax[1] + ext;
        region.extended_aabb_max[2] = amax[2] + ext;

        region.first_s6_timestamp = detection_time;

        training_regions_.push_back(std::move(region));

        std::fprintf(stderr,
            "[Aether3D][RegionForm] Region %u: %zu blocks, "
            "AABB=(%.2f,%.2f,%.2f)-(%.2f,%.2f,%.2f)\n",
            static_cast<unsigned>(training_regions_.back().region_id),
            comp.size(),
            amin[0], amin[1], amin[2],
            amax[0], amax[1], amax[2]);
    }

    // Sort region_queue by timestamp (maintain temporal order)
    // Simple: rebuild queue from training_regions_ sorted by first_s6_timestamp
    // Only include pending regions
    region_queue_.clear();
    std::vector<std::pair<double, std::uint16_t>> pending_by_time;
    for (const auto& r : training_regions_) {
        if (r.state == TrainingRegion::State::kPending) {
            pending_by_time.push_back({r.first_s6_timestamp, r.region_id});
        }
    }
    std::sort(pending_by_time.begin(), pending_by_time.end());
    for (const auto& p : pending_by_time) {
        region_queue_.push_back(p.second);
    }
}

void PipelineCoordinator::update_region_animations(double dt) noexcept {
    if (!viewer_entered_.load(std::memory_order_acquire)) return;

    std::lock_guard<std::mutex> lock(regions_mutex_);

    auto current_time = std::chrono::duration<double>(
        std::chrono::steady_clock::now().time_since_epoch()).count();

    // 1. Start fly-in for staged regions (sequential, 0.4s apart)
    for (auto it = staged_regions_.begin(); it != staged_regions_.end(); ) {
        bool can_start = true;
        if (it != staged_regions_.begin()) {
            // Check previous staged region's animation progress
            auto prev_id = *(it - 1);
            for (const auto& r : training_regions_) {
                if (r.region_id == prev_id) {
                    if (r.state != TrainingRegion::State::kRevealed) {
                        can_start = false;
                    } else {
                        float elapsed = static_cast<float>(current_time - r.anim_start_time_);
                        if (elapsed < 0.4f) can_start = false;
                    }
                    break;
                }
            }
        }

        if (can_start) {
            auto rid = *it;
            for (auto& r : training_regions_) {
                if (r.region_id == rid && r.state == TrainingRegion::State::kConverged) {
                    r.state = TrainingRegion::State::kRevealed;
                    r.anim_start_time_ = current_time;
                    std::fprintf(stderr,
                        "[Aether3D][Anim] Region %u fly-in START\n",
                        static_cast<unsigned>(rid));
                    break;
                }
            }
            it = staged_regions_.erase(it);
        } else {
            break;  // Sequential: stop at first blocked region
        }
    }

    // 2. Update animation state for all revealed regions
    for (auto& region : training_regions_) {
        if (region.state == TrainingRegion::State::kRevealed) {
            float elapsed = static_cast<float>(current_time - region.anim_start_time_);
            float duration = 1.2f;
            float progress = std::clamp(elapsed / duration, 0.0f, 1.0f);

            // Easing: easeOutBack with ~10% overshoot
            auto ease_out_back = [](float t) -> float {
                constexpr float c1 = 1.70158f;
                constexpr float c3 = c1 + 1.0f;
                float tm1 = t - 1.0f;
                return 1.0f + c3 * tm1 * tm1 * tm1 + c1 * tm1 * tm1;
            };

            // For now, use region_fade_alphas as the animation vehicle
            // (Phase 6 will replace with full RegionAnimState GPU buffer)
            float fade = std::clamp(progress / 0.3f, 0.0f, 1.0f);

            // Apply to renderer's region fade (dynamic, no limit)
            {
                std::size_t needed = static_cast<std::size_t>(region.region_id) + 1;
                std::vector<float> fade_alphas(needed, 1.0f);
                fade_alphas[region.region_id] = fade;
                renderer_.set_region_fade_alphas(fade_alphas.data(), needed);
            }
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════
// Thread Lifecycle
// ═══════════════════════════════════════════════════════════════════════

void PipelineCoordinator::start_threads() noexcept {
    running_.store(true, std::memory_order_release);
    scanning_active_.store(true, std::memory_order_release);

    frame_thread_ = std::thread(&PipelineCoordinator::frame_thread_func, this);
    evidence_thread_ = std::thread(&PipelineCoordinator::evidence_thread_func, this);
    training_thread_ = std::thread(&PipelineCoordinator::training_thread_func, this);
}

void PipelineCoordinator::stop_threads() noexcept {
    running_.store(false, std::memory_order_release);

    if (frame_thread_.joinable()) frame_thread_.join();
    if (evidence_thread_.joinable()) evidence_thread_.join();
    if (training_thread_.joinable()) training_thread_.join();
}

}  // namespace pipeline
}  // namespace aether
