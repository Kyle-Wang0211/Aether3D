// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_TSDF_CPU_INTEGRATION_BACKEND_H
#define AETHER_TSDF_CPU_INTEGRATION_BACKEND_H

#include "aether/tsdf/adaptive_resolution.h"
#include "aether/tsdf/integration_backend.h"
#include <cmath>

namespace aether {
namespace tsdf {

class CPUIntegrationBackend final : public IntegrationBackend {
public:
    IntegrationStats process_frame(
        const IntegrationInput& input,
        const DepthDataProvider& depth_data,
        VoxelBlockAccessor&,
        const BlockIndex*,
        const int*,
        int) override {
        IntegrationStats stats{};
        const int width = depth_data.width();
        const int height = depth_data.height();
        const float inv_fx = 1.0f / input.fx;
        const float inv_fy = 1.0f / input.fy;

        for (int y = 0; y < height; ++y) {
            for (int x = 0; x < width; ++x) {
                const float d = depth_data.depth_at(x, y);
                if (!std::isfinite(d) || d < DEPTH_MIN || d > DEPTH_MAX) continue;
                const uint8_t conf = depth_data.confidence_at(x, y);
                if (SKIP_LOW_CONFIDENCE_PIXELS && conf == 0) continue;
                const float cam_x = (static_cast<float>(x) - input.cx) * d * inv_fx;
                const float cam_y = (static_cast<float>(y) - input.cy) * d * inv_fy;
                (void)cam_x;
                (void)cam_y;
                ++stats.voxels_updated;
            }
        }
        stats.blocks_updated = stats.voxels_updated > 0 ? 1 : 0;
        stats.total_time_ms = 0.0;
        stats.gpu_time_ms = 0.0;
        return stats;
    }
};

}  // namespace tsdf
}  // namespace aether

#endif  // AETHER_TSDF_CPU_INTEGRATION_BACKEND_H
