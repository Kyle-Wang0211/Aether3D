// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_PIPELINE_LOCAL_SUBJECT_FIRST_REFINE_H
#define AETHER_PIPELINE_LOCAL_SUBJECT_FIRST_REFINE_H

#include <atomic>
#include <chrono>
#include <cstdint>

namespace aether {
namespace pipeline {
namespace local_subject_first_refine {

inline bool should_pause_imported_video_processing(
    bool foreground_active) noexcept
{
    return !foreground_active;
}

void update_import_queue_foreground_state(
    bool foreground_active,
    bool& pause_logged) noexcept;

void update_training_refine_foreground_state(
    bool foreground_active,
    bool& pause_logged) noexcept;

void maybe_update_training_refine_foreground_state(
    bool local_subject_first_mode,
    bool foreground_active,
    bool& pause_logged) noexcept;

std::chrono::steady_clock::time_point begin_preview_refine_phase(
    bool local_subject_first_mode) noexcept;

void finish_preview_refine_phase(
    bool local_subject_first_mode,
    std::atomic<std::uint64_t>& preview_refine_phase_ms,
    std::chrono::steady_clock::time_point phase_started_at) noexcept;

}  // namespace local_subject_first_refine
}  // namespace pipeline
}  // namespace aether

#endif  // AETHER_PIPELINE_LOCAL_SUBJECT_FIRST_REFINE_H
