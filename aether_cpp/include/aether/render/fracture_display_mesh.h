// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_CPP_RENDER_FRACTURE_DISPLAY_MESH_H
#define AETHER_CPP_RENDER_FRACTURE_DISPLAY_MESH_H

#ifdef __cplusplus

#include "aether/core/status.h"
#include "aether/innovation/core_types.h"

#include <cstddef>
#include <cstdint>
#include <vector>

namespace aether {
namespace render {

struct FragmentVisualParams {
    float edge_length{0.0f};
    float gap_width{0.0f};
    float fill_opacity{0.0f};
    float fill_gray{0.0f};
    float border_width_px{0.0f};
    float border_alpha{0.0f};
    float metallic{0.0f};
    float roughness{0.0f};
    float wedge_thickness{0.0f};

    // PBR extension fields (Cook-Torrance material)
    float f0{0.04f};                   // Fresnel reflectance at normal incidence
    float clearcoat{0.0f};             // Clearcoat layer intensity [0,1]
    float ambient_occlusion{1.0f};     // Ambient occlusion factor [0,1]
};

core::Status generate_fracture_fragments(
    const innovation::ScaffoldUnit* units,
    std::size_t unit_count,
    const innovation::ScaffoldVertex* vertices,
    std::size_t vertex_count,
    const float* per_unit_display,
    const float* per_unit_depth,
    std::vector<innovation::DisplayFragment>* out_fragments);

FragmentVisualParams compute_visual_params(
    float display,
    float depth,
    float triangle_area,
    float median_area);

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
    std::uint8_t* out_count);

}  // namespace render
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_CPP_RENDER_FRACTURE_DISPLAY_MESH_H
