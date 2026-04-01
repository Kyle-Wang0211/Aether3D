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
}  // namespace pipeline
}  // namespace aether

#endif  // AETHER_PIPELINE_LOCAL_PREVIEW_RUNTIME_H
