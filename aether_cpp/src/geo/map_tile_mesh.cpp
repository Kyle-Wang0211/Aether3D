// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/geo/map_tile_mesh.h"

#include <cmath>
#include <cstring>

namespace aether {
namespace geo {

// ---------------------------------------------------------------------------
// Self-contained protobuf varint decoder
// ---------------------------------------------------------------------------
namespace {

bool read_varint(const std::uint8_t*& ptr, const std::uint8_t* end, std::uint64_t& out) {
    out = 0;
    int shift = 0;
    while (ptr < end) {
        std::uint8_t b = *ptr++;
        out |= static_cast<std::uint64_t>(b & 0x7F) << shift;
        if ((b & 0x80) == 0) return true;
        shift += 7;
        if (shift >= 64) return false;
    }
    return false;
}

void skip_field(const std::uint8_t*& ptr, const std::uint8_t* end, std::uint32_t wire_type) {
    switch (wire_type) {
        case 0: { std::uint64_t v; read_varint(ptr, end, v); break; }
        case 1: ptr += 8; break;
        case 2: {
            std::uint64_t len; read_varint(ptr, end, len);
            ptr += len; break;
        }
        case 5: ptr += 4; break;
        default: break;
    }
    if (ptr > end) ptr = end;
}

}  // anonymous namespace

core::Status mvt_decode_tile(const std::uint8_t* data, std::size_t size,
                             MVTLayer* out_layers, std::size_t max_layers,
                             std::size_t* out_count) {
    if (!out_count) return core::Status::kInvalidArgument;
    *out_count = 0;
    if (!data || size == 0) return core::Status::kOk;

    const std::uint8_t* ptr = data;
    const std::uint8_t* end = data + size;

    while (ptr < end && *out_count < max_layers) {
        std::uint64_t tag;
        if (!read_varint(ptr, end, tag)) break;
        std::uint32_t field = static_cast<std::uint32_t>(tag >> 3);
        std::uint32_t wire = static_cast<std::uint32_t>(tag & 7);

        if (field == 3 && wire == 2) {
            // Tile.layers (field 3, length-delimited)
            std::uint64_t layer_len;
            if (!read_varint(ptr, end, layer_len)) break;
            const std::uint8_t* layer_end = ptr + layer_len;
            if (layer_end > end) layer_end = end;

            MVTLayer& layer = out_layers[*out_count];
            std::memset(&layer, 0, sizeof(MVTLayer));
            layer.extent = 4096;

            // Parse layer fields
            while (ptr < layer_end) {
                std::uint64_t ltag;
                if (!read_varint(ptr, layer_end, ltag)) break;
                std::uint32_t lfield = static_cast<std::uint32_t>(ltag >> 3);
                std::uint32_t lwire = static_cast<std::uint32_t>(ltag & 7);

                if (lfield == 1 && lwire == 2) {
                    // Layer name (field 1, string)
                    std::uint64_t name_len;
                    if (!read_varint(ptr, layer_end, name_len)) break;
                    std::size_t copy_len = (name_len < 63) ? static_cast<std::size_t>(name_len) : 63;
                    std::memcpy(layer.name, ptr, copy_len);
                    layer.name[copy_len] = '\0';
                    ptr += name_len;
                } else if (lfield == 5 && lwire == 0) {
                    // Layer extent (field 5, varint)
                    std::uint64_t ext;
                    if (!read_varint(ptr, layer_end, ext)) break;
                    layer.extent = static_cast<std::uint32_t>(ext);
                } else if (lfield == 2 && lwire == 2) {
                    // Feature (field 2) — count them
                    std::uint64_t feat_len;
                    if (!read_varint(ptr, layer_end, feat_len)) break;
                    ptr += feat_len;
                    layer.feature_count++;
                } else {
                    skip_field(ptr, layer_end, lwire);
                }
            }
            ptr = layer_end;
            (*out_count)++;
        } else {
            skip_field(ptr, end, wire);
        }
    }

    return core::Status::kOk;
}

// ---------------------------------------------------------------------------
// Ear-clipping triangulation
// ---------------------------------------------------------------------------
namespace {

float cross2d(float ax, float ay, float bx, float by) {
    return ax * by - ay * bx;
}

bool point_in_triangle(float px, float py,
                       float ax, float ay, float bx, float by, float cx, float cy) {
    float d1 = cross2d(bx - ax, by - ay, px - ax, py - ay);
    float d2 = cross2d(cx - bx, cy - by, px - bx, py - by);
    float d3 = cross2d(ax - cx, ay - cy, px - cx, py - cy);
    bool has_neg = (d1 < 0) || (d2 < 0) || (d3 < 0);
    bool has_pos = (d1 > 0) || (d2 > 0) || (d3 > 0);
    return !(has_neg && has_pos);
}

}  // anonymous namespace

core::Status triangulate_polygon(const float* ring_xy, std::size_t vertex_count,
                                 std::uint32_t* out_indices, std::size_t max_indices,
                                 std::size_t* out_count) {
    if (!out_count) return core::Status::kInvalidArgument;
    *out_count = 0;
    if (!ring_xy || vertex_count < 3) return core::Status::kInvalidArgument;
    if (!out_indices) return core::Status::kInvalidArgument;

    // Simple ear-clipping
    std::size_t n = vertex_count;
    // Create index array
    std::uint32_t idx[1024];
    if (n > 1024) return core::Status::kResourceExhausted;
    for (std::size_t i = 0; i < n; ++i) idx[i] = static_cast<std::uint32_t>(i);

    std::size_t remaining = n;
    std::size_t tri_count = 0;
    std::size_t max_tris = max_indices / 3;

    std::size_t iterations = 0;
    while (remaining > 2 && tri_count < max_tris) {
        bool ear_found = false;
        for (std::size_t i = 0; i < remaining; ++i) {
            std::size_t prev = (i + remaining - 1) % remaining;
            std::size_t next = (i + 1) % remaining;

            float ax = ring_xy[idx[prev] * 2], ay = ring_xy[idx[prev] * 2 + 1];
            float bx = ring_xy[idx[i] * 2],    by = ring_xy[idx[i] * 2 + 1];
            float cx = ring_xy[idx[next] * 2],  cy = ring_xy[idx[next] * 2 + 1];

            // Check convexity (CCW winding)
            float cross = cross2d(bx - ax, by - ay, cx - bx, cy - by);
            if (cross <= 0) continue;

            // Check no other vertex inside this triangle
            bool is_ear = true;
            for (std::size_t j = 0; j < remaining; ++j) {
                if (j == prev || j == i || j == next) continue;
                float px = ring_xy[idx[j] * 2], py = ring_xy[idx[j] * 2 + 1];
                if (point_in_triangle(px, py, ax, ay, bx, by, cx, cy)) {
                    is_ear = false;
                    break;
                }
            }

            if (is_ear) {
                out_indices[tri_count * 3]     = idx[prev];
                out_indices[tri_count * 3 + 1] = idx[i];
                out_indices[tri_count * 3 + 2] = idx[next];
                tri_count++;

                // Remove vertex i
                for (std::size_t k = i; k < remaining - 1; ++k) {
                    idx[k] = idx[k + 1];
                }
                remaining--;
                ear_found = true;
                break;
            }
        }
        if (!ear_found) break;
        iterations++;
        if (iterations > n * 2) break;
    }

    *out_count = tri_count * 3;
    return core::Status::kOk;
}

// ---------------------------------------------------------------------------
// Polyline expansion
// ---------------------------------------------------------------------------
core::Status expand_polyline(const float* line_xy, std::size_t vertex_count,
                             float width,
                             MapVertex* out_vertices, std::size_t max_vertices,
                             std::size_t* out_count) {
    if (!out_count) return core::Status::kInvalidArgument;
    *out_count = 0;
    if (!line_xy || vertex_count < 2 || !out_vertices) return core::Status::kInvalidArgument;

    float half_w = width * 0.5f;
    std::size_t output_count = 0;

    for (std::size_t i = 0; i < vertex_count && output_count + 2 <= max_vertices; ++i) {
        float dx, dy;
        if (i == 0) {
            dx = line_xy[(i + 1) * 2] - line_xy[i * 2];
            dy = line_xy[(i + 1) * 2 + 1] - line_xy[i * 2 + 1];
        } else if (i == vertex_count - 1) {
            dx = line_xy[i * 2] - line_xy[(i - 1) * 2];
            dy = line_xy[i * 2 + 1] - line_xy[(i - 1) * 2 + 1];
        } else {
            dx = line_xy[(i + 1) * 2] - line_xy[(i - 1) * 2];
            dy = line_xy[(i + 1) * 2 + 1] - line_xy[(i - 1) * 2 + 1];
        }

        float len = std::sqrt(dx * dx + dy * dy);
        if (len < 1e-8f) { dx = 1.0f; dy = 0.0f; len = 1.0f; }
        float nx = -dy / len;
        float ny = dx / len;

        float cx = line_xy[i * 2], cy = line_xy[i * 2 + 1];

        // Left vertex
        MapVertex& vl = out_vertices[output_count++];
        vl.x = cx + nx * half_w;
        vl.y = cy + ny * half_w;
        vl.z = 0;
        vl.u = 0; vl.v = static_cast<float>(i) / (vertex_count - 1);
        vl.nx = 0; vl.ny = 0; vl.nz = 1;

        // Right vertex
        MapVertex& vr = out_vertices[output_count++];
        vr.x = cx - nx * half_w;
        vr.y = cy - ny * half_w;
        vr.z = 0;
        vr.u = 1; vr.v = vl.v;
        vr.nx = 0; vr.ny = 0; vr.nz = 1;
    }

    *out_count = output_count;
    return core::Status::kOk;
}

}  // namespace geo
}  // namespace aether
