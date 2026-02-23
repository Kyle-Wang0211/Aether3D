// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/geo/asc_cell.h"
#include "aether/geo/geo_constants.h"

#include <cmath>
#include <cstdint>

namespace aether {
namespace geo {

// ---------------------------------------------------------------------------
// Cube-face projection: lat/lon → face + (u,v) in [-1,1]
// Uses gnomonic-style projection onto 6 faces of a circumscribed cube.
// ---------------------------------------------------------------------------
namespace {

struct FaceUV {
    std::uint32_t face;
    double u;
    double v;
};

FaceUV latlon_to_face_uv(double lat_rad, double lon_rad) {
    const double x = std::cos(lat_rad) * std::cos(lon_rad);
    const double y = std::cos(lat_rad) * std::sin(lon_rad);
    const double z = std::sin(lat_rad);

    const double ax = std::fabs(x);
    const double ay = std::fabs(y);
    const double az = std::fabs(z);

    FaceUV result{};
    if (ax >= ay && ax >= az) {
        // Face 0 (+X) or Face 1 (-X)
        if (x > 0) { result.face = 0; result.u = y / x;  result.v = z / x; }
        else       { result.face = 1; result.u = -y / x; result.v = z / (-x); }
    } else if (ay >= ax && ay >= az) {
        // Face 2 (+Y) or Face 3 (-Y)
        if (y > 0) { result.face = 2; result.u = -x / y; result.v = z / y; }
        else       { result.face = 3; result.u = x / y;  result.v = z / (-y); }
    } else {
        // Face 4 (+Z) or Face 5 (-Z)
        if (z > 0) { result.face = 4; result.u = y / z;  result.v = -x / z; }
        else       { result.face = 5; result.u = y / (-z); result.v = x / (-z); }
    }
    return result;
}

void face_uv_to_latlon(std::uint32_t face, double u, double v,
                        double* out_lat_rad, double* out_lon_rad) {
    double x = 0, y = 0, z = 0;
    switch (face) {
        case 0: x =  1; y =  u; z =  v; break;
        case 1: x = -1; y =  u; z =  v; break;
        case 2: y =  1; x = -u; z =  v; break;
        case 3: y = -1; x = -u; z =  v; break;
        case 4: z =  1; y =  u; x = -v; break;
        case 5: z = -1; y =  u; x =  v; break;
        default: break;
    }
    const double r = std::sqrt(x * x + y * y + z * z);
    *out_lat_rad = std::asin(z / r);
    *out_lon_rad = std::atan2(y, x);
}

}  // anonymous namespace

// ---------------------------------------------------------------------------
// Hilbert curve: iterative XY ↔ Hilbert-d conversion
// Based on the algorithm from the Wikipedia "Hilbert curve" article.
// ---------------------------------------------------------------------------
std::uint64_t xy_to_hilbert(std::uint32_t x, std::uint32_t y, std::uint32_t order) {
    std::uint64_t d = 0;
    for (std::uint32_t s = order; s > 0; --s) {
        const std::uint32_t mask = 1u << (s - 1);
        const std::uint32_t rx = (x & mask) ? 1 : 0;
        const std::uint32_t ry = (y & mask) ? 1 : 0;
        d += static_cast<std::uint64_t>((3u * rx) ^ ry) << (2u * (s - 1));
        // Rotate
        if (ry == 0) {
            if (rx == 1) {
                x = mask - 1 - x;
                y = mask - 1 - y;
            }
            // Swap x and y
            std::uint32_t tmp = x;
            x = y;
            y = tmp;
        }
    }
    return d;
}

void hilbert_to_xy(std::uint64_t d, std::uint32_t order,
                   std::uint32_t* out_x, std::uint32_t* out_y) {
    std::uint32_t x = 0, y = 0;
    for (std::uint32_t s = 1; s <= order; ++s) {
        const std::uint32_t mask = 1u << (s - 1);
        const std::uint32_t rx = 1u & static_cast<std::uint32_t>(d >> 1u);
        const std::uint32_t ry = 1u & (static_cast<std::uint32_t>(d) ^ rx);
        // Rotate
        if (ry == 0) {
            if (rx == 1) {
                x = mask - 1 - x;
                y = mask - 1 - y;
            }
            std::uint32_t tmp = x;
            x = y;
            y = tmp;
        }
        x |= rx ? mask : 0;
        y |= ry ? mask : 0;
        d >>= 2u;
    }
    *out_x = x;
    *out_y = y;
}

// ---------------------------------------------------------------------------
// CellId construction and extraction
// ---------------------------------------------------------------------------
core::Status latlon_to_cell(double lat_deg, double lon_deg,
                            std::uint32_t level,
                            std::uint64_t* out_cell_id) {
    if (!out_cell_id) return core::Status::kInvalidArgument;
    if (level > ASC_CELL_MAX_LEVEL) return core::Status::kOutOfRange;
    if (lat_deg < LAT_MIN || lat_deg > LAT_MAX) return core::Status::kOutOfRange;

    // Wrap longitude
    double lon = lon_deg;
    while (lon < LON_MIN) lon += 360.0;
    while (lon > LON_MAX) lon -= 360.0;

    const double lat_rad = lat_deg * DEG_TO_RAD;
    const double lon_rad = lon * DEG_TO_RAD;

    FaceUV fuv = latlon_to_face_uv(lat_rad, lon_rad);

    // Map (u,v) from [-1,1] to [0, cells_per_axis) at this level
    const std::uint32_t cells = 1u << level;
    auto to_grid = [&](double coord) -> std::uint32_t {
        double t = (coord + 1.0) * 0.5;  // [0, 1]
        if (t < 0.0) t = 0.0;
        if (t >= 1.0) t = 1.0 - 1e-15;
        return static_cast<std::uint32_t>(t * cells);
    };

    const std::uint32_t gx = to_grid(fuv.u);
    const std::uint32_t gy = to_grid(fuv.v);

    const std::uint64_t hilbert_pos = xy_to_hilbert(gx, gy, level);

    // Pack into CellId:
    //   [63..61] face (3 bits)
    //   [60..31] hilbert position (30 bits) — we shift to align within this range
    //   [30..27] level (4 bits)
    //   [26..0]  reserved
    const std::uint64_t face64 = static_cast<std::uint64_t>(fuv.face);
    const std::uint64_t shift_amount = ASC_POS_BITS - 2 * level;

    *out_cell_id = (face64 << ASC_FACE_SHIFT) |
                   ((hilbert_pos << shift_amount) << ASC_POS_SHIFT) |
                   (static_cast<std::uint64_t>(level) << ASC_LEVEL_SHIFT);
    return core::Status::kOk;
}

core::Status cell_to_latlon(std::uint64_t cell_id,
                            double* out_lat_deg, double* out_lon_deg) {
    if (!out_lat_deg || !out_lon_deg) return core::Status::kInvalidArgument;

    const std::uint32_t face = cell_face(cell_id);
    const std::uint32_t level = cell_level(cell_id);
    if (face >= ASC_NUM_FACES || level > ASC_CELL_MAX_LEVEL) {
        return core::Status::kOutOfRange;
    }

    const std::uint64_t pos_raw = (cell_id & ASC_POS_MASK) >> ASC_POS_SHIFT;
    const std::uint64_t shift_amount = ASC_POS_BITS - 2 * level;
    const std::uint64_t hilbert_pos = pos_raw >> shift_amount;

    std::uint32_t gx = 0, gy = 0;
    hilbert_to_xy(hilbert_pos, level, &gx, &gy);

    const std::uint32_t cells = 1u << level;
    // Map grid center back to (u,v) in [-1,1]
    const double u = ((static_cast<double>(gx) + 0.5) / cells) * 2.0 - 1.0;
    const double v = ((static_cast<double>(gy) + 0.5) / cells) * 2.0 - 1.0;

    double lat_rad = 0, lon_rad = 0;
    face_uv_to_latlon(face, u, v, &lat_rad, &lon_rad);

    *out_lat_deg = lat_rad * RAD_TO_DEG;
    *out_lon_deg = lon_rad * RAD_TO_DEG;
    return core::Status::kOk;
}

std::uint32_t cell_face(std::uint64_t cell_id) {
    return static_cast<std::uint32_t>((cell_id & ASC_FACE_MASK) >> ASC_FACE_SHIFT);
}

std::uint32_t cell_level(std::uint64_t cell_id) {
    return static_cast<std::uint32_t>((cell_id & ASC_LEVEL_MASK) >> ASC_LEVEL_SHIFT);
}

std::uint64_t cell_parent(std::uint64_t cell_id) {
    const std::uint32_t level = cell_level(cell_id);
    if (level == 0) return 0;

    const std::uint32_t face = cell_face(cell_id);
    const std::uint64_t pos_raw = (cell_id & ASC_POS_MASK) >> ASC_POS_SHIFT;
    const std::uint64_t shift_amount = ASC_POS_BITS - 2 * level;
    const std::uint64_t hilbert_pos = pos_raw >> shift_amount;

    // Recover XY, downsample, re-encode at (level-1)
    std::uint32_t gx = 0, gy = 0;
    hilbert_to_xy(hilbert_pos, level, &gx, &gy);
    gx >>= 1;
    gy >>= 1;

    const std::uint32_t parent_level = level - 1;
    const std::uint64_t parent_pos = xy_to_hilbert(gx, gy, parent_level);
    const std::uint64_t parent_shift = ASC_POS_BITS - 2 * parent_level;

    return (static_cast<std::uint64_t>(face) << ASC_FACE_SHIFT) |
           ((parent_pos << parent_shift) << ASC_POS_SHIFT) |
           (static_cast<std::uint64_t>(parent_level) << ASC_LEVEL_SHIFT);
}

core::Status latlon_to_st_cell(double lat_deg, double lon_deg,
                               std::uint32_t level,
                               double timestamp_s,
                               std::uint32_t bucket_seconds,
                               AetherSTCellId* out_id) {
    if (!out_id) return core::Status::kInvalidArgument;
    if (bucket_seconds == 0) return core::Status::kInvalidArgument;

    std::uint64_t spatial = 0;
    core::Status s = latlon_to_cell(lat_deg, lon_deg, level, &spatial);
    if (s != core::Status::kOk) return s;

    out_id->spatial = spatial;
    out_id->temporal_bucket = static_cast<std::uint32_t>(
        static_cast<std::uint64_t>(timestamp_s) / bucket_seconds);
    return core::Status::kOk;
}

}  // namespace geo
}  // namespace aether
