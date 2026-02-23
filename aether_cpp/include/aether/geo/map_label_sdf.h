// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_GEO_MAP_LABEL_SDF_H
#define AETHER_GEO_MAP_LABEL_SDF_H

#include "aether/core/status.h"

#include <cstddef>
#include <cstdint>

namespace aether {
namespace geo {

struct LabelGlyph {
    float x, y, w, h;
    float u0, v0, u1, v1;
};

struct Label {
    float screen_x, screen_y;
    float priority;
    uint32_t glyph_count;
    LabelGlyph glyphs[64];
    bool visible;
};

struct LabelAtlas;

/// Create an SDF glyph atlas with given dimensions.
LabelAtlas* label_atlas_create(uint32_t atlas_width, uint32_t atlas_height);

/// Destroy an SDF glyph atlas.
void label_atlas_destroy(LabelAtlas* atlas);

/// Add a glyph's SDF data to the atlas. Returns kResourceExhausted if full.
core::Status label_atlas_add_glyph(LabelAtlas* atlas, uint32_t codepoint,
                                   const uint8_t* sdf_data,
                                   uint32_t glyph_w, uint32_t glyph_h);

/// Layout labels with priority-based collision avoidance.
/// Writes visible labels to out_visible, up to max_visible.
core::Status label_layout(const Label* labels, size_t count,
                          Label* out_visible, size_t max_visible,
                          size_t* out_count);

}  // namespace geo
}  // namespace aether

#endif  // AETHER_GEO_MAP_LABEL_SDF_H
