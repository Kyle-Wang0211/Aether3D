// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/geo/map_label_sdf.h"

#include <cstdlib>
#include <cstring>

namespace aether {
namespace geo {

// ---------------------------------------------------------------------------
// Internal atlas structure: row-major bin-packer for glyphs
// ---------------------------------------------------------------------------
static constexpr uint32_t kMaxGlyphs = 4096;

struct GlyphEntry {
    uint32_t codepoint;
    uint32_t x, y, w, h;
};

struct LabelAtlas {
    uint32_t width;
    uint32_t height;
    uint8_t* pixels;      // atlas_width * atlas_height

    // Row-major bin-packer state
    uint32_t cursor_x;    // Current x position in current row
    uint32_t cursor_y;    // Current row y position
    uint32_t row_height;  // Height of tallest glyph in current row

    GlyphEntry glyphs[kMaxGlyphs];
    uint32_t glyph_count;
};

LabelAtlas* label_atlas_create(uint32_t atlas_width, uint32_t atlas_height) {
    if (atlas_width == 0 || atlas_height == 0) return nullptr;

    auto* atlas = static_cast<LabelAtlas*>(std::calloc(1, sizeof(LabelAtlas)));
    if (!atlas) return nullptr;

    atlas->width = atlas_width;
    atlas->height = atlas_height;
    atlas->pixels = static_cast<uint8_t*>(std::calloc(atlas_width * atlas_height, 1));
    if (!atlas->pixels) {
        std::free(atlas);
        return nullptr;
    }

    atlas->cursor_x = 0;
    atlas->cursor_y = 0;
    atlas->row_height = 0;
    atlas->glyph_count = 0;

    return atlas;
}

void label_atlas_destroy(LabelAtlas* atlas) {
    if (!atlas) return;
    std::free(atlas->pixels);
    std::free(atlas);
}

core::Status label_atlas_add_glyph(LabelAtlas* atlas, uint32_t codepoint,
                                   const uint8_t* sdf_data,
                                   uint32_t glyph_w, uint32_t glyph_h) {
    if (!atlas || !sdf_data) return core::Status::kInvalidArgument;
    if (glyph_w == 0 || glyph_h == 0) return core::Status::kInvalidArgument;
    if (atlas->glyph_count >= kMaxGlyphs) return core::Status::kResourceExhausted;

    // Row-major bin-packing: try to place in current row
    if (atlas->cursor_x + glyph_w > atlas->width) {
        // Advance to next row
        atlas->cursor_y += atlas->row_height;
        atlas->cursor_x = 0;
        atlas->row_height = 0;
    }

    // Check vertical fit
    if (atlas->cursor_y + glyph_h > atlas->height) {
        return core::Status::kResourceExhausted;
    }

    // Place glyph
    uint32_t px = atlas->cursor_x;
    uint32_t py = atlas->cursor_y;

    // Copy SDF data into atlas
    for (uint32_t row = 0; row < glyph_h; ++row) {
        uint32_t dst_offset = (py + row) * atlas->width + px;
        uint32_t src_offset = row * glyph_w;
        std::memcpy(&atlas->pixels[dst_offset], &sdf_data[src_offset], glyph_w);
    }

    // Record glyph entry
    GlyphEntry& entry = atlas->glyphs[atlas->glyph_count];
    entry.codepoint = codepoint;
    entry.x = px;
    entry.y = py;
    entry.w = glyph_w;
    entry.h = glyph_h;
    atlas->glyph_count++;

    // Advance cursor
    atlas->cursor_x += glyph_w;
    if (glyph_h > atlas->row_height) {
        atlas->row_height = glyph_h;
    }

    return core::Status::kOk;
}

// ---------------------------------------------------------------------------
// label_layout: priority-based collision avoidance using grid
// ---------------------------------------------------------------------------
namespace {

struct AABB {
    float x0, y0, x1, y1;
};

bool aabb_overlaps(const AABB& a, const AABB& b) {
    return !(a.x1 <= b.x0 || b.x1 <= a.x0 || a.y1 <= b.y0 || b.y1 <= a.y0);
}

AABB label_bounds(const Label& label) {
    AABB box;
    box.x0 = label.screen_x;
    box.y0 = label.screen_y;
    box.x1 = label.screen_x;
    box.y1 = label.screen_y;

    for (uint32_t i = 0; i < label.glyph_count && i < 64; ++i) {
        float gx1 = label.screen_x + label.glyphs[i].x + label.glyphs[i].w;
        float gy1 = label.screen_y + label.glyphs[i].y + label.glyphs[i].h;
        if (gx1 > box.x1) box.x1 = gx1;
        if (gy1 > box.y1) box.y1 = gy1;
    }

    // If no glyphs, give a default small bounding box
    if (label.glyph_count == 0) {
        box.x1 = box.x0 + 10.0f;
        box.y1 = box.y0 + 10.0f;
    }

    return box;
}

}  // anonymous namespace

core::Status label_layout(const Label* labels, size_t count,
                          Label* out_visible, size_t max_visible,
                          size_t* out_count) {
    if (!out_count) return core::Status::kInvalidArgument;
    *out_count = 0;
    if (count == 0) return core::Status::kOk;
    if (!labels || !out_visible) return core::Status::kInvalidArgument;

    // Sort labels by priority (higher priority first) using a simple index array
    // Since we can't allocate dynamically easily, limit to a reasonable max
    static constexpr size_t kMaxLabels = 4096;
    size_t effective_count = count;
    if (effective_count > kMaxLabels) effective_count = kMaxLabels;

    // Create index array sorted by descending priority (insertion sort for simplicity)
    uint32_t sorted[kMaxLabels];
    for (size_t i = 0; i < effective_count; ++i) {
        sorted[i] = static_cast<uint32_t>(i);
    }
    for (size_t i = 1; i < effective_count; ++i) {
        uint32_t key = sorted[i];
        float key_prio = labels[key].priority;
        size_t j = i;
        while (j > 0 && labels[sorted[j - 1]].priority < key_prio) {
            sorted[j] = sorted[j - 1];
            --j;
        }
        sorted[j] = key;
    }

    // Greedy placement: place labels in priority order, skip if overlapping
    AABB placed[4096];
    size_t placed_count = 0;

    for (size_t i = 0; i < effective_count && *out_count < max_visible; ++i) {
        const Label& lbl = labels[sorted[i]];
        AABB bounds = label_bounds(lbl);

        bool collides = false;
        for (size_t j = 0; j < placed_count; ++j) {
            if (aabb_overlaps(bounds, placed[j])) {
                collides = true;
                break;
            }
        }

        if (!collides) {
            out_visible[*out_count] = lbl;
            out_visible[*out_count].visible = true;
            placed[placed_count++] = bounds;
            (*out_count)++;
        }
    }

    return core::Status::kOk;
}

}  // namespace geo
}  // namespace aether
