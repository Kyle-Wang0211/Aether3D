// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/render/wedge_geometry.h"

#include "aether/core/numeric_guard.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>

namespace aether {
namespace render {
namespace {

constexpr float kEpsilon = 1e-6f;

inline innovation::Float3 add3(const innovation::Float3& a, const innovation::Float3& b) {
    return innovation::make_float3(a.x + b.x, a.y + b.y, a.z + b.z);
}

inline innovation::Float3 sub3(const innovation::Float3& a, const innovation::Float3& b) {
    return innovation::make_float3(a.x - b.x, a.y - b.y, a.z - b.z);
}

inline innovation::Float3 mul3(const innovation::Float3& v, float s) {
    return innovation::make_float3(v.x * s, v.y * s, v.z * s);
}

inline innovation::Float3 neg3(const innovation::Float3& v) {
    return innovation::make_float3(-v.x, -v.y, -v.z);
}

inline float dot3(const innovation::Float3& a, const innovation::Float3& b) {
    return a.x * b.x + a.y * b.y + a.z * b.z;
}

inline innovation::Float3 cross3(const innovation::Float3& a, const innovation::Float3& b) {
    return innovation::make_float3(
        a.y * b.z - a.z * b.y,
        a.z * b.x - a.x * b.z,
        a.x * b.y - a.y * b.x);
}

inline float length_sq3(const innovation::Float3& v) {
    return dot3(v, v);
}

inline innovation::Float3 normalize_or(
    const innovation::Float3& v,
    const innovation::Float3& fallback) {
    const float len_sq = length_sq3(v);
    if (!std::isfinite(len_sq) || len_sq <= kEpsilon * kEpsilon) {
        const float fb_len_sq = length_sq3(fallback);
        if (!std::isfinite(fb_len_sq) || fb_len_sq <= kEpsilon * kEpsilon) {
            return innovation::make_float3(0.0f, 0.0f, 1.0f);
        }
        const float fb_inv_len = 1.0f / std::sqrt(fb_len_sq);
        return mul3(fallback, fb_inv_len);
    }
    const float inv_len = 1.0f / std::sqrt(len_sq);
    return mul3(v, inv_len);
}

inline innovation::Float3 safe_face_normal(
    const innovation::Float3& v0,
    const innovation::Float3& v1,
    const innovation::Float3& v2,
    const innovation::Float3& requested_normal) {
    const innovation::Float3 edge0 = sub3(v1, v0);
    const innovation::Float3 edge1 = sub3(v2, v0);
    const innovation::Float3 geometric = cross3(edge0, edge1);
    return normalize_or(requested_normal, geometric);
}

inline void append_vertex(
    std::vector<WedgeVertex>* out_vertices,
    const innovation::Float3& position,
    const innovation::Float3& normal,
    float metallic,
    float roughness,
    float display,
    float thickness,
    std::uint32_t triangle_id) {
    WedgeVertex vertex{};
    vertex.position = position;
    vertex.normal = normal;
    vertex.metallic = metallic;
    vertex.roughness = roughness;
    vertex.display = display;
    vertex.thickness = thickness;
    vertex.triangle_id = triangle_id;
    out_vertices->push_back(vertex);
}

inline void append_tri(
    std::vector<std::uint32_t>* out_indices,
    std::uint32_t a,
    std::uint32_t b,
    std::uint32_t c) {
    out_indices->push_back(a);
    out_indices->push_back(b);
    out_indices->push_back(c);
}

std::vector<innovation::Float3> bevel_normals(
    const innovation::Float3& top_face_normal,
    const innovation::Float3& side_face_normal,
    int segments) {
    const int safe_segments = std::max(1, segments);
    std::vector<innovation::Float3> normals;
    normals.reserve(static_cast<std::size_t>(safe_segments + 1));
    for (int i = 0; i <= safe_segments; ++i) {
        const float t = static_cast<float>(i) / static_cast<float>(safe_segments);
        const innovation::Float3 mixed = add3(
            mul3(top_face_normal, 1.0f - t),
            mul3(side_face_normal, t));
        normals.push_back(normalize_or(mixed, top_face_normal));
    }
    return normals;
}

void generate_flat_wedge(
    const WedgeTriangleInput& triangle,
    const innovation::Float3& normal,
    std::vector<WedgeVertex>* out_vertices,
    std::vector<std::uint32_t>* out_indices) {
    const std::uint32_t base = static_cast<std::uint32_t>(out_vertices->size());
    append_vertex(out_vertices, triangle.v0, normal, triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);
    append_vertex(out_vertices, triangle.v1, normal, triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);
    append_vertex(out_vertices, triangle.v2, normal, triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);
    append_tri(out_indices, base, base + 1u, base + 2u);
}

void generate_low_lod_wedge(
    const WedgeTriangleInput& triangle,
    const innovation::Float3& normal,
    std::vector<WedgeVertex>* out_vertices,
    std::vector<std::uint32_t>* out_indices) {
    const innovation::Float3 top0 = triangle.v0;
    const innovation::Float3 top1 = triangle.v1;
    const innovation::Float3 top2 = triangle.v2;
    const innovation::Float3 bottom0 = sub3(triangle.v0, mul3(normal, triangle.thickness));
    const innovation::Float3 bottom1 = sub3(triangle.v1, mul3(normal, triangle.thickness));
    const innovation::Float3 bottom2 = sub3(triangle.v2, mul3(normal, triangle.thickness));

    const std::uint32_t base = static_cast<std::uint32_t>(out_vertices->size());

    append_vertex(out_vertices, top0, normal, triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);
    append_vertex(out_vertices, top1, normal, triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);
    append_vertex(out_vertices, top2, normal, triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);

    const innovation::Float3 bottom_normal = neg3(normal);
    append_vertex(out_vertices, bottom0, bottom_normal, triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);
    append_vertex(out_vertices, bottom1, bottom_normal, triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);
    append_vertex(out_vertices, bottom2, bottom_normal, triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);

    append_tri(out_indices, base, base + 1u, base + 2u);
    append_tri(out_indices, base + 5u, base + 4u, base + 3u);

    append_tri(out_indices, base, base + 3u, base + 1u);
    append_tri(out_indices, base + 1u, base + 3u, base + 4u);

    append_tri(out_indices, base + 1u, base + 4u, base + 2u);
    append_tri(out_indices, base + 2u, base + 4u, base + 5u);

    append_tri(out_indices, base + 2u, base + 5u, base);
    append_tri(out_indices, base, base + 5u, base + 3u);
}

void generate_medium_lod_wedge(
    const WedgeTriangleInput& triangle,
    const innovation::Float3& normal,
    std::vector<WedgeVertex>* out_vertices,
    std::vector<std::uint32_t>* out_indices) {
    const int bevel_segments = 1;
    const float bevel_radius = 0.15f * triangle.thickness;
    const innovation::Float3 bevel_offset = mul3(normal, bevel_radius);

    const innovation::Float3 top0 = triangle.v0;
    const innovation::Float3 top1 = triangle.v1;
    const innovation::Float3 top2 = triangle.v2;

    const innovation::Float3 bottom0 = sub3(triangle.v0, mul3(normal, triangle.thickness));
    const innovation::Float3 bottom1 = sub3(triangle.v1, mul3(normal, triangle.thickness));
    const innovation::Float3 bottom2 = sub3(triangle.v2, mul3(normal, triangle.thickness));

    const innovation::Float3 top_bevel0 = sub3(top0, bevel_offset);
    const innovation::Float3 top_bevel1 = sub3(top1, bevel_offset);
    const innovation::Float3 top_bevel2 = sub3(top2, bevel_offset);

    const innovation::Float3 bottom_bevel0 = add3(bottom0, bevel_offset);
    const innovation::Float3 bottom_bevel1 = add3(bottom1, bevel_offset);
    const innovation::Float3 bottom_bevel2 = add3(bottom2, bevel_offset);

    const std::uint32_t base = static_cast<std::uint32_t>(out_vertices->size());

    append_vertex(out_vertices, top_bevel0, normal, triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);
    append_vertex(out_vertices, top_bevel1, normal, triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);
    append_vertex(out_vertices, top_bevel2, normal, triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);

    const innovation::Float3 side01 = normalize_or(
        cross3(normal, sub3(top1, top0)),
        normal);
    const std::vector<innovation::Float3> top_normals01 = bevel_normals(normal, side01, bevel_segments);
    append_vertex(out_vertices, top0, top_normals01[0], triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);
    append_vertex(out_vertices, top_bevel0, top_normals01[1], triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);
    append_vertex(out_vertices, top1, top_normals01[0], triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);
    append_vertex(out_vertices, top_bevel1, top_normals01[1], triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);

    const innovation::Float3 side12 = normalize_or(
        cross3(normal, sub3(top2, top1)),
        normal);
    const std::vector<innovation::Float3> top_normals12 = bevel_normals(normal, side12, bevel_segments);
    append_vertex(out_vertices, top1, top_normals12[0], triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);
    append_vertex(out_vertices, top_bevel1, top_normals12[1], triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);
    append_vertex(out_vertices, top2, top_normals12[0], triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);
    append_vertex(out_vertices, top_bevel2, top_normals12[1], triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);

    const innovation::Float3 side20 = normalize_or(
        cross3(normal, sub3(top0, top2)),
        normal);
    const std::vector<innovation::Float3> top_normals20 = bevel_normals(normal, side20, bevel_segments);
    append_vertex(out_vertices, top2, top_normals20[0], triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);
    append_vertex(out_vertices, top_bevel2, top_normals20[1], triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);
    append_vertex(out_vertices, top0, top_normals20[0], triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);
    append_vertex(out_vertices, top_bevel0, top_normals20[1], triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);

    const innovation::Float3 neg_normal = neg3(normal);
    append_vertex(out_vertices, bottom_bevel0, neg_normal, triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);
    append_vertex(out_vertices, bottom_bevel1, neg_normal, triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);
    append_vertex(out_vertices, bottom_bevel2, neg_normal, triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);

    const innovation::Float3 bottom_side01 = normalize_or(
        cross3(neg_normal, sub3(bottom1, bottom0)),
        neg_normal);
    const std::vector<innovation::Float3> bottom_normals01 = bevel_normals(neg_normal, bottom_side01, bevel_segments);
    append_vertex(out_vertices, bottom0, bottom_normals01[0], triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);
    append_vertex(out_vertices, bottom_bevel0, bottom_normals01[1], triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);
    append_vertex(out_vertices, bottom1, bottom_normals01[0], triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);
    append_vertex(out_vertices, bottom_bevel1, bottom_normals01[1], triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);

    const innovation::Float3 bottom_side12 = normalize_or(
        cross3(neg_normal, sub3(bottom2, bottom1)),
        neg_normal);
    const std::vector<innovation::Float3> bottom_normals12 = bevel_normals(neg_normal, bottom_side12, bevel_segments);
    append_vertex(out_vertices, bottom1, bottom_normals12[0], triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);
    append_vertex(out_vertices, bottom_bevel1, bottom_normals12[1], triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);
    append_vertex(out_vertices, bottom2, bottom_normals12[0], triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);
    append_vertex(out_vertices, bottom_bevel2, bottom_normals12[1], triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);

    const innovation::Float3 bottom_side20 = normalize_or(
        cross3(neg_normal, sub3(bottom0, bottom2)),
        neg_normal);
    const std::vector<innovation::Float3> bottom_normals20 = bevel_normals(neg_normal, bottom_side20, bevel_segments);
    append_vertex(out_vertices, bottom2, bottom_normals20[0], triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);
    append_vertex(out_vertices, bottom_bevel2, bottom_normals20[1], triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);
    append_vertex(out_vertices, bottom0, bottom_normals20[0], triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);
    append_vertex(out_vertices, bottom_bevel0, bottom_normals20[1], triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);

    append_vertex(out_vertices, top_bevel0, side01, triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);
    append_vertex(out_vertices, bottom_bevel0, side01, triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);
    append_vertex(out_vertices, top_bevel1, side01, triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);
    append_vertex(out_vertices, bottom_bevel1, side01, triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);

    append_vertex(out_vertices, top_bevel1, side12, triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);
    append_vertex(out_vertices, bottom_bevel1, side12, triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);
    append_vertex(out_vertices, top_bevel2, side12, triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);
    append_vertex(out_vertices, bottom_bevel2, side12, triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);

    append_vertex(out_vertices, top_bevel2, side20, triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);
    append_vertex(out_vertices, bottom_bevel2, side20, triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);
    append_vertex(out_vertices, top_bevel0, side20, triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);
    append_vertex(out_vertices, bottom_bevel0, side20, triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);

    append_tri(out_indices, base, base + 1u, base + 2u);

    std::uint32_t idx = base + 3u;
    for (int e = 0; e < 3; ++e) {
        append_tri(out_indices, idx, idx + 1u, idx + 2u);
        append_tri(out_indices, idx + 2u, idx + 1u, idx + 3u);
        idx += 4u;
    }

    append_tri(out_indices, base + 15u, base + 16u, base + 17u);

    idx = base + 18u;
    for (int e = 0; e < 3; ++e) {
        append_tri(out_indices, idx, idx + 2u, idx + 1u);
        append_tri(out_indices, idx + 1u, idx + 2u, idx + 3u);
        idx += 4u;
    }

    idx = base + 30u;
    for (int e = 0; e < 3; ++e) {
        append_tri(out_indices, idx, idx + 1u, idx + 2u);
        append_tri(out_indices, idx + 2u, idx + 1u, idx + 3u);
        idx += 4u;
    }
}

void append_full_bevel_strip(
    std::vector<WedgeVertex>* out_vertices,
    const WedgeTriangleInput& triangle,
    const innovation::Float3& outer_start,
    const innovation::Float3& outer_end,
    const innovation::Float3& inner_start,
    const innovation::Float3& inner_end,
    const innovation::Float3& face_normal,
    const innovation::Float3& edge_direction,
    int bevel_segments) {
    const innovation::Float3 side_normal = normalize_or(
        cross3(face_normal, edge_direction),
        face_normal);
    const std::vector<innovation::Float3> normals = bevel_normals(face_normal, side_normal, bevel_segments);

    const innovation::Float3 mid_start = mul3(add3(outer_start, inner_start), 0.5f);
    const innovation::Float3 mid_end = mul3(add3(outer_end, inner_end), 0.5f);

    const innovation::Float3 n0 = normals[0];
    const innovation::Float3 n1 = normals.size() > 1u
        ? normals[1]
        : normalize_or(add3(face_normal, side_normal), face_normal);
    const innovation::Float3 n2 = normals.size() > 2u ? normals[2] : side_normal;

    append_vertex(out_vertices, outer_start, n0, triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);
    append_vertex(out_vertices, outer_end, n0, triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);
    append_vertex(out_vertices, mid_start, n1, triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);
    append_vertex(out_vertices, mid_end, n1, triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);
    append_vertex(out_vertices, inner_start, n2, triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);
    append_vertex(out_vertices, inner_end, n2, triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);
}

void generate_full_lod_wedge(
    const WedgeTriangleInput& triangle,
    const innovation::Float3& normal,
    std::vector<WedgeVertex>* out_vertices,
    std::vector<std::uint32_t>* out_indices) {
    const int bevel_segments = 2;
    const float bevel_radius = 0.15f * triangle.thickness;

    const innovation::Float3 top0 = triangle.v0;
    const innovation::Float3 top1 = triangle.v1;
    const innovation::Float3 top2 = triangle.v2;
    const innovation::Float3 bottom0 = sub3(triangle.v0, mul3(normal, triangle.thickness));
    const innovation::Float3 bottom1 = sub3(triangle.v1, mul3(normal, triangle.thickness));
    const innovation::Float3 bottom2 = sub3(triangle.v2, mul3(normal, triangle.thickness));

    const innovation::Float3 bevel_offset = mul3(normal, bevel_radius);
    const innovation::Float3 top_bevel0 = sub3(top0, bevel_offset);
    const innovation::Float3 top_bevel1 = sub3(top1, bevel_offset);
    const innovation::Float3 top_bevel2 = sub3(top2, bevel_offset);
    const innovation::Float3 bottom_bevel0 = add3(bottom0, bevel_offset);
    const innovation::Float3 bottom_bevel1 = add3(bottom1, bevel_offset);
    const innovation::Float3 bottom_bevel2 = add3(bottom2, bevel_offset);

    const std::uint32_t base = static_cast<std::uint32_t>(out_vertices->size());

    append_vertex(out_vertices, top_bevel0, normal, triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);
    append_vertex(out_vertices, top_bevel1, normal, triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);
    append_vertex(out_vertices, top_bevel2, normal, triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);
    append_tri(out_indices, base, base + 1u, base + 2u);

    std::uint32_t current = base + 3u;

    append_full_bevel_strip(out_vertices, triangle,
                            top0, top1, top_bevel0, top_bevel1,
                            normal, normalize_or(sub3(top1, top0), normal),
                            bevel_segments);
    for (int seg = 0; seg < bevel_segments; ++seg) {
        const std::uint32_t row = current + static_cast<std::uint32_t>(seg * 2);
        append_tri(out_indices, row, row + 2u, row + 1u);
        append_tri(out_indices, row + 1u, row + 2u, row + 3u);
    }
    current += 6u;

    append_full_bevel_strip(out_vertices, triangle,
                            top1, top2, top_bevel1, top_bevel2,
                            normal, normalize_or(sub3(top2, top1), normal),
                            bevel_segments);
    for (int seg = 0; seg < bevel_segments; ++seg) {
        const std::uint32_t row = current + static_cast<std::uint32_t>(seg * 2);
        append_tri(out_indices, row, row + 2u, row + 1u);
        append_tri(out_indices, row + 1u, row + 2u, row + 3u);
    }
    current += 6u;

    append_full_bevel_strip(out_vertices, triangle,
                            top2, top0, top_bevel2, top_bevel0,
                            normal, normalize_or(sub3(top0, top2), normal),
                            bevel_segments);
    for (int seg = 0; seg < bevel_segments; ++seg) {
        const std::uint32_t row = current + static_cast<std::uint32_t>(seg * 2);
        append_tri(out_indices, row, row + 2u, row + 1u);
        append_tri(out_indices, row + 1u, row + 2u, row + 3u);
    }
    current += 6u;

    const innovation::Float3 neg_normal = neg3(normal);
    append_vertex(out_vertices, bottom_bevel0, neg_normal, triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);
    append_vertex(out_vertices, bottom_bevel1, neg_normal, triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);
    append_vertex(out_vertices, bottom_bevel2, neg_normal, triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);
    append_tri(out_indices, current + 2u, current + 1u, current);
    current += 3u;

    append_full_bevel_strip(out_vertices, triangle,
                            bottom0, bottom1, bottom_bevel0, bottom_bevel1,
                            neg_normal, normalize_or(sub3(bottom1, bottom0), neg_normal),
                            bevel_segments);
    for (int seg = 0; seg < bevel_segments; ++seg) {
        const std::uint32_t row = current + static_cast<std::uint32_t>(seg * 2);
        append_tri(out_indices, row, row + 1u, row + 2u);
        append_tri(out_indices, row + 1u, row + 3u, row + 2u);
    }
    current += 6u;

    append_full_bevel_strip(out_vertices, triangle,
                            bottom1, bottom2, bottom_bevel1, bottom_bevel2,
                            neg_normal, normalize_or(sub3(bottom2, bottom1), neg_normal),
                            bevel_segments);
    for (int seg = 0; seg < bevel_segments; ++seg) {
        const std::uint32_t row = current + static_cast<std::uint32_t>(seg * 2);
        append_tri(out_indices, row, row + 1u, row + 2u);
        append_tri(out_indices, row + 1u, row + 3u, row + 2u);
    }
    current += 6u;

    append_full_bevel_strip(out_vertices, triangle,
                            bottom2, bottom0, bottom_bevel2, bottom_bevel0,
                            neg_normal, normalize_or(sub3(bottom0, bottom2), neg_normal),
                            bevel_segments);
    for (int seg = 0; seg < bevel_segments; ++seg) {
        const std::uint32_t row = current + static_cast<std::uint32_t>(seg * 2);
        append_tri(out_indices, row, row + 1u, row + 2u);
        append_tri(out_indices, row + 1u, row + 3u, row + 2u);
    }
    current += 6u;

    const innovation::Float3 side01 = normalize_or(cross3(normal, sub3(top1, top0)), normal);
    append_vertex(out_vertices, top_bevel0, side01, triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);
    append_vertex(out_vertices, bottom_bevel0, side01, triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);
    append_vertex(out_vertices, top_bevel1, side01, triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);
    append_vertex(out_vertices, bottom_bevel1, side01, triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);
    append_tri(out_indices, current, current + 1u, current + 2u);
    append_tri(out_indices, current + 2u, current + 1u, current + 3u);
    current += 4u;

    const innovation::Float3 side12 = normalize_or(cross3(normal, sub3(top2, top1)), normal);
    append_vertex(out_vertices, top_bevel1, side12, triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);
    append_vertex(out_vertices, bottom_bevel1, side12, triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);
    append_vertex(out_vertices, top_bevel2, side12, triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);
    append_vertex(out_vertices, bottom_bevel2, side12, triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);
    append_tri(out_indices, current, current + 1u, current + 2u);
    append_tri(out_indices, current + 2u, current + 1u, current + 3u);
    current += 4u;

    const innovation::Float3 side20 = normalize_or(cross3(normal, sub3(top0, top2)), normal);
    append_vertex(out_vertices, top_bevel2, side20, triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);
    append_vertex(out_vertices, bottom_bevel2, side20, triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);
    append_vertex(out_vertices, top_bevel0, side20, triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);
    append_vertex(out_vertices, bottom_bevel0, side20, triangle.metallic, triangle.roughness,
                  triangle.display, triangle.thickness, triangle.triangle_id);
    append_tri(out_indices, current, current + 1u, current + 2u);
    append_tri(out_indices, current + 2u, current + 1u, current + 3u);
}

void sanitize_vertices(std::vector<WedgeVertex>* vertices) {
    for (WedgeVertex& v : *vertices) {
        core::guard_finite_scalar(&v.position.x);
        core::guard_finite_scalar(&v.position.y);
        core::guard_finite_scalar(&v.position.z);
        core::guard_finite_scalar(&v.normal.x);
        core::guard_finite_scalar(&v.normal.y);
        core::guard_finite_scalar(&v.normal.z);
        core::guard_finite_scalar(&v.metallic);
        core::guard_finite_scalar(&v.roughness);
        core::guard_finite_scalar(&v.display);
        core::guard_finite_scalar(&v.thickness);
    }
}

}  // namespace

core::Status generate_wedge_geometry(
    const WedgeTriangleInput* triangles,
    std::size_t triangle_count,
    WedgeLodLevel lod,
    std::vector<WedgeVertex>* out_vertices,
    std::vector<std::uint32_t>* out_indices) {
    if (out_vertices == nullptr || out_indices == nullptr) {
        return core::Status::kInvalidArgument;
    }
    out_vertices->clear();
    out_indices->clear();

    if (triangle_count == 0u) {
        return core::Status::kOk;
    }
    if (triangles == nullptr) {
        return core::Status::kInvalidArgument;
    }

    std::size_t vertices_per_triangle = 0u;
    std::size_t indices_per_triangle = 0u;
    switch (lod) {
        case WedgeLodLevel::kFlat:
            vertices_per_triangle = 3u;
            indices_per_triangle = 3u;
            break;
        case WedgeLodLevel::kLow:
            vertices_per_triangle = 6u;
            indices_per_triangle = 24u;
            break;
        case WedgeLodLevel::kMedium:
            vertices_per_triangle = 42u;
            indices_per_triangle = 60u;
            break;
        case WedgeLodLevel::kFull:
            vertices_per_triangle = 54u;
            indices_per_triangle = 96u;
            break;
        default:
            return core::Status::kInvalidArgument;
    }

    out_vertices->reserve(triangle_count * vertices_per_triangle);
    out_indices->reserve(triangle_count * indices_per_triangle);

    for (std::size_t i = 0u; i < triangle_count; ++i) {
        const WedgeTriangleInput& triangle = triangles[i];
        const innovation::Float3 normal = safe_face_normal(
            triangle.v0,
            triangle.v1,
            triangle.v2,
            triangle.normal);

        switch (lod) {
            case WedgeLodLevel::kFlat:
                generate_flat_wedge(triangle, normal, out_vertices, out_indices);
                break;
            case WedgeLodLevel::kLow:
                generate_low_lod_wedge(triangle, normal, out_vertices, out_indices);
                break;
            case WedgeLodLevel::kMedium:
                generate_medium_lod_wedge(triangle, normal, out_vertices, out_indices);
                break;
            case WedgeLodLevel::kFull:
                generate_full_lod_wedge(triangle, normal, out_vertices, out_indices);
                break;
            default:
                return core::Status::kInvalidArgument;
        }
    }

    sanitize_vertices(out_vertices);
    return core::Status::kOk;
}

}  // namespace render
}  // namespace aether
