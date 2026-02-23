// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_CPP_RENDER_ENVIRONMENT_LIGHT_H
#define AETHER_CPP_RENDER_ENVIRONMENT_LIGHT_H

#ifdef __cplusplus

#include "aether/innovation/core_types.h"

namespace aether {
namespace render {

struct EnvironmentLight {
    innovation::Float3 primary_direction{0.0f, -1.0f, 0.0f};
    float primary_intensity{1.0f};
    float sh_coeffs_rgb[27]{};
};

}  // namespace render
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_CPP_RENDER_ENVIRONMENT_LIGHT_H
