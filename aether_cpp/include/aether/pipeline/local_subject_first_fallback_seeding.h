// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_PIPELINE_LOCAL_SUBJECT_FIRST_FALLBACK_SEEDING_H
#define AETHER_PIPELINE_LOCAL_SUBJECT_FIRST_FALLBACK_SEEDING_H

#include <cstddef>
#include <vector>

#include "aether/pipeline/streaming_pipeline.h"
#include "aether/splat/packed_splats.h"
#include "aether/tsdf/tsdf_volume.h"

namespace aether {
namespace pipeline {
namespace local_subject_first_fallback_seeding {

inline constexpr std::size_t kTsdfFallbackSeedCount = 6000u;

struct TsdfFallbackSeedStats {
    std::size_t seeded{0};
    std::size_t sampled_frame_colors{0};
    std::size_t shaded_fallback_colors{0};
};

TsdfFallbackSeedStats append_tsdf_fallback_gaussians(
    const std::vector<tsdf::SurfacePoint>& surface_points,
    const std::vector<SelectedFrame>& all_frames,
    std::vector<splat::GaussianParams>& out) noexcept;

}  // namespace local_subject_first_fallback_seeding
}  // namespace pipeline
}  // namespace aether

#endif  // AETHER_PIPELINE_LOCAL_SUBJECT_FIRST_FALLBACK_SEEDING_H
