// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/pipeline/local_subject_first_refine.h"

#include <cstdio>

namespace aether {
namespace pipeline {
namespace local_subject_first_refine {

void update_import_queue_foreground_state(
    bool foreground_active,
    bool& pause_logged) noexcept
{
    if (!foreground_active) {
        if (!pause_logged) {
            std::fprintf(
                stderr,
                "[Aether3D][ImportQueue] local_subject_first app inactive: "
                "pausing imported-video frame processing until foreground resumes\n");
            pause_logged = true;
        }
        return;
    }

    if (pause_logged) {
        std::fprintf(
            stderr,
            "[Aether3D][ImportQueue] local_subject_first resumed: "
            "continuing imported-video frame processing in foreground\n");
        pause_logged = false;
    }
}

void update_training_refine_foreground_state(
    bool foreground_active,
    bool& pause_logged) noexcept
{
    if (!foreground_active) {
        if (!pause_logged) {
            std::fprintf(
                stderr,
                "[Aether3D][TrainThread] local_subject_first app inactive: "
                "using background-safe refine path while host execution remains available\n");
            pause_logged = true;
        }
        return;
    }

    if (pause_logged) {
        std::fprintf(
            stderr,
            "[Aether3D][TrainThread] local_subject_first resumed: "
            "foreground active, continuing GPU refine\n");
        pause_logged = false;
    }
}

void maybe_update_training_refine_foreground_state(
    bool local_subject_first_mode,
    bool foreground_active,
    bool& pause_logged) noexcept
{
    if (!local_subject_first_mode) {
        return;
    }
    update_training_refine_foreground_state(foreground_active, pause_logged);
}

std::chrono::steady_clock::time_point begin_preview_refine_phase(
    bool local_subject_first_mode) noexcept
{
    return local_subject_first_mode
        ? std::chrono::steady_clock::now()
        : std::chrono::steady_clock::time_point{};
}

void finish_preview_refine_phase(
    bool local_subject_first_mode,
    std::atomic<std::uint64_t>& preview_refine_phase_ms,
    std::chrono::steady_clock::time_point phase_started_at) noexcept
{
    if (!local_subject_first_mode) {
        return;
    }
    const auto phase_finished_at = std::chrono::steady_clock::now();
    const auto elapsed_ms = static_cast<std::uint64_t>(
        std::chrono::duration_cast<std::chrono::milliseconds>(
            phase_finished_at - phase_started_at).count());
    preview_refine_phase_ms.fetch_add(
        elapsed_ms,
        std::memory_order_relaxed);
}

}  // namespace local_subject_first_refine
}  // namespace pipeline
}  // namespace aether
