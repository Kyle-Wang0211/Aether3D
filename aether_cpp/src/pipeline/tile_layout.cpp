// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/pipeline/tile_layout.h"

namespace aether {
namespace pipeline {

TileLayout make_tile_layout(
    std::int32_t image_width,
    std::int32_t image_height,
    std::int32_t tile_size,
    std::int32_t overlap) noexcept {

    TileLayout layout;
    layout.tile_size = tile_size;
    layout.overlap = overlap;
    layout.stride = tile_size - overlap;
    layout.image_width = image_width;
    layout.image_height = image_height;

    // Caller-side precondition violations → empty layout (no crash on Apple/Android).
    // Plan G runtime always passes valid inputs (4K → 2K downsample step before this).
    if (tile_size <= overlap || image_width < tile_size || image_height < tile_size) {
        layout.nx = 0;
        layout.ny = 0;
        return layout;
    }

    const std::int32_t stride = layout.stride;

    // ceil((dim - tile_size) / stride) + 1, except when dim == tile_size (single tile).
    // Matches Swift makeLayout semantics bit-for-bit.
    if (image_width == tile_size) {
        layout.nx = 1;
    } else {
        const std::int32_t extra = image_width - tile_size;
        layout.nx = (extra + stride - 1) / stride + 1;
    }
    if (image_height == tile_size) {
        layout.ny = 1;
    } else {
        const std::int32_t extra = image_height - tile_size;
        layout.ny = (extra + stride - 1) / stride + 1;
    }

    layout.tiles.reserve(static_cast<std::size_t>(layout.nx) * layout.ny);
    for (std::int32_t row = 0; row < layout.ny; ++row) {
        for (std::int32_t col = 0; col < layout.nx; ++col) {
            TileRect t;
            // Last tile in each row/col pinned to image edge.
            t.x = (col == layout.nx - 1) ? (image_width - tile_size) : (col * stride);
            t.y = (row == layout.ny - 1) ? (image_height - tile_size) : (row * stride);
            t.width = tile_size;
            t.height = tile_size;
            t.row = row;
            t.col = col;
            layout.tiles.push_back(t);
        }
    }
    return layout;
}

}  // namespace pipeline
}  // namespace aether
