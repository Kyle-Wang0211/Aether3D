// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/pipeline/local_subject_first_ingest.h"

#include <cstdio>

namespace aether {
namespace pipeline {
namespace local_subject_first_ingest {

ImportedVideoDrainFreezeState evaluate_finish_scanning_freeze(
    bool local_subject_first_mode,
    std::uint32_t preview_frames_enqueued,
    std::uint32_t preview_frames_ingested) noexcept
{
    ImportedVideoDrainFreezeState state;
    state.imported_video_preview_pending =
        local_subject_first_mode &&
        preview_frames_enqueued > preview_frames_ingested;
    state.should_freeze_features_immediately =
        !state.imported_video_preview_pending;
    return state;
}

void log_finish_scanning_summary(
    std::uint32_t accepted_frames,
    std::uint32_t dropped_frames,
    const ImportedVideoDrainFreezeState& state,
    std::uint32_t preview_frames_ingested,
    std::uint32_t preview_frames_enqueued) noexcept
{
    std::fprintf(
        stderr,
        state.imported_video_preview_pending
            ? "[Aether3D] Scan finished: %u frames accepted, %u dropped (%.1f%% loss) "
              "\xE2\x80\x94 deferring feature freeze until imported-video queue drains (%u/%u ingested)\n"
            : "[Aether3D] Scan finished: %u frames accepted, %u dropped (%.1f%% loss)\n",
        accepted_frames,
        dropped_frames,
        accepted_frames > 0
            ? 100.0f * dropped_frames / (accepted_frames + dropped_frames)
            : 0.0f,
        preview_frames_ingested,
        preview_frames_enqueued);
}

bool should_freeze_features_after_imported_video_drain(
    bool local_subject_first_mode,
    bool imported_video_input,
    bool scanning_active,
    bool features_frozen,
    std::uint32_t preview_frames_enqueued,
    std::uint32_t preview_frames_ingested,
    std::size_t frame_queue_size) noexcept
{
    return local_subject_first_mode &&
           imported_video_input &&
           !scanning_active &&
           !features_frozen &&
           preview_frames_enqueued > 0 &&
           preview_frames_ingested >= preview_frames_enqueued &&
           frame_queue_size == 0u;
}

void log_imported_video_queue_drained_freeze(
    std::uint32_t preview_frames_ingested,
    std::uint32_t preview_frames_enqueued) noexcept
{
    std::fprintf(
        stderr,
        "[Aether3D][SubjectFirstMode] imported-video queue drained: "
        "freezing features after %u/%u ingested frames\n",
        preview_frames_ingested,
        preview_frames_enqueued);
}

}  // namespace local_subject_first_ingest
}  // namespace pipeline
}  // namespace aether
