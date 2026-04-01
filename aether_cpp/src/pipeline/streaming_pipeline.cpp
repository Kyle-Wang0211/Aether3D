// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/pipeline/streaming_pipeline.h"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstring>

#include "aether/training/mvs_initializer.h"

namespace aether {
namespace pipeline {

StreamingPipeline::StreamingPipeline(
    render::GPUDevice& device,
    splat::SplatRenderEngine& renderer,
    const StreamingConfig& config) noexcept
    : device_(device), renderer_(renderer), config_(config),
      frame_selector_(config.frame_selection) {
    start_threads();
}

StreamingPipeline::~StreamingPipeline() noexcept {
    stop_threads();
    delete training_engine_;
}

// ─── Main Thread API ─────────────────────────────────────────────────

void StreamingPipeline::on_frame(
    const std::uint8_t* rgba, std::uint32_t w, std::uint32_t h,
    const float transform[16], const float intrinsics[4],
    double timestamp, float quality_score, float blur_score) noexcept
{
    if (!scanning_active_.load(std::memory_order_relaxed)) return;

    FrameEnvelope envelope;
    envelope.rgba.assign(rgba, rgba + w * h * 4);
    envelope.width = w;
    envelope.height = h;
    std::memcpy(envelope.transform, transform, 16 * sizeof(float));
    std::memcpy(envelope.intrinsics, intrinsics, 4 * sizeof(float));
    envelope.timestamp = timestamp;
    envelope.quality_score = quality_score;
    envelope.blur_score = blur_score;

    // Try push — if queue is full, drop oldest (backpressure)
    frame_queue_.try_push(std::move(envelope));

    // Check if training thread has published new splats
    if (splat_updates_.has_new_data()) {
        const auto& update = splat_updates_.read_buffer();
        if (!update.splats.empty()) {
            // Periodic publishing sends ALL Gaussians → clear + push
            renderer_.clear_splats();
            renderer_.push_splats(update.splats.data(), update.splats.size());
        }
    }
}

bool StreamingPipeline::is_training_active() const noexcept {
    return training_started_.load(std::memory_order_relaxed);
}

training::TrainingProgress StreamingPipeline::training_progress() const noexcept {
    if (training_engine_) {
        return training_engine_->progress();
    }
    return {};
}

std::size_t StreamingPipeline::selected_frame_count() const noexcept {
    return frame_selector_.selected_count();
}

void StreamingPipeline::finish_scanning() noexcept {
    scanning_active_.store(false, std::memory_order_release);
}

void StreamingPipeline::request_enhance(std::size_t extra_iterations) noexcept {
    enhance_iters_.fetch_add(extra_iterations, std::memory_order_relaxed);
}

void StreamingPipeline::set_thermal_state(int level) noexcept {
    thermal_state_.store(level, std::memory_order_relaxed);
    if (training_engine_) {
        training_engine_->set_thermal_state(level);
    }
}

core::Status StreamingPipeline::export_ply(const char* path) noexcept {
    if (!training_engine_) return core::Status::kInvalidArgument;
    return training_engine_->export_ply(path);
}

// ─── Thread Management ──────────────────────────────────────────────

void StreamingPipeline::start_threads() noexcept {
    running_.store(true, std::memory_order_release);
    scanning_active_.store(true, std::memory_order_release);

    eval_thread_ = std::thread(&StreamingPipeline::eval_thread_func, this);
    training_thread_ = std::thread(&StreamingPipeline::training_thread_func, this);
    io_thread_ = std::thread(&StreamingPipeline::io_thread_func, this);
}

void StreamingPipeline::stop_threads() noexcept {
    running_.store(false, std::memory_order_release);
    scanning_active_.store(false, std::memory_order_release);

    if (eval_thread_.joinable()) eval_thread_.join();
    if (training_thread_.joinable()) training_thread_.join();
    if (io_thread_.joinable()) io_thread_.join();
}

// ─── Eval Thread ────────────────────────────────────────────────────

void StreamingPipeline::eval_thread_func() noexcept {
    while (running_.load(std::memory_order_acquire)) {
        FrameEnvelope envelope;
        if (!frame_queue_.try_pop(envelope)) {
            // No frames available, sleep briefly
            std::this_thread::sleep_for(std::chrono::milliseconds(5));
            continue;
        }

        // Build frame candidate for selector
        capture::FrameCandidate candidate{};
        candidate.rgba_ptr = envelope.rgba.data();
        candidate.width = envelope.width;
        candidate.height = envelope.height;
        std::memcpy(candidate.transform, envelope.transform, 16 * sizeof(float));
        std::memcpy(candidate.intrinsics, envelope.intrinsics, 4 * sizeof(float));
        candidate.timestamp = envelope.timestamp;
        candidate.quality_score = envelope.quality_score;
        candidate.blur_score = envelope.blur_score;

        // Evaluate
        auto result = frame_selector_.evaluate(candidate);
        if (!result.selected) continue;

        // Build selected frame for training
        SelectedFrame selected;
        selected.rgba = std::move(envelope.rgba);
        selected.width = envelope.width;
        selected.height = envelope.height;
        std::memcpy(selected.transform, envelope.transform, 16 * sizeof(float));
        std::memcpy(selected.intrinsics, envelope.intrinsics, 4 * sizeof(float));
        selected.quality_score = envelope.quality_score;
        selected.is_test_frame = result.is_test_frame;

        // Enqueue to training
        selected_queue_.try_push(std::move(selected));
    }
}

// ─── Training Thread ────────────────────────────────────────────────

void StreamingPipeline::training_thread_func() noexcept {
    std::vector<SelectedFrame> collected_frames;

    // Phase 1: Collect minimum frames for MVS initialization
    while (running_.load(std::memory_order_acquire)) {
        SelectedFrame frame;
        if (selected_queue_.try_pop(frame)) {
            collected_frames.push_back(std::move(frame));
        }

        if (collected_frames.size() >= config_.min_frames_to_start_training) {
            break;
        }

        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }

    if (!running_.load(std::memory_order_acquire)) return;

    // Phase 2: MVS Initialization
    std::vector<training::MVSFrame> mvs_frames;
    for (const auto& f : collected_frames) {
        if (!f.is_test_frame) {
            training::MVSFrame mf;
            mf.rgba = f.rgba.data();
            mf.width = f.width;
            mf.height = f.height;
            std::memcpy(mf.transform, f.transform, 16 * sizeof(float));
            std::memcpy(mf.intrinsics, f.intrinsics, 4 * sizeof(float));
            mvs_frames.push_back(mf);
        }
    }

    std::vector<splat::GaussianParams> initial_points;
    training::MVSConfig mvs_config;
    mvs_config.depth_width = config_.training.render_width / 2;
    mvs_config.depth_height = config_.training.render_height / 2;

    if (!mvs_frames.empty()) {
        training::mvs_initialize(
            mvs_frames.data(), mvs_frames.size(),
            mvs_config, initial_points);
        std::fprintf(stderr, "[Aether3D][Streaming] MVS init: %zu points from %zu frames\n",
                     initial_points.size(), mvs_frames.size());
    }

    // Fallback: if MVS produced too few points, create random init
    if (initial_points.size() < 100) {
        std::fprintf(stderr, "[Aether3D][Streaming] MVS fallback: %zu → 1000 random points\n",
                     initial_points.size());
        initial_points.resize(1000);
        for (auto& g : initial_points) {
            g.position[0] = (rand() % 1000 - 500) / 500.0f;
            g.position[1] = (rand() % 1000 - 500) / 500.0f;
            g.position[2] = (rand() % 1000 - 500) / 500.0f;
            g.color[0] = g.color[1] = g.color[2] = 0.5f;
            g.opacity = 0.5f;
            g.scale[0] = g.scale[1] = g.scale[2] = 0.01f;
            g.rotation[0] = 1.0f;
            g.rotation[1] = g.rotation[2] = g.rotation[3] = 0.0f;
        }
    }

    // Create training engine
    training_engine_ = new training::GaussianTrainingEngine(
        device_, config_.training);
    training_engine_->set_initial_point_cloud(
        initial_points.data(), initial_points.size());

    // Add collected frames as training data
    for (const auto& f : collected_frames) {
        float weight = f.is_test_frame ? 0.0f :
            (f.quality_score >= 0.5f ? 1.0f : config_.low_quality_loss_weight);
        if (!f.is_test_frame) {
            const float* depth_ptr = f.ne_depth.empty()
                ? nullptr : f.ne_depth.data();
            const float* lidar_ptr = f.lidar_depth.empty()
                ? nullptr : f.lidar_depth.data();
            training_engine_->add_training_frame(
                f.rgba.data(), f.width, f.height,
                f.transform, f.intrinsics, weight,
                f.timestamp, f.frame_index,
                depth_ptr, f.ne_depth_w, f.ne_depth_h,
                lidar_ptr, f.lidar_w, f.lidar_h);
        }
    }

    // Push initial points to renderer for immediate visual feedback
    renderer_.push_splats(initial_points.data(), initial_points.size());
    std::fprintf(stderr, "[Aether3D][Streaming] Training started: %zu initial splats, "
                 "%zu frames\n", initial_points.size(), collected_frames.size());

    training_started_.store(true, std::memory_order_release);

    // Phase 3: Training loop
    std::size_t local_step = 0;
    constexpr std::size_t kSplatPublishInterval = 50;  // Push splats every 50 steps
    while (running_.load(std::memory_order_acquire)) {
        // Drain any newly selected frames
        SelectedFrame new_frame;
        while (selected_queue_.try_pop(new_frame)) {
            if (!new_frame.is_test_frame) {
                float weight = (new_frame.quality_score >= 0.5f) ?
                    1.0f : config_.low_quality_loss_weight;
                const float* depth_ptr = new_frame.ne_depth.empty()
                    ? nullptr : new_frame.ne_depth.data();
                const float* lidar_ptr = new_frame.lidar_depth.empty()
                    ? nullptr : new_frame.lidar_depth.data();
                training_engine_->add_training_frame(
                    new_frame.rgba.data(), new_frame.width, new_frame.height,
                    new_frame.transform, new_frame.intrinsics, weight,
                    new_frame.timestamp, new_frame.frame_index,
                    depth_ptr, new_frame.ne_depth_w, new_frame.ne_depth_h,
                    lidar_ptr, new_frame.lidar_w, new_frame.lidar_h);
            }
        }

        // Propagate thermal state
        training_engine_->set_thermal_state(
            thermal_state_.load(std::memory_order_relaxed));

        // Train one step
        auto step_status = training_engine_->train_step();

        if (core::is_ok(step_status)) {
            local_step++;

            // ─── Periodic splat publishing (real-time feedback) ───
            if (local_step % kSplatPublishInterval == 0) {
                std::vector<splat::GaussianParams> all_splats;
                training_engine_->export_gaussians(all_splats);
                if (!all_splats.empty()) {
                    auto& buf = splat_updates_.write_buffer();
                    buf.splats = std::move(all_splats);
                    buf.region_idx = 0;
                    splat_updates_.publish();
                }

                auto prog = training_engine_->progress();
                std::fprintf(stderr,
                    "[Aether3D][Streaming] Step %zu/%zu | loss=%.4f | "
                    "gaussians=%zu\n",
                    prog.step, prog.total_steps,
                    prog.loss, prog.num_gaussians);
            }
        }

        // Check completion
        auto prog = training_engine_->progress();
        if (prog.is_complete) {
            // Check for enhance requests
            std::size_t extra = enhance_iters_.exchange(0, std::memory_order_relaxed);
            if (extra > 0) {
                // Continue training for extra iterations
                // (would need to extend max_iterations)
                continue;
            }
            break;
        }

        // Yield CPU time
        std::this_thread::sleep_for(std::chrono::microseconds(100));
    }
}

// ─── I/O Thread ─────────────────────────────────────────────────────

void StreamingPipeline::io_thread_func() noexcept {
    while (running_.load(std::memory_order_acquire)) {
        IOTask task;
        if (io_queue_.try_pop(task)) {
            // Write JPEG to disk
            if (task.path[0] != '\0' && !task.jpeg_data.empty()) {
                std::FILE* f = std::fopen(task.path, "wb");
                if (f) {
                    std::fwrite(task.jpeg_data.data(), 1,
                                task.jpeg_data.size(), f);
                    std::fclose(f);
                }
            }
        } else {
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
        }
    }
}

}  // namespace pipeline
}  // namespace aether
