// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_CPP_RENDER_SHADER_SOURCE_H
#define AETHER_CPP_RENDER_SHADER_SOURCE_H

#ifdef __cplusplus

#include "aether/core/status.h"

#include <cstddef>
#include <cstdint>

namespace aether {
namespace render {

enum class ShaderLanguage : std::uint8_t {
    kMSL = 0u,
    kGLSL_ES300 = 1u,
    kGLSL_Vulkan = 2u,
    // Phase 6.1: WGSL added as the cross-platform shader language for
    // the Dawn-backed renderer. Per the architectural commitment locked
    // in PHASE_BACKLOG.md "Phase 6 prerequisite", WGSL is the single
    // source of truth for all new shader code (gaussian_splat_*.wgsl,
    // gaussian_training_*.wgsl). MSL retained only as a legacy reference
    // path under App/GaussianSplatting/Shaders/ — no new MSL shaders.
    kWGSL = 3u,
};

enum class BRDFApproximationPath : std::uint8_t {
    kLUT = 0u,
    kPolynomial = 1u,
};

enum class BRDFTargetPlatform : std::uint8_t {
    kIOS = 0u,
    kAndroid = 1u,
    kHarmonyOS = 2u,
    kDesktop = 3u,
};

struct BRDFApproximationCaps {
    BRDFTargetPlatform platform{BRDFTargetPlatform::kDesktop};
    bool supports_lut_texture{true};
    bool prefer_low_bandwidth{false};
    std::uint32_t lut_resolution{256u};
};

struct BRDFApproximationChoice {
    BRDFApproximationPath path{BRDFApproximationPath::kPolynomial};
    std::uint32_t lut_resolution{0u};
    std::size_t estimated_lut_bytes{0u};
    bool valid{false};
};

const char* brdf_shader_source(ShaderLanguage lang);
const char* brdf_lut_source(ShaderLanguage lang);
const char* brdf_polynomial_source(ShaderLanguage lang);
const char* sh_evaluation_source(ShaderLanguage lang);
const char* flip_rotation_source(ShaderLanguage lang);
BRDFApproximationChoice choose_brdf_approximation(const BRDFApproximationCaps& caps);
std::size_t split_sum_lut_bytes(std::uint32_t resolution);
void env_brdf_polynomial(float ndotv, float roughness, float* out_a, float* out_b);
core::Status generate_split_sum_lut(std::uint32_t resolution, float* out_rg, std::size_t out_count);
std::uint32_t shader_source_version();

}  // namespace render
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_CPP_RENDER_SHADER_SOURCE_H
