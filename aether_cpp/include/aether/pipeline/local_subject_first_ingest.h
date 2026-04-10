// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_PIPELINE_LOCAL_SUBJECT_FIRST_INGEST_H
#define AETHER_PIPELINE_LOCAL_SUBJECT_FIRST_INGEST_H

#include <cstddef>
#include <cstdint>

namespace aether {
namespace pipeline {
namespace local_subject_first_ingest {

struct ImportedVideoDrainFreezeState {
    bool imported_video_preview_pending{false};
    bool should_freeze_features_immediately{false};
};

ImportedVideoDrainFreezeState evaluate_finish_scanning_freeze(
    bool local_subject_first_mode,
    std::uint32_t preview_frames_enqueued,
    std::uint32_t preview_frames_ingested) noexcept;

void log_finish_scanning_summary(
    std::uint32_t accepted_frames,
    std::uint32_t dropped_frames,
    const ImportedVideoDrainFreezeState& state,
    std::uint32_t preview_frames_ingested,
    std::uint32_t preview_frames_enqueued) noexcept;

bool should_freeze_features_after_imported_video_drain(
    bool local_subject_first_mode,
    bool imported_video_input,
    bool scanning_active,
    bool features_frozen,
    std::uint32_t preview_frames_enqueued,
    std::uint32_t preview_frames_ingested,
    std::size_t frame_queue_size) noexcept;

void log_imported_video_queue_drained_freeze(
    std::uint32_t preview_frames_ingested,
    std::uint32_t preview_frames_enqueued) noexcept;

}  // namespace local_subject_first_ingest
}  // namespace pipeline
}  // namespace aether

#endif  // AETHER_PIPELINE_LOCAL_SUBJECT_FIRST_INGEST_H
