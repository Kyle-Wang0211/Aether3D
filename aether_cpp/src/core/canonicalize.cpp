// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/core/canonicalize.h"

namespace aether {
namespace core {

void canonicalize_block(int32_t x, int32_t y, int32_t z,
                        int32_t& out_x, int32_t& out_y, int32_t& out_z) {
    out_x = x;
    out_y = y;
    out_z = z;
}

}  // namespace core
}  // namespace aether
