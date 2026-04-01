// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_PIPELINE_STREAMING_PIPELINE_H
#define AETHER_PIPELINE_STREAMING_PIPELINE_H

#ifdef __cplusplus

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <thread>
#include <vector>

#include "aether/core/spsc_queue.h"
#include "aether/core/status.h"
#include "aether/core/triple_buffer.h"
#include "aether/capture/frame_selector.h"
#include "aether/render/gpu_device.h"
#include "aether/splat/packed_splats.h"
#include "aether/splat/splat_render_engine.h"
#include "aether/training/gaussian_training_engine.h"

namespace aether {
namespace pipeline {

// ═══════════════════════════════════════════════════════════════════════
// StreamingPipeline: 4-thread coordinator for scan→train→render
// ═══════════════════════════════════════════════════════════════════════
// Thread model:
//   Thread 0 (main):  on_frame() — enqueues to eval, <1ms
//   Thread 1 (eval):  frame selector → JPEG compress → enqueue to training
//   Thread 2 (train): MVS init → training loop → push_splats
//   Thread 3 (I/O):   JPEG write + checkpoint
//
// All inter-thread communication is lock-free (SPSC queue + triple buffer).

struct StreamingConfig {
    std::size_t min_frames_to_start_training{20};
    std::size_t training_batch_size{4};
    float low_quality_loss_weight{0.3f};
    capture::FrameSelectionConfig frame_selection;
    training::TrainingConfig training;
};

/// Splat update published from training thread to main thread.
struct SplatUpdate {
    std::vector<splat::GaussianParams> splats;
    std::size_t region_idx{0};
};

/// Selected frame metadata passed from eval to training thread.
struct SelectedFrame {
    std::vector<std::uint8_t> rgba;  // Pixel data copy
    std::uint32_t width;
    std::uint32_t height;
    float transform[16];
    float intrinsics[4];
    float quality_score;
    bool is_test_frame;

    // Bug 0.26 fix: preserve temporal metadata for temporal-focal training.
    // Without these, training frames cannot be ordered by capture time,
    // blocking time-based focal window sampling.
    double timestamp{0.0};         // Capture timestamp (seconds since epoch)
    std::uint64_t frame_index{0};  // Sequential frame index from capture
    bool imported_video{false};    // True for album-video local_preview path

    // Monocular depth prior from Neural Engine (may be empty if unavailable).
    // Row-major float map. Semantics are carried by `ne_depth_is_metric`:
    //   false -> relative / disparity-like prior that needs affine calibration
    //   true  -> metric depth in meters and can be used directly
    std::vector<float> ne_depth;
    std::uint32_t ne_depth_w{0};
    std::uint32_t ne_depth_h{0};
    bool ne_depth_is_metric{false};

    // LiDAR metric depth (optional, Pro devices only — "120% enhancement").
    // Direct metric depth in meters from ARKit sceneDepth (256×192 Float32).
    // Empty on non-LiDAR devices. When available, provides absolute depth
    // constraint that supplements DAv2's relative Pearson loss.
    std::vector<float> lidar_depth;
    std::uint32_t lidar_w{0};          // 256 (ARKit sceneDepth)
    std::uint32_t lidar_h{0};          // 192
};

/// I/O task for the I/O thread.
struct IOTask {
    std::vector<std::uint8_t> jpeg_data;
    char path[256];
};

class StreamingPipeline {
public:
    StreamingPipeline(render::GPUDevice& device,
                      splat::SplatRenderEngine& renderer,
                      const StreamingConfig& config) noexcept;
    ~StreamingPipeline() noexcept;

    // Non-copyable
    StreamingPipeline(const StreamingPipeline&) = delete;
    StreamingPipeline& operator=(const StreamingPipeline&) = delete;

    // ─── Main Thread API (must be <1ms) ───

    /// Submit a frame for evaluation. Called from main thread at 60fps.
    /// Returns immediately (enqueues to eval thread).
    void on_frame(const std::uint8_t* rgba, std::uint32_t w, std::uint32_t h,
                  const float transform[16], const float intrinsics[4],
                  double timestamp, float quality_score,
                  float blur_score) noexcept;

    // ─── State Queries (lock-free reads) ───

    bool is_training_active() const noexcept;
    training::TrainingProgress training_progress() const noexcept;
    std::size_t selected_frame_count() const noexcept;

    // ─── Control ───

    /// Stop accepting frames. Eval thread drains queue, appends S0-S4 to training.
    void finish_scanning() noexcept;

    /// Request additional training iterations.
    void request_enhance(std::size_t extra_iterations) noexcept;

    /// Set thermal state (propagated to training engine).
    void set_thermal_state(int level) noexcept;

    /// Export final PLY (blocks until complete).
    core::Status export_ply(const char* path) noexcept;

private:
    render::GPUDevice& device_;
    splat::SplatRenderEngine& renderer_;
    StreamingConfig config_;

    // Frame selector (eval thread)
    capture::FrameSelector frame_selector_;

    // Training engine (training thread)
    training::GaussianTrainingEngine* training_engine_{nullptr};

    // ─── Inter-Thread Communication ───

    // Frame candidate from main → eval
    struct FrameEnvelope {
        std::vector<std::uint8_t> rgba;
        std::uint32_t width{0};
        std::uint32_t height{0};
        float transform[16]{};
        float intrinsics[4]{};
        double timestamp{0.0};
        float quality_score{0.0f};
        float blur_score{0.0f};
    };

    core::SPSCQueue<FrameEnvelope, 16> frame_queue_;      // main → eval
    core::SPSCQueue<SelectedFrame, 64> selected_queue_;   // eval → train
    core::SPSCQueue<IOTask, 32> io_queue_;                // eval → I/O
    core::TripleBuffer<SplatUpdate> splat_updates_;       // train → main

    // ─── Threads ───
    std::thread eval_thread_;
    std::thread training_thread_;
    std::thread io_thread_;

    // ─── Control Flags ───
    std::atomic<bool> running_{false};
    std::atomic<bool> scanning_active_{false};
    std::atomic<bool> training_started_{false};
    std::atomic<std::size_t> enhance_iters_{0};
    std::atomic<int> thermal_state_{0};

    // ─── Thread Entry Points ───
    void eval_thread_func() noexcept;
    void training_thread_func() noexcept;
    void io_thread_func() noexcept;

    void start_threads() noexcept;
    void stop_threads() noexcept;
};

}  // namespace pipeline
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_PIPELINE_STREAMING_PIPELINE_H
