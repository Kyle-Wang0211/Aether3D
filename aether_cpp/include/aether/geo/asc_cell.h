// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_GEO_ASC_CELL_H
#define AETHER_GEO_ASC_CELL_H

#include "aether/core/status.h"

#include <cstdint>

namespace aether {
namespace geo {

/// 96-bit Aether Spatio-Temporal Cell ID.
/// Upper 64 bits: spatial Hilbert cell on cube-face projection.
/// Lower 32 bits: temporal bucket (seconds since epoch).
struct AetherSTCellId {
    std::uint64_t spatial{0};
    std::uint32_t temporal_bucket{0};

    bool operator==(const AetherSTCellId& o) const {
        return spatial == o.spatial && temporal_bucket == o.temporal_bucket;
    }
    bool operator!=(const AetherSTCellId& o) const { return !(*this == o); }
    bool operator<(const AetherSTCellId& o) const {
        if (spatial != o.spatial) return spatial < o.spatial;
        return temporal_bucket < o.temporal_bucket;
    }
};

/// Convert lat/lon (degrees) to a 64-bit ASC CellId at the given level.
/// Level range: [0, ASC_CELL_MAX_LEVEL].
core::Status latlon_to_cell(double lat_deg, double lon_deg,
                            std::uint32_t level,
                            std::uint64_t* out_cell_id);

/// Convert a CellId back to the center lat/lon of that cell.
core::Status cell_to_latlon(std::uint64_t cell_id,
                            double* out_lat_deg, double* out_lon_deg);

/// Extract face index [0..5] from a CellId.
std::uint32_t cell_face(std::uint64_t cell_id);

/// Extract level [0..ASC_CELL_MAX_LEVEL] from a CellId.
std::uint32_t cell_level(std::uint64_t cell_id);

/// Get parent cell at (level - 1).  Returns 0 if already at level 0.
std::uint64_t cell_parent(std::uint64_t cell_id);

/// Compute a full 96-bit spatio-temporal cell id.
/// bucket_seconds: temporal bucket width (e.g. 3600 for hourly).
core::Status latlon_to_st_cell(double lat_deg, double lon_deg,
                               std::uint32_t level,
                               double timestamp_s,
                               std::uint32_t bucket_seconds,
                               AetherSTCellId* out_id);

/// XY ↔ Hilbert conversion (order-N iterative, no recursion).
std::uint64_t xy_to_hilbert(std::uint32_t x, std::uint32_t y, std::uint32_t order);
void hilbert_to_xy(std::uint64_t d, std::uint32_t order,
                   std::uint32_t* out_x, std::uint32_t* out_y);

}  // namespace geo
}  // namespace aether

#endif  // AETHER_GEO_ASC_CELL_H
