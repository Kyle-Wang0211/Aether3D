// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_PIPELINE_LOCAL_PREVIEW_RUNTIME_H
#define AETHER_PIPELINE_LOCAL_PREVIEW_RUNTIME_H

#include <vector>
#include <cstdint>

#include "aether_tsdf_c.h"
#include "aether/capture/frame_selector.h"

namespace aether {
namespace pipeline {

struct FrameInput;

namespace local_preview_runtime {

struct ImportedPreviewKeyframeDecision {
    bool accept{false};
    bool low_parallax{false};
    bool near_duplicate{false};
};

capture::FrameSelectionConfig sanitize_frame_selection_config(
    capture::FrameSelectionConfig cfg) noexcept;

capture::FrameSelectionConfig preview_frame_selection_config(
    capture::FrameSelectionConfig cfg) noexcept;

void bootstrap_imported_video_intrinsics(std::uint32_t w,
                                         std::uint32_t h,
                                         float intrinsics[9]) noexcept;

void extract_camera_pose_metrics(
    const float* transform,
    float out_pos[3],
    float out_fwd[3]) noexcept;

bool should_submit_preview_depth_prior(
    bool has_cached_depth,
    std::uint32_t frames_since_last_submit,
    bool has_last_request,
    const float current_pos[3],
    const float current_fwd[3],
    const float last_pos[3],
    const float last_fwd[3]) noexcept;

bool should_accept_preview_keyframe(
    bool has_depth_prior,
    const capture::FrameSelectionResult& sel_result,
    bool has_last_selected,
    const float current_pos[3],
    const float current_fwd[3],
    const float last_pos[3],
    const float last_fwd[3]) noexcept;

ImportedPreviewKeyframeDecision decide_imported_preview_keyframe(
    bool has_depth_prior,
    const capture::FrameSelectionResult& sel_result,
    bool has_last_selected,
    const float current_pos[3],
    const float current_fwd[3],
    const float last_pos[3],
    const float last_fwd[3]) noexcept;

enum class PreviewPrefilterDecision : std::uint8_t {
    kAccept = 0,
    kRejectLowBrightness = 1,
    kRejectBlur = 2,
};

PreviewPrefilterDecision evaluate_preview_import_prefilter(
    float brightness,
    float blur,
    float low_light_brightness_threshold,
    float min_blur_score,
    float low_light_blur_strictness) noexcept;

void update_imported_video_bootstrap_pose(
    FrameInput& input,
    const float* metric_depth,
    std::uint32_t depth_w,
    std::uint32_t depth_h,
    bool& pose_initialized,
    float pose[16],
    std::vector<aether_icp_point_t>& target_points_world,
    std::vector<aether_icp_point_t>& target_normals_world,
    bool& shared_intrinsics_initialized,
    float shared_intrinsics[9]) noexcept;

}  // namespace local_preview_runtime

// Active local product semantics are subject-first. Keep the older
// local_preview_runtime namespace as the compatibility implementation while
// exposing clearer native wrappers for new code.
namespace local_subject_first_runtime {

using ImportedSubjectFirstKeyframeDecision =
    local_preview_runtime::ImportedPreviewKeyframeDecision;
using SubjectFirstPrefilterDecision =
    local_preview_runtime::PreviewPrefilterDecision;

inline capture::FrameSelectionConfig sanitize_subject_first_frame_selection_config(
    capture::FrameSelectionConfig cfg) noexcept
{
    return local_preview_runtime::sanitize_frame_selection_config(cfg);
}

inline capture::FrameSelectionConfig subject_first_frame_selection_config(
    capture::FrameSelectionConfig cfg) noexcept
{
    return local_preview_runtime::preview_frame_selection_config(cfg);
}

inline void bootstrap_imported_subject_first_intrinsics(
    std::uint32_t w,
    std::uint32_t h,
    float intrinsics[9]) noexcept
{
    local_preview_runtime::bootstrap_imported_video_intrinsics(w, h, intrinsics);
}

inline void extract_subject_first_camera_pose_metrics(
    const float* transform,
    float out_pos[3],
    float out_fwd[3]) noexcept
{
    local_preview_runtime::extract_camera_pose_metrics(transform, out_pos, out_fwd);
}

inline bool should_submit_subject_first_depth_prior(
    bool has_cached_depth,
    std::uint32_t frames_since_last_submit,
    bool has_last_request,
    const float current_pos[3],
    const float current_fwd[3],
    const float last_pos[3],
    const float last_fwd[3]) noexcept
{
    return local_preview_runtime::should_submit_preview_depth_prior(
        has_cached_depth,
        frames_since_last_submit,
        has_last_request,
        current_pos,
        current_fwd,
        last_pos,
        last_fwd);
}

inline bool should_accept_subject_first_keyframe(
    bool has_depth_prior,
    const capture::FrameSelectionResult& sel_result,
    bool has_last_selected,
    const float current_pos[3],
    const float current_fwd[3],
    const float last_pos[3],
    const float last_fwd[3]) noexcept
{
    return local_preview_runtime::should_accept_preview_keyframe(
        has_depth_prior,
        sel_result,
        has_last_selected,
        current_pos,
        current_fwd,
        last_pos,
        last_fwd);
}

inline ImportedSubjectFirstKeyframeDecision decide_imported_subject_first_keyframe(
    bool has_depth_prior,
    const capture::FrameSelectionResult& sel_result,
    bool has_last_selected,
    const float current_pos[3],
    const float current_fwd[3],
    const float last_pos[3],
    const float last_fwd[3]) noexcept
{
    return local_preview_runtime::decide_imported_preview_keyframe(
        has_depth_prior,
        sel_result,
        has_last_selected,
        current_pos,
        current_fwd,
        last_pos,
        last_fwd);
}

inline SubjectFirstPrefilterDecision evaluate_subject_first_import_prefilter(
    float brightness,
    float blur,
    float low_light_brightness_threshold,
    float min_blur_score,
    float low_light_blur_strictness) noexcept
{
    return local_preview_runtime::evaluate_preview_import_prefilter(
        brightness,
        blur,
        low_light_brightness_threshold,
        min_blur_score,
        low_light_blur_strictness);
}

inline void update_imported_video_subject_first_bootstrap_pose(
    FrameInput& input,
    const float* metric_depth,
    std::uint32_t depth_w,
    std::uint32_t depth_h,
    bool& pose_initialized,
    float pose[16],
    std::vector<aether_icp_point_t>& target_points_world,
    std::vector<aether_icp_point_t>& target_normals_world,
    bool& shared_intrinsics_initialized,
    float shared_intrinsics[9]) noexcept
{
    local_preview_runtime::update_imported_video_bootstrap_pose(
        input,
        metric_depth,
        depth_w,
        depth_h,
        pose_initialized,
        pose,
        target_points_world,
        target_normals_world,
        shared_intrinsics_initialized,
        shared_intrinsics);
}

}  // namespace local_subject_first_runtime
}  // namespace pipeline
}  // namespace aether

#endif  // AETHER_PIPELINE_LOCAL_PREVIEW_RUNTIME_H
