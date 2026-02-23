// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_GEO_CROSS_TEMPORAL_GS_H
#define AETHER_GEO_CROSS_TEMPORAL_GS_H

#include "aether/core/status.h"

#include <cstddef>
#include <cstdint>

namespace aether {
namespace geo {

struct GaussianState {
    float position[3];
    float scale[3];
    float color[3];
    float opacity;
    float covariance[6];  // Upper-triangle of 3x3 symmetric
};

struct ChangeResult {
    float change_score;
    bool is_new;
    bool is_removed;
    bool is_changed;
};

struct CrossTemporalEngine;

/// Create a cross-temporal change detection engine.
/// thermal_level: 0-8, controls max Gaussian count.
CrossTemporalEngine* cross_temporal_create(int32_t thermal_level);

/// Destroy engine.
void cross_temporal_destroy(CrossTemporalEngine* engine);

/// Match Gaussians between two epochs and detect changes.
core::Status cross_temporal_match(CrossTemporalEngine* engine,
                                  const GaussianState* epoch_a, size_t count_a,
                                  const GaussianState* epoch_b, size_t count_b,
                                  ChangeResult* out, size_t* out_count);

/// Compact Gaussians by merging near-identical ones.
core::Status cross_temporal_compact(CrossTemporalEngine* engine,
                                    GaussianState* gaussians, size_t count,
                                    size_t* out_count);

}  // namespace geo
}  // namespace aether

#endif  // AETHER_GEO_CROSS_TEMPORAL_GS_H
