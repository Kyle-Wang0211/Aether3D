// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/tsdf/mesh_extraction_scheduler.h"

#include <algorithm>
#include <cmath>

namespace aether {
namespace tsdf {

MeshExtractionScheduler::MeshExtractionScheduler() {
    reset();
}

int MeshExtractionScheduler::next_block_budget() const {
    return blocks_per_cycle_;
}

int MeshExtractionScheduler::current_blocks_per_cycle() const {
    return blocks_per_cycle_;
}

void MeshExtractionScheduler::reset() {
    const int slow_start = static_cast<int>(
        std::ceil(static_cast<double>(MIN_BLOCKS_PER_EXTRACTION) * static_cast<double>(SLOW_START_RATIO)));
    blocks_per_cycle_ = std::max(MIN_BLOCKS_PER_EXTRACTION, slow_start);
    consecutive_good_ = 0;
    ema_ms_ = MESH_BUDGET_TARGET_MS;
}

void MeshExtractionScheduler::report_cycle(double elapsed_ms) {
    if (!std::isfinite(elapsed_ms)) {
        elapsed_ms = MESH_BUDGET_OVERRUN_MS + 1.0;
    }
    if (elapsed_ms < 0.0) {
        elapsed_ms = MESH_BUDGET_OVERRUN_MS + 1.0;
    }

    constexpr double kAlpha = 0.3;
    ema_ms_ = kAlpha * elapsed_ms + (1.0 - kAlpha) * ema_ms_;
    const double ratio = MESH_BUDGET_TARGET_MS / std::max(0.5, ema_ms_);
    const double clamped_ratio = std::max(0.5, std::min(1.5, ratio));
    int proposed = static_cast<int>(std::lround(static_cast<double>(blocks_per_cycle_) * clamped_ratio));

    if (elapsed_ms < MESH_BUDGET_GOOD_MS) {
        ++consecutive_good_;
        if (consecutive_good_ >= CONSECUTIVE_GOOD_CYCLES_BEFORE_RAMP) {
            proposed = std::max(proposed, blocks_per_cycle_ + BLOCK_RAMP_PER_CYCLE);
            consecutive_good_ = 0;
        }
    } else {
        consecutive_good_ = 0;
    }

    if (elapsed_ms > MESH_BUDGET_OVERRUN_MS) {
        proposed = std::min(proposed, blocks_per_cycle_ / 2);
    }

    blocks_per_cycle_ = std::max(
        MIN_BLOCKS_PER_EXTRACTION,
        std::min(MAX_BLOCKS_PER_EXTRACTION, proposed));
}

}  // namespace tsdf
}  // namespace aether
