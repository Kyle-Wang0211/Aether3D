// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// aether/tsdf/tsdf_types.h
// IntegrationInput, IntegrationResult (Swift TSDFTypes parity)

#ifndef AETHER_TSDF_TSDF_TYPES_H
#define AETHER_TSDF_TSDF_TYPES_H

namespace aether {
namespace tsdf {

enum class MemoryPressureLevel : int {
    kWarning = 1,
    kCritical = 2,
    kTerminal = 3,
};

enum class IntegrationSkipReason : int {
    kNone = 0,
    kTrackingLost = 1,
    kPoseTeleport = 2,
    kPoseJitter = 3,
    kThermalThrottle = 4,
    kFrameTimeout = 5,
    kLowValidPixels = 6,
    kMemoryPressure = 7,
};

struct IntegrationInput {
    const float* depth_data{nullptr};
    int depth_width{0};
    int depth_height{0};
    const unsigned char* confidence_data{nullptr};
    float voxel_size{0.01f};
    float fx{0.f}, fy{0.f}, cx{0.f}, cy{0.f};
    const float* view_matrix{nullptr};
    double timestamp{0.0};
    int tracking_state{2};  // 2 = normal, 1 = limited, 0 = unavailable
};

struct IntegrationStats {
    int blocks_updated{0};
    int blocks_allocated{0};
    int voxels_updated{0};
    double gpu_time_ms{0.0};
    double total_time_ms{0.0};
};

struct IntegrationResult {
    int voxels_integrated{0};
    int blocks_updated{0};
    bool success{false};
    bool skipped{false};
    IntegrationSkipReason skip_reason{IntegrationSkipReason::kNone};
    IntegrationStats stats{};
};

}  // namespace tsdf
}  // namespace aether

#endif  // AETHER_TSDF_TSDF_TYPES_H
