// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_PIPELINE_LOCAL_SUBJECT_FIRST_TRAINING_H
#define AETHER_PIPELINE_LOCAL_SUBJECT_FIRST_TRAINING_H

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <vector>

#include "aether/pipeline/streaming_pipeline.h"
#include "aether/splat/packed_splats.h"

namespace aether {
namespace pipeline {
namespace local_subject_first_training {

inline constexpr std::size_t kImportedVideoInitialSeedCap = 30000u;
inline constexpr std::uint32_t kImportedVideoMinSeedFramesFloor = 10u;
inline constexpr std::uint32_t kImportedVideoMinTrainingFramesFloor = 10u;
inline constexpr std::uint32_t kImportedVideoMinIngestedFramesFloor = 12u;
inline constexpr std::size_t kImportedVideoMinSeedGaussians = 6000u;
inline constexpr std::size_t kImportedVideoSupportTopUpTargetGaussians = 12000u;
inline constexpr std::uint64_t kImportedVideoDegradedReadyMinElapsedMs = 3500u;
inline constexpr float kImportedVideoMvsPrimaryPriorRange = 6.0f;
inline constexpr std::uint32_t kImportedVideoMvsPrimaryPriorLevels = 0u;
inline constexpr std::size_t kLocalSubjectFirstMaxTrainingFrames = 24u;
inline constexpr std::size_t kCloudDefaultMaxTrainingFrames = 30u;
inline constexpr std::size_t kLocalSubjectFirstBaseTrainingSteps = 1400u;
inline constexpr std::size_t kCloudDefaultBaseTrainingSteps = 3000u;

std::size_t max_training_frames_for_mode(
    bool local_subject_first_mode) noexcept;

std::size_t training_base_steps_for_mode(
    bool local_subject_first_mode,
    std::size_t configured_max_iterations) noexcept;

bool align_to_baseline_3dgs_for_mode(
    bool local_subject_first_mode) noexcept;

const char* training_mode_name(
    bool local_subject_first_mode) noexcept;

bool apply_capture_hold_if_needed(
    bool local_subject_first_mode,
    bool scanning_active,
    std::vector<splat::GaussianParams>& pending_gaussians,
    bool& capture_hold_logged) noexcept;

struct ImportedVideoSeedBootstrapResult {
    bool has_any_imported_video_frames{false};
    bool preview_only{false};
    bool attempted{false};
    bool waiting_for_more_depth_frames{false};
    std::size_t depth_frame_count{0};
    std::uint32_t min_seed_frames{0};
    std::size_t preview_initial_seed_cap{0};
    std::size_t min_seed_gaussians{0};
    bool seed_evidence_sufficient{false};
    std::uint64_t phase_elapsed_ms{0};
    std::vector<splat::GaussianParams> seeds;
};

ImportedVideoSeedBootstrapResult maybe_build_imported_video_seed_bootstrap(
    const std::vector<SelectedFrame>& all_frames,
    std::size_t min_frames_to_start_training,
    std::size_t default_preview_initial_seed_cap,
    std::size_t training_render_width,
    std::size_t training_render_height,
    std::size_t last_seed_attempt_depth_frames,
    float dav2_affine_scale,
    float dav2_affine_shift) noexcept;

struct ImportedVideoTrainingGateState {
    bool preview_only{false};
    std::uint32_t min_training_frames{0};
    std::size_t preview_initial_seed_cap{0};
    std::size_t min_seed_gaussians{0};
    bool degraded_seed_fallback_ready{false};
    bool degraded_engine_ready{false};
    bool primary_engine_ready{false};
    bool ready_to_create_engine{false};
};

struct TrainingLoopLocalState {
    bool local_subject_first_mode{false};
    bool scan_finished{false};
    bool tsdf_idle{false};
    std::uint32_t preview_frames_ingested{0};
    std::uint32_t preview_depth_results_ready{0};
    std::uint32_t preview_selected_frames{0};
    std::uint32_t preview_seed_candidates{0};
    std::uint32_t preview_seed_accepted{0};
    std::uint32_t preview_frames_enqueued{0};
    std::uint64_t preview_elapsed_ms{0};
    ImportedVideoTrainingGateState imported_video_gate;
};

TrainingLoopLocalState make_training_loop_local_state(
    bool local_subject_first_mode,
    const std::vector<SelectedFrame>& all_frames,
    std::size_t min_frames_to_start_training,
    std::uint32_t preview_frames_ingested,
    std::uint32_t preview_depth_results_ready,
    std::uint32_t preview_selected_frames,
    std::uint32_t preview_seed_candidates,
    std::uint32_t preview_seed_accepted,
    std::uint32_t preview_frames_enqueued,
    bool scanning_active,
    bool tsdf_idle,
    std::size_t pending_gaussian_count,
    std::chrono::steady_clock::time_point preview_started_at,
    std::chrono::steady_clock::time_point now) noexcept;

bool should_attempt_imported_video_seed_bootstrap(
    const TrainingLoopLocalState& state,
    bool engine_created,
    bool pending_gaussians_empty,
    bool preview_dav2_seed_initialized,
    bool has_frames) noexcept;

struct DegradedTsdfFallbackPlan {
    bool should_seed{false};
    std::size_t max_points{0};
    bool preview_only{false};
};

DegradedTsdfFallbackPlan make_degraded_tsdf_fallback_plan(
    const TrainingLoopLocalState& state,
    bool engine_created,
    bool pending_gaussians_empty,
    std::size_t all_frame_count) noexcept;

void log_degraded_tsdf_fallback(
    const DegradedTsdfFallbackPlan& plan,
    std::size_t seeded) noexcept;

struct ImportedVideoGeometryTopUpPlan {
    bool should_top_up{false};
    bool post_engine{false};
    std::size_t current_support_gaussians{0};
    std::size_t target_support_gaussians{0};
    std::size_t requested_max_points{0};
};

ImportedVideoGeometryTopUpPlan make_imported_video_geometry_topup_plan(
    const TrainingLoopLocalState& state,
    bool engine_created,
    std::size_t current_support_gaussians,
    bool pre_engine_topup_applied,
    bool post_engine_topup_applied) noexcept;

void log_imported_video_geometry_topup(
    const ImportedVideoGeometryTopUpPlan& plan,
    std::size_t seeded) noexcept;

ImportedVideoTrainingGateState evaluate_imported_video_training_gate(
    const std::vector<SelectedFrame>& all_frames,
    std::size_t min_frames_to_start_training,
    std::size_t default_preview_initial_seed_cap,
    std::uint32_t preview_frames_ingested,
    std::uint32_t preview_depth_results_ready,
    std::uint32_t preview_selected_frames,
    std::uint32_t preview_frames_enqueued,
    std::uint64_t preview_elapsed_ms,
    bool scanning_active,
    bool tsdf_idle,
    std::size_t pending_gaussian_count) noexcept;

void maybe_log_imported_video_training_gate_wait(
    std::uint32_t& diag_counter,
    const ImportedVideoTrainingGateState& gate_state,
    std::uint32_t preview_selected_frames,
    std::uint32_t preview_seed_accepted,
    std::uint32_t preview_seed_candidates,
    std::uint32_t preview_frames_ingested,
    std::uint32_t preview_depth_results_ready,
    std::uint64_t preview_elapsed_ms,
    bool features_frozen,
    bool tsdf_idle,
    std::size_t pending_gaussian_count) noexcept;

}  // namespace local_subject_first_training
}  // namespace pipeline
}  // namespace aether

#endif  // AETHER_PIPELINE_LOCAL_SUBJECT_FIRST_TRAINING_H
