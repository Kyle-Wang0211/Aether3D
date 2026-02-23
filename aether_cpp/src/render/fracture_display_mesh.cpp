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

    const float wedge_base = 0.008f;
    const float wedge_min = 0.0005f;
    const float wedge_exponent = 0.7f;
    const float decay = std::pow(1.0f - d, wedge_exponent);
    const float area_factor = std::max(0.5f, std::min(2.0f, std::sqrt(triangle_area / std::max(median_area, 1e-6f))));
    p.gap_width = std::max(wedge_min, wedge_base * decay * area_factor);
    p.wedge_thickness = p.gap_width;

    const float s4 = tsdf::smoothstep(0.75f, 0.88f, d);
    // Piecewise linear gray mapping — steeper at low end so S0-S2 are
    // visually distinguishable (old formula produced RGB 7/17 at S1/S2;
    // new formula produces RGB 51/128, matching CoverageVisualizationConstants).
    float gray_pre;
    if (d <= 0.25f) {
        // S0-S2 range: steep ramp 0 → 0.50 (RGB 0 → 128)
        gray_pre = (d / 0.25f) * 0.50f;
    } else if (d <= 0.50f) {
        // S2-S3 range: moderate ramp 0.50 → 0.65
        gray_pre = 0.50f + ((d - 0.25f) / 0.25f) * 0.15f;
    } else {
        // S3-S4 range: gentle ramp 0.65 → 200/255 ≈ 0.784
        gray_pre = 0.65f + ((d - 0.50f) / 0.25f) * (200.0f / 255.0f - 0.65f);
    }
    gray_pre = clamp01(gray_pre);
    p.fill_gray = gray_pre * (1.0f - s4) + 1.0f * s4;
    p.fill_opacity = tsdf::continuous_fill_opacity(d);

    const float border_base = 6.0f;
    const float border_gamma = 1.4f;
    const float display_factor = 0.6f * (1.0f - d);
    const float area_border_factor = 0.4f * area_factor;
    const float combined = display_factor + area_border_factor;
    p.border_width_px = std::max(1.0f, std::min(12.0f, border_base * std::pow(combined, border_gamma)));

    const float display_fade = 1.0f - d * 0.5f;
    p.border_alpha = std::pow(std::max(0.0f, display_fade), 1.0f / border_gamma);

    const float s3 = tsdf::smoothstep(0.45f, 0.55f, d);
    p.metallic = 0.3f + 0.4f * s3;
    p.roughness = 0.6f - 0.3f * s3;

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
    innovation::DisplayFragment* out_fragments,
    std::uint8_t* out_count) {
    if (out_fragments == nullptr || out_count == nullptr) {
        return;
    }

    const innovation::Float3 center = triangle_centroid(a, b, c);
    const std::uint8_t count = static_cast<std::uint8_t>(1u + (seed % 6u));
    const float gap = std::max(0.0f, std::min(0.45f, gap_ratio));

    for (std::uint8_t i = 0u; i < count; ++i) {
        const float t0 = static_cast<float>(i) / static_cast<float>(count);
        const float t1 = static_cast<float>(i + 1u) / static_cast<float>(count);
        innovation::DisplayFragment frag{};
        frag.vertex_count = 3u;
        frag.vertices[0] = shrink_toward(center, center, gap);
        frag.vertices[1] = shrink_toward(perimeter_point(a, b, c, t0), center, gap);
        frag.vertices[2] = shrink_toward(perimeter_point(a, b, c, t1), center, gap);
        frag.centroid = triangle_centroid(frag.vertices[0], frag.vertices[1], frag.vertices[2]);
        out_fragments[i] = frag;
    }

    *out_count = count;
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
    out_fragments->reserve(unit_count * 6u);
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
        const float gap_ratio = clamp01(params.gap_width / 0.008f);

        innovation::DisplayFragment local[6]{};
        std::uint8_t local_count = 0u;
        voronoi_subdivide_triangle(a, b, c, innovation::splitmix64(unit.unit_id), gap_ratio, local, &local_count);

        for (std::uint8_t j = 0u; j < local_count; ++j) {
            innovation::DisplayFragment frag = local[j];
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
