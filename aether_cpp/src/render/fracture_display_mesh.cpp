// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/render/fracture_display_mesh.h"

#include "aether/core/numeric_guard.h"
#include "aether/innovation/core_types.h"
#include "aether/tsdf/adaptive_resolution.h"

#include <algorithm>
#include <cmath>

namespace aether {
namespace render {
namespace {

inline float clamp01(float v) {
    return std::max(0.0f, std::min(1.0f, v));
}

inline innovation::Float3 lerp3(const innovation::Float3& a, const innovation::Float3& b, float t) {
    return innovation::make_float3(
        a.x + (b.x - a.x) * t,
        a.y + (b.y - a.y) * t,
        a.z + (b.z - a.z) * t);
}

inline innovation::Float3 shrink_toward(
    const innovation::Float3& p,
    const innovation::Float3& center,
    float ratio) {
    return lerp3(p, center, clamp01(ratio));
}

inline float rand01(std::uint64_t* state) {
    if (state == nullptr) {
        return 0.0f;
    }
    *state = innovation::splitmix64(*state);
    return static_cast<float>(*state & 0x00FFFFFFu) / static_cast<float>(0x00FFFFFFu);
}

innovation::Float3 triangle_centroid(
    const innovation::Float3& a,
    const innovation::Float3& b,
    const innovation::Float3& c) {
    return innovation::make_float3(
        (a.x + b.x + c.x) / 3.0f,
        (a.y + b.y + c.y) / 3.0f,
        (a.z + b.z + c.z) / 3.0f);
}

innovation::Float3 perimeter_point(
    const innovation::Float3& a,
    const innovation::Float3& b,
    const innovation::Float3& c,
    float t) {
    const float w = t - std::floor(t);
    const float segment = w * 3.0f;
    if (segment < 1.0f) {
        return lerp3(a, b, segment);
    }
    if (segment < 2.0f) {
        return lerp3(b, c, segment - 1.0f);
    }
    return lerp3(c, a, segment - 2.0f);
}

inline float distance3(const innovation::Float3& lhs, const innovation::Float3& rhs) {
    const float dx = lhs.x - rhs.x;
    const float dy = lhs.y - rhs.y;
    const float dz = lhs.z - rhs.z;
    return std::sqrt(dx * dx + dy * dy + dz * dz);
}

}  // namespace

FragmentVisualParams compute_visual_params(
    float display,
    float depth,
    float triangle_area,
    float median_area) {
    FragmentVisualParams p{};
    const float d = clamp01(display);

    const tsdf::ContinuousResolutionConfig cfg = tsdf::default_continuous_resolution_config();
    p.edge_length = tsdf::continuous_edge_length(depth, d, false, cfg);

    const float safe_depth = std::max(0.05f, std::min(3.0f, depth));
    const float depth_norm = clamp01((safe_depth - 0.25f) / 1.75f);  // near=0, far=1
    // Keep wedges visually connected on dense LiDAR meshes.
    // Lower base gap prevents the "floating glyph grid" look.
    const float wedge_base = 0.0013f;
    const float wedge_min = 0.00004f;
    const float wedge_exponent = 0.82f;
    const float decay = std::pow(1.0f - d, wedge_exponent);
    const float area_factor = std::max(0.6f, std::min(1.8f, std::sqrt(triangle_area / std::max(median_area, 1e-6f))));
    const float depth_gap_scale = 0.55f + 0.40f * depth_norm;
    p.gap_width = std::max(wedge_min, wedge_base * decay * area_factor);
    p.gap_width *= depth_gap_scale;
    p.wedge_thickness = p.gap_width;

    const float s4 = tsdf::smoothstep(0.75f, 0.88f, d);
    // Capture-first mapping: keep S0-S2 near-black, then brighten smoothly.
    // This preserves "black fill + white border" at scan start.
    const float low_response = std::pow(d, 1.8f);
    const float mid_lift = tsdf::smoothstep(0.35f, 0.75f, d);
    const float gray_pre = clamp01(0.02f + 0.78f * low_response + 0.15f * mid_lift);
    p.fill_gray = gray_pre * (1.0f - s4) + 1.0f * s4;
    p.fill_opacity = tsdf::continuous_fill_opacity(d);

    const float darkness = 1.0f - d;
    const float depth_border_scale = 0.70f + 0.60f * depth_norm;
    const float area_border_scale = 0.65f + 0.45f * area_factor;
    const float border_energy = std::max(0.0f, darkness * depth_border_scale * area_border_scale);
    p.border_width_px = std::max(3.2f, std::min(34.0f, 3.2f + 24.0f * std::pow(border_energy, 0.74f)));
    p.border_alpha = std::max(
        0.16f,
        std::min(
            1.0f,
            0.18f + 0.82f * std::pow(
                std::max(0.0f, darkness * (0.75f + 0.25f * depth_norm)),
                0.70f)));

    // Material parameters derived in core without platform-specific shader hooks.
    const float area_metallic_boost = 1.0f + 0.3f * (area_factor - 1.0f);
    p.metallic = std::max(0.0f, std::min(1.0f, (0.30f + 0.40f * d) * area_metallic_boost));
    p.roughness = std::max(0.05f, std::min(1.0f, 0.65f - 0.45f * d));
    p.f0 = 0.04f;
    p.clearcoat = std::max(0.0f, std::min(0.3f, (d - 0.75f) * 1.2f));
    p.ambient_occlusion = 1.0f;

    // C01 NumericGuard: guard visual params derived from pow/sqrt/division
    core::guard_finite_vector(reinterpret_cast<float*>(&p), sizeof(p) / sizeof(float));

    return p;
}

void voronoi_subdivide_triangle(
    const innovation::Float3& a,
    const innovation::Float3& b,
    const innovation::Float3& c,
    std::uint64_t seed,
    float gap_ratio,
    std::uint8_t min_fragments,
    std::uint8_t max_fragments,
    float inner_jitter,
    innovation::DisplayFragment* out_fragments,
    std::uint8_t* out_count) {
    if (out_fragments == nullptr || out_count == nullptr) {
        return;
    }

    // Keep fragments visually connected ("broken glass"), avoid over-shrinking islands.
    const float gap = std::max(0.0f, std::min(0.0045f, gap_ratio));
    const std::uint8_t safe_min = std::max<std::uint8_t>(1u, std::min<std::uint8_t>(8u, min_fragments));
    const std::uint8_t safe_max = std::max(safe_min, std::min<std::uint8_t>(8u, max_fragments));

    const innovation::Float3 centroid = triangle_centroid(a, b, c);
    std::uint64_t random_state = innovation::splitmix64(seed ^ 0xD1B54A32D192ED03ULL);
    std::uint8_t count = safe_min;
    if (safe_max > safe_min) {
        const std::uint8_t span = static_cast<std::uint8_t>(safe_max - safe_min + 1u);
        const std::uint8_t offset = static_cast<std::uint8_t>(
            std::min<float>(
                static_cast<float>(span - 1u),
                std::floor(rand01(&random_state) * static_cast<float>(span))));
        count = static_cast<std::uint8_t>(safe_min + offset);
    }

    struct LocalTri {
        innovation::Float3 v0;
        innovation::Float3 v1;
        innovation::Float3 v2;
    };
    auto tri_area = [](const LocalTri& tri) -> float {
        return innovation::triangle_area(tri.v0, tri.v1, tri.v2);
    };
    auto tri_centroid = [](const LocalTri& tri) -> innovation::Float3 {
        return triangle_centroid(tri.v0, tri.v1, tri.v2);
    };

    LocalTri shards[8]{};
    std::uint8_t shard_count = 1u;
    shards[0] = LocalTri{a, b, c};

    while (shard_count < count) {
        std::uint8_t split_idx = 0u;
        float split_area = -1.0f;
        for (std::uint8_t i = 0u; i < shard_count; ++i) {
            const float area = tri_area(shards[i]);
            if (area > split_area) {
                split_area = area;
                split_idx = i;
            }
        }
        if (!(split_area > 1e-10f)) {
            break;
        }

        LocalTri base = shards[split_idx];
        const float l01 = distance3(base.v0, base.v1);
        const float l12 = distance3(base.v1, base.v2);
        const float l20 = distance3(base.v2, base.v0);

        innovation::Float3 e0 = base.v0;
        innovation::Float3 e1 = base.v1;
        innovation::Float3 opposite = base.v2;
        if (l12 >= l01 && l12 >= l20) {
            e0 = base.v1;
            e1 = base.v2;
            opposite = base.v0;
        } else if (l20 >= l01 && l20 >= l12) {
            e0 = base.v2;
            e1 = base.v0;
            opposite = base.v1;
        }

        const float t = 0.18f + 0.64f * rand01(&random_state);
        innovation::Float3 split = lerp3(e0, e1, t);
        const innovation::Float3 center = tri_centroid(base);
        const float center_pull = 0.08f + 0.28f * rand01(&random_state);
        split = lerp3(split, center, center_pull);
        const float jitter = (rand01(&random_state) - 0.5f) * inner_jitter * 0.22f;
        split = lerp3(split, center, jitter);

        LocalTri t0{opposite, e0, split};
        LocalTri t1{opposite, split, e1};
        if (tri_area(t0) <= 1e-10f || tri_area(t1) <= 1e-10f) {
            break;
        }

        shards[split_idx] = t0;
        shards[shard_count] = t1;
        ++shard_count;
    }

    for (std::uint8_t i = 0u; i < shard_count; ++i) {
        const LocalTri tri = shards[i];
        const innovation::Float3 center = tri_centroid(tri);
        const float local_gap = gap * (0.35f + 0.55f * rand01(&random_state));
        innovation::DisplayFragment frag{};
        frag.vertex_count = 3u;
        frag.vertices[0] = shrink_toward(tri.v0, center, local_gap);
        frag.vertices[1] = shrink_toward(tri.v1, center, local_gap);
        frag.vertices[2] = shrink_toward(tri.v2, center, local_gap);
        frag.centroid = triangle_centroid(frag.vertices[0], frag.vertices[1], frag.vertices[2]);
        out_fragments[i] = frag;
    }

    *out_count = shard_count;
}

core::Status generate_fracture_fragments(
    const innovation::ScaffoldUnit* units,
    std::size_t unit_count,
    const innovation::ScaffoldVertex* vertices,
    std::size_t vertex_count,
    const float* per_unit_display,
    const float* per_unit_depth,
    std::vector<innovation::DisplayFragment>* out_fragments) {
    if (out_fragments == nullptr) {
        return core::Status::kInvalidArgument;
    }
    out_fragments->clear();
    if ((unit_count > 0u && units == nullptr) || (vertex_count > 0u && vertices == nullptr)) {
        return core::Status::kInvalidArgument;
    }
    out_fragments->reserve(unit_count * 6u);

    float median_area = 1e-4f;
    if (unit_count > 0u) {
        std::vector<float> areas;
        areas.reserve(unit_count);
        for (std::size_t i = 0u; i < unit_count; ++i) {
            areas.push_back(std::max(1e-8f, units[i].area));
        }
        std::nth_element(areas.begin(), areas.begin() + static_cast<std::ptrdiff_t>(areas.size() / 2u), areas.end());
        median_area = areas[areas.size() / 2u];
    }

    for (std::size_t i = 0u; i < unit_count; ++i) {
        const innovation::ScaffoldUnit& unit = units[i];
        if (unit.v0 >= vertex_count || unit.v1 >= vertex_count || unit.v2 >= vertex_count) {
            continue;
        }
        const innovation::Float3 a = vertices[unit.v0].position;
        const innovation::Float3 b = vertices[unit.v1].position;
        const innovation::Float3 c = vertices[unit.v2].position;

        const float display = per_unit_display != nullptr ? per_unit_display[i] : clamp01(unit.confidence);
        const float depth = per_unit_depth != nullptr ? per_unit_depth[i] : 1.0f;
        const FragmentVisualParams params = compute_visual_params(display, depth, std::max(1e-8f, unit.area), median_area);
        const float mean_edge = std::max(1e-4f, (distance3(a, b) + distance3(b, c) + distance3(c, a)) / 3.0f);
        // Keep shards connected: clamp to a small shrink ratio in triangle-local scale.
        const float gap_ratio = std::max(0.0f, std::min(0.0045f, params.gap_width / mean_edge));
        const float safe_depth = std::max(0.05f, std::min(3.0f, depth));
        const float depth_norm = clamp01((safe_depth - 0.25f) / 1.75f);
        const float area_factor = std::max(
            0.6f,
            std::min(1.8f, std::sqrt(std::max(1e-8f, unit.area) / std::max(median_area, 1e-6f))));
        const float detail_level = clamp01(
            0.72f * display +
            0.18f * (1.0f - depth_norm) +
            0.10f * (1.0f / area_factor));
        const std::uint8_t min_fragments = static_cast<std::uint8_t>(
            std::max(1, std::min(4, 1 + static_cast<int>(std::floor(2.2f * detail_level)))));
        const std::uint8_t max_fragments = static_cast<std::uint8_t>(
            std::max(
                static_cast<int>(min_fragments),
                std::min(8, 2 + static_cast<int>(std::lround(7.0f * detail_level)))));
        const float inner_jitter = std::max(
            0.20f,
            std::min(0.75f, 0.25f + 0.35f * depth_norm + 0.25f * (1.0f - display)));

        // Keep capacity aligned with voronoi_subdivide_triangle() safe_max (8).
        innovation::DisplayFragment local[8]{};
        std::uint8_t local_count = 0u;
        voronoi_subdivide_triangle(
            a,
            b,
            c,
            innovation::splitmix64(unit.unit_id),
            gap_ratio,
            min_fragments,
            max_fragments,
            inner_jitter,
            local,
            &local_count);

        for (std::uint8_t j = 0u; j < local_count; ++j) {
            innovation::DisplayFragment frag = local[j];
            if (frag.vertex_count < 3u) {
                continue;
            }
            const float area = innovation::triangle_area(frag.vertices[0], frag.vertices[1], frag.vertices[2]);
            if (!std::isfinite(area) || area <= 1e-10f) {
                continue;
            }
            frag.parent_unit_id = unit.unit_id;
            frag.sub_index = j;
            frag.normal = unit.normal;
            frag.display = display;
            frag.gap_shrink = gap_ratio;
            const std::uint64_t seed = innovation::splitmix64(unit.unit_id ^ static_cast<std::uint64_t>(j));
            frag.crack_seed = static_cast<float>(seed & 0x00FFFFFFu) / static_cast<float>(0x00FFFFFFu);
            out_fragments->push_back(frag);
        }
    }

    if (unit_count == 0u) {
        return core::Status::kOk;
    }
    return out_fragments->empty() ? core::Status::kOutOfRange : core::Status::kOk;
}

}  // namespace render
}  // namespace aether
