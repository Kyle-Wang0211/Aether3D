// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/pipeline/local_subject_first_training.h"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <vector>

#include "aether/pipeline/local_subject_first_fallback_seeding.h"
#include "aether/training/dav2_initializer.h"
#include "aether/training/mvs_initializer.h"

namespace aether {
namespace pipeline {
namespace local_subject_first_training {
namespace {

inline bool has_any_imported_video_frames(
    const std::vector<SelectedFrame>& all_frames) noexcept
{
    return std::any_of(
        all_frames.begin(),
        all_frames.end(),
        [](const SelectedFrame& frame) noexcept { return frame.imported_video; });
}

inline bool is_imported_video_preview_only(
    const std::vector<SelectedFrame>& all_frames) noexcept
{
    return !all_frames.empty() &&
           std::all_of(
               all_frames.begin(),
               all_frames.end(),
               [](const SelectedFrame& frame) noexcept { return frame.imported_video; });
}

inline std::uint32_t imported_video_min_seed_frames(
    std::size_t min_frames_to_start_training) noexcept
{
    return static_cast<std::uint32_t>(std::max<std::size_t>(
        min_frames_to_start_training * 3u,
        kImportedVideoMinSeedFramesFloor));
}

inline std::uint32_t imported_video_min_training_frames(
    std::size_t min_frames_to_start_training) noexcept
{
    return static_cast<std::uint32_t>(std::max<std::size_t>(
        min_frames_to_start_training * 3u,
        kImportedVideoMinTrainingFramesFloor));
}

inline std::uint32_t imported_video_min_ingested_frames(
    std::size_t min_frames_to_start_training) noexcept
{
    return static_cast<std::uint32_t>(std::max<std::size_t>(
        min_frames_to_start_training * 4u,
        kImportedVideoMinIngestedFramesFloor));
}

inline std::size_t imported_video_seed_cap(
    bool preview_only,
    std::size_t default_preview_initial_seed_cap) noexcept
{
    return preview_only
        ? kImportedVideoInitialSeedCap
        : default_preview_initial_seed_cap;
}

inline std::size_t imported_video_support_topup_target_gaussians(
    std::size_t min_seed_gaussians) noexcept
{
    return std::max<std::size_t>(
        min_seed_gaussians,
        kImportedVideoSupportTopUpTargetGaussians);
}

}  // namespace

std::size_t max_training_frames_for_mode(
    bool local_subject_first_mode) noexcept
{
    return local_subject_first_mode
        ? kLocalSubjectFirstMaxTrainingFrames
        : kCloudDefaultMaxTrainingFrames;
}

std::size_t training_base_steps_for_mode(
    bool local_subject_first_mode,
    std::size_t configured_max_iterations) noexcept
{
    return std::max<std::size_t>(
        configured_max_iterations,
        local_subject_first_mode
            ? kLocalSubjectFirstBaseTrainingSteps
            : kCloudDefaultBaseTrainingSteps);
}

bool align_to_baseline_3dgs_for_mode(
    bool local_subject_first_mode) noexcept
{
    return local_subject_first_mode;
}

const char* training_mode_name(
    bool local_subject_first_mode) noexcept
{
    return local_subject_first_mode ? "local_subject_first" : "cloud_default";
}

bool apply_capture_hold_if_needed(
    bool local_subject_first_mode,
    bool scanning_active,
    std::vector<splat::GaussianParams>& pending_gaussians,
    bool& capture_hold_logged) noexcept
{
    if (!local_subject_first_mode || !scanning_active) {
        if (capture_hold_logged) {
            std::fprintf(
                stderr,
                "[Aether3D][TrainThread] local_subject_first capture hold released: "
                "bootstrap/refine may begin\n");
            capture_hold_logged = false;
        }
        return false;
    }

    pending_gaussians.clear();
    if (!capture_hold_logged) {
        std::fprintf(
            stderr,
            "[Aether3D][TrainThread] local_subject_first capture hold: "
            "deferring bootstrap/refine until capture stops "
            "(preserving preview seeds for post-stop bootstrap)\n");
        capture_hold_logged = true;
    }
    return true;
}

ImportedVideoSeedBootstrapResult maybe_build_imported_video_seed_bootstrap(
    const std::vector<SelectedFrame>& all_frames,
    std::size_t min_frames_to_start_training,
    std::size_t default_preview_initial_seed_cap,
    std::size_t training_render_width,
    std::size_t training_render_height,
    std::size_t last_seed_attempt_depth_frames,
    float dav2_affine_scale,
    float dav2_affine_shift) noexcept
{
    ImportedVideoSeedBootstrapResult result;
    result.has_any_imported_video_frames = has_any_imported_video_frames(all_frames);
    result.preview_only = is_imported_video_preview_only(all_frames);
    result.min_seed_frames = imported_video_min_seed_frames(min_frames_to_start_training);
    result.preview_initial_seed_cap =
        imported_video_seed_cap(result.preview_only, default_preview_initial_seed_cap);
    result.min_seed_gaussians = std::min<std::size_t>(
        result.preview_initial_seed_cap,
        kImportedVideoMinSeedGaussians);

    if (!result.has_any_imported_video_frames) {
        return result;
    }

    std::vector<const SelectedFrame*> depth_frames;
    depth_frames.reserve(all_frames.size());
    for (const auto& frame : all_frames) {
        if (!frame.imported_video) {
            continue;
        }
        if (frame.ne_depth.empty() || frame.ne_depth_w == 0 || frame.ne_depth_h == 0) {
            continue;
        }
        depth_frames.push_back(&frame);
    }
    result.depth_frame_count = depth_frames.size();

    const bool seed_attempt_already_ran =
        result.preview_only &&
        last_seed_attempt_depth_frames == depth_frames.size() &&
        last_seed_attempt_depth_frames > 0;
    const bool seed_ready_to_initialize =
        depth_frames.size() >= result.min_seed_frames;

    if (!seed_ready_to_initialize && !depth_frames.empty()) {
        static std::uint32_t preview_seed_wait_log_count = 0;
        preview_seed_wait_log_count++;
        if (preview_seed_wait_log_count <= 8 ||
            preview_seed_wait_log_count % 20 == 0) {
            std::fprintf(
                stderr,
                "[Aether3D][TrainThread] Repo MVS seed waiting: %zu/%u imported depth frames ready\n",
                depth_frames.size(),
                result.min_seed_frames);
        }
        result.waiting_for_more_depth_frames = true;
        return result;
    }

    if (depth_frames.empty() || seed_attempt_already_ran) {
        return result;
    }

    result.attempted = true;
    const auto phase_t0 = std::chrono::steady_clock::now();

    std::vector<training::MVSFrame> mvs_frames;
    mvs_frames.reserve(depth_frames.size());
    std::size_t imported_video_metric_depth_frames = 0;
    for (const auto* frame_ptr : depth_frames) {
        if (!frame_ptr) {
            continue;
        }
        training::MVSFrame mf{};
        mf.rgba = frame_ptr->rgba.data();
        mf.width = frame_ptr->width;
        mf.height = frame_ptr->height;
        std::memcpy(mf.transform, frame_ptr->transform, sizeof(mf.transform));
        mf.intrinsics[0] = frame_ptr->intrinsics[0];
        mf.intrinsics[1] = frame_ptr->intrinsics[1];
        mf.intrinsics[2] = frame_ptr->intrinsics[2];
        mf.intrinsics[3] = frame_ptr->intrinsics[3];
        if (!frame_ptr->ne_depth.empty() &&
            frame_ptr->ne_depth_w > 0 &&
            frame_ptr->ne_depth_h > 0) {
            if (result.preview_only) {
                if (frame_ptr->ne_depth_is_metric) {
                    imported_video_metric_depth_frames++;
                }
            } else {
                mf.dav2_depth = frame_ptr->ne_depth.data();
                mf.dav2_w = frame_ptr->ne_depth_w;
                mf.dav2_h = frame_ptr->ne_depth_h;
                mf.dav2_is_metric = frame_ptr->ne_depth_is_metric;
                if (!mf.dav2_is_metric) {
                    mf.dav2_scale = dav2_affine_scale;
                    mf.dav2_shift = dav2_affine_shift;
                }
            }
        }
        mvs_frames.push_back(mf);
    }

    core::Status primary_seed_status = core::Status::kInvalidArgument;
    if (mvs_frames.size() >= 3) {
        training::MVSConfig mvs_cfg;
        mvs_cfg.depth_width = std::max<std::uint32_t>(
            static_cast<std::uint32_t>(160),
            static_cast<std::uint32_t>(
                std::max<std::size_t>(training_render_width, 320u) / 2u));
        mvs_cfg.depth_height = std::max<std::uint32_t>(
            static_cast<std::uint32_t>(120),
            static_cast<std::uint32_t>(
                std::max<std::size_t>(training_render_height, 240u) / 2u));
        if (result.preview_only) {
            mvs_cfg.dav2_prior_range = kImportedVideoMvsPrimaryPriorRange;
            mvs_cfg.dav2_prior_levels = kImportedVideoMvsPrimaryPriorLevels;
            std::fprintf(
                stderr,
                "[Aether3D][TrainThread] Repo MVS primary: imported-video DAv2 prior disabled "
                "(metric_depth_frames=%zu/%zu)\n",
                imported_video_metric_depth_frames,
                mvs_frames.size());
        }
        primary_seed_status = training::mvs_initialize(
            mvs_frames.data(),
            mvs_frames.size(),
            mvs_cfg,
            result.seeds);
        if (primary_seed_status == core::Status::kOk && !result.seeds.empty()) {
            if (result.seeds.size() > result.preview_initial_seed_cap) {
                result.seeds.resize(result.preview_initial_seed_cap);
            }
            std::fprintf(
                stderr,
                "[Aether3D][TrainThread] Repo MVS seed bootstrap: +%zu gaussians "
                "from %zu imported frames\n",
                result.seeds.size(),
                mvs_frames.size());
        }
    }

    const std::size_t mvs_seed_fallback_threshold =
        std::min<std::size_t>(result.preview_initial_seed_cap, 12000u);
    if (result.seeds.size() < mvs_seed_fallback_threshold) {
        training::DAv2Config dav2_cfg;
        dav2_cfg.subsample_step = 2;
        const bool have_primary_mvs_seed =
            primary_seed_status == core::Status::kOk && !result.seeds.empty();
        const std::size_t remaining_seed_budget =
            result.seeds.size() >= result.preview_initial_seed_cap
                ? 0u
                : (result.preview_initial_seed_cap - result.seeds.size());
        const std::size_t dav2_supplement_cap =
            have_primary_mvs_seed
                ? std::min<std::size_t>(
                      std::max<std::size_t>(result.seeds.size() / 3u, 512u),
                      2048u)
                : remaining_seed_budget;
        dav2_cfg.max_points = static_cast<std::uint32_t>(
            std::min<std::size_t>(remaining_seed_budget, dav2_supplement_cap));
        if (dav2_cfg.max_points > 0) {
            std::vector<splat::GaussianParams> dav2_supplement;
            const auto dav2_status = training::dav2_initialize(
                depth_frames.data(),
                depth_frames.size(),
                dav2_cfg,
                dav2_supplement);
            if (dav2_status == core::Status::kOk && !dav2_supplement.empty()) {
                if (dav2_supplement.size() > dav2_cfg.max_points) {
                    dav2_supplement.resize(dav2_cfg.max_points);
                }
                result.seeds.insert(
                    result.seeds.end(),
                    dav2_supplement.begin(),
                    dav2_supplement.end());
                std::fprintf(
                    stderr,
                    result.seeds.size() == dav2_supplement.size()
                        ? "[Aether3D][TrainThread] Repo DAv2 fallback seed bootstrap: +%zu gaussians "
                          "from %zu imported frames\n"
                        : "[Aether3D][TrainThread] Repo DAv2 supplement: +%zu gaussians "
                          "after MVS seed bootstrap\n",
                    dav2_supplement.size(),
                    depth_frames.size());
            } else if (primary_seed_status != core::Status::kOk) {
                std::fprintf(
                    stderr,
                    "[Aether3D][TrainThread] Repo MVS seed bootstrap failed, DAv2 fallback unavailable "
                    "(status=%d)\n",
                    static_cast<int>(dav2_status));
            }
        }
    }

    const auto phase_t1 = std::chrono::steady_clock::now();
    result.phase_elapsed_ms = static_cast<std::uint64_t>(
        std::chrono::duration_cast<std::chrono::milliseconds>(
            phase_t1 - phase_t0).count());

    if (result.seeds.size() > result.preview_initial_seed_cap) {
        result.seeds.resize(result.preview_initial_seed_cap);
    }
    result.seed_evidence_sufficient =
        !result.preview_only || result.seeds.size() >= result.min_seed_gaussians;
    if (!result.seed_evidence_sufficient && !result.seeds.empty()) {
        std::fprintf(
            stderr,
            "[Aether3D][TrainThread] Repo seed evidence still thin: %zu/%zu gaussians from %zu imported depth frames — waiting for more evidence\n",
            result.seeds.size(),
            result.min_seed_gaussians,
            depth_frames.size());
    }

    return result;
}

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
    std::chrono::steady_clock::time_point now) noexcept
{
    TrainingLoopLocalState state;
    state.local_subject_first_mode = local_subject_first_mode;
    state.scan_finished = !scanning_active;
    state.tsdf_idle = tsdf_idle;
    state.preview_frames_ingested = preview_frames_ingested;
    state.preview_depth_results_ready = preview_depth_results_ready;
    state.preview_selected_frames = preview_selected_frames;
    state.preview_seed_candidates = preview_seed_candidates;
    state.preview_seed_accepted = preview_seed_accepted;
    state.preview_frames_enqueued = preview_frames_enqueued;
    state.preview_elapsed_ms = local_subject_first_mode
        ? static_cast<std::uint64_t>(
              std::chrono::duration_cast<std::chrono::milliseconds>(
                  now - preview_started_at).count())
        : 0u;
    state.imported_video_gate = evaluate_imported_video_training_gate(
        all_frames,
        min_frames_to_start_training,
        kImportedVideoInitialSeedCap,
        preview_frames_ingested,
        preview_depth_results_ready,
        preview_selected_frames,
        preview_frames_enqueued,
        state.preview_elapsed_ms,
        scanning_active,
        tsdf_idle,
        pending_gaussian_count);
    return state;
}

bool should_attempt_imported_video_seed_bootstrap(
    const TrainingLoopLocalState& state,
    bool engine_created,
    bool pending_gaussians_empty,
    bool preview_dav2_seed_initialized,
    bool has_frames) noexcept
{
    return !engine_created &&
           pending_gaussians_empty &&
           state.local_subject_first_mode &&
           !preview_dav2_seed_initialized &&
           has_frames;
}

DegradedTsdfFallbackPlan make_degraded_tsdf_fallback_plan(
    const TrainingLoopLocalState& state,
    bool engine_created,
    bool pending_gaussians_empty,
    std::size_t all_frame_count) noexcept
{
    DegradedTsdfFallbackPlan plan;
    plan.preview_only = state.imported_video_gate.preview_only;
    plan.max_points = state.local_subject_first_mode
        ? local_subject_first_fallback_seeding::kTsdfFallbackSeedCount
        : std::size_t(20000u);
    plan.should_seed =
        !engine_created &&
        pending_gaussians_empty &&
        state.scan_finished &&
        state.tsdf_idle &&
        (all_frame_count >= state.imported_video_gate.min_training_frames ||
         state.imported_video_gate.degraded_seed_fallback_ready);
    return plan;
}

void log_degraded_tsdf_fallback(
    const DegradedTsdfFallbackPlan& plan,
    std::size_t seeded) noexcept
{
    if (!plan.should_seed || seeded == 0) {
        return;
    }
    std::fprintf(
        stderr,
        plan.preview_only
            ? "[Aether3D][TrainThread] Imported-video degraded TSDF seed fallback: +%zu gaussians\n"
            : "[Aether3D][TrainThread] Fallback TSDF seed bootstrap: +%zu gaussians\n",
        seeded);
}

ImportedVideoGeometryTopUpPlan make_imported_video_geometry_topup_plan(
    const TrainingLoopLocalState& state,
    bool engine_created,
    std::size_t current_support_gaussians,
    bool pre_engine_topup_applied,
    bool post_engine_topup_applied) noexcept
{
    ImportedVideoGeometryTopUpPlan plan;
    plan.post_engine = engine_created;
    plan.current_support_gaussians = current_support_gaussians;

    if (!state.imported_video_gate.preview_only ||
        !state.scan_finished ||
        !state.tsdf_idle ||
        current_support_gaussians == 0 ||
        state.preview_depth_results_ready < 3u ||
        state.preview_selected_frames < state.imported_video_gate.min_training_frames) {
        return plan;
    }

    if ((!engine_created && pre_engine_topup_applied) ||
        (engine_created && post_engine_topup_applied)) {
        return plan;
    }

    plan.target_support_gaussians = imported_video_support_topup_target_gaussians(
        state.imported_video_gate.min_seed_gaussians);
    if (current_support_gaussians >= plan.target_support_gaussians) {
        return plan;
    }

    const std::size_t deficit =
        plan.target_support_gaussians - current_support_gaussians;
    plan.requested_max_points = std::min<std::size_t>(
        deficit,
        local_subject_first_fallback_seeding::kTsdfFallbackSeedCount);
    plan.should_top_up = plan.requested_max_points > 0;
    return plan;
}

void log_imported_video_geometry_topup(
    const ImportedVideoGeometryTopUpPlan& plan,
    std::size_t seeded) noexcept
{
    if (!plan.should_top_up || seeded == 0) {
        return;
    }
    std::fprintf(
        stderr,
        plan.post_engine
            ? "[Aether3D][TrainThread] Imported-video bounded TSDF top-up (post-engine): +%zu gaussians current=%zu target=%zu requested=%zu\n"
            : "[Aether3D][TrainThread] Imported-video bounded TSDF top-up (pre-engine): +%zu gaussians current=%zu target=%zu requested=%zu\n",
        seeded,
        plan.current_support_gaussians,
        plan.target_support_gaussians,
        plan.requested_max_points);
}

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
    std::size_t pending_gaussian_count) noexcept
{
    ImportedVideoTrainingGateState state;
    state.preview_only = is_imported_video_preview_only(all_frames);
    state.min_training_frames =
        imported_video_min_training_frames(min_frames_to_start_training);
    state.preview_initial_seed_cap =
        imported_video_seed_cap(state.preview_only, default_preview_initial_seed_cap);
    state.min_seed_gaussians = std::min<std::size_t>(
        state.preview_initial_seed_cap,
        kImportedVideoMinSeedGaussians);

    const std::uint32_t min_ingested_frames =
        imported_video_min_ingested_frames(min_frames_to_start_training);
    state.degraded_seed_fallback_ready =
        state.preview_only &&
        !scanning_active &&
        tsdf_idle &&
        preview_depth_results_ready >= 3u &&
        preview_frames_enqueued > 0u &&
        preview_frames_ingested >= min_ingested_frames &&
        preview_selected_frames >= state.min_training_frames &&
        preview_elapsed_ms >= kImportedVideoDegradedReadyMinElapsedMs &&
        (!all_frames.empty() || preview_depth_results_ready > 0u);
    state.degraded_engine_ready =
        state.preview_only &&
        !scanning_active &&
        tsdf_idle &&
        preview_depth_results_ready >= 3u &&
        preview_frames_ingested >= min_ingested_frames &&
        preview_selected_frames >= state.min_training_frames &&
        preview_elapsed_ms >= kImportedVideoDegradedReadyMinElapsedMs &&
        !all_frames.empty();
    state.primary_engine_ready =
        all_frames.size() >= state.min_training_frames &&
        preview_selected_frames >= state.min_training_frames &&
        pending_gaussian_count >= state.min_seed_gaussians;
    state.ready_to_create_engine =
        pending_gaussian_count > 0 &&
        (!state.preview_only ||
         state.primary_engine_ready ||
         state.degraded_engine_ready);

    return state;
}

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
    std::size_t pending_gaussian_count) noexcept
{
    if (!gate_state.preview_only || gate_state.ready_to_create_engine) {
        return;
    }
    diag_counter++;
    if (diag_counter <= 12 || diag_counter % 30 == 0) {
        std::fprintf(
            stderr,
            "[Aether3D][TrainGate] waiting imported-video: selected=%u/%u "
            "accepted_seed=%u pending=%zu/%zu candidates=%u ingested=%u depth_ready=%u "
            "elapsed=%.1fs frozen=%d tsdf_idle=%d degraded_ready=%d\n",
            preview_selected_frames,
            gate_state.min_training_frames,
            preview_seed_accepted,
            pending_gaussian_count,
            gate_state.min_seed_gaussians,
            preview_seed_candidates,
            preview_frames_ingested,
            preview_depth_results_ready,
            static_cast<double>(preview_elapsed_ms) / 1000.0,
            features_frozen ? 1 : 0,
            tsdf_idle ? 1 : 0,
            gate_state.degraded_engine_ready ? 1 : 0);
    }
}

}  // namespace local_subject_first_training
}  // namespace pipeline
}  // namespace aether
