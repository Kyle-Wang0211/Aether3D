// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_TSDF_SDF_STORAGE_H
#define AETHER_TSDF_SDF_STORAGE_H

#include "aether/math/half.h"
#include <cstdint>

namespace aether {
namespace tsdf {

struct SDFStorage {
    uint16_t bits{0};

    SDFStorage() = default;
    explicit SDFStorage(float value) : bits(aether::math::float_to_half(value)) {}

    float to_float() const { return aether::math::half_to_float(bits); }
    static SDFStorage from_float(float value) { return SDFStorage(value); }
};

static_assert(sizeof(SDFStorage) == 2, "SDFStorage must stay 2 bytes");

}  // namespace tsdf
}  // namespace aether

#endif  // AETHER_TSDF_SDF_STORAGE_H
