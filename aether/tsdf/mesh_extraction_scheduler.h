// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_TSDF_MESH_EXTRACTION_SCHEDULER_H
#define AETHER_TSDF_MESH_EXTRACTION_SCHEDULER_H

#include "aether/tsdf/tsdf_constants.h"

namespace aether {
namespace tsdf {

class MeshExtractionScheduler {
public:
    MeshExtractionScheduler();

    int next_block_budget() const;
    void report_cycle(double elapsed_ms);
    void reset();
    int current_blocks_per_cycle() const;

private:
    int blocks_per_cycle_{MIN_BLOCKS_PER_EXTRACTION};
    int consecutive_good_{0};
    double ema_ms_{MESH_BUDGET_TARGET_MS};
};

}  // namespace tsdf
}  // namespace aether

#endif  // AETHER_TSDF_MESH_EXTRACTION_SCHEDULER_H
