// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/render/shader_source.h"

#include <algorithm>
#include <cmath>

namespace aether {
namespace render {

namespace {

constexpr std::uint32_t kShaderSourceVersion = 4u;

inline float clamp01(float v) {
    return std::max(0.0f, std::min(1.0f, v));
}

constexpr const char* kBRDFMSL = R"(
// Aether3D BRDF v2
inline half NDF_GGX(half NdotH, half roughness) {
    half a = roughness * roughness;
    half a2 = a * a;
    half denom = NdotH * NdotH * (a2 - 1.0h) + 1.0h;
    return a2 / (3.14159h * denom * denom);
}
inline half GeometrySmith(half NdotV, half NdotL, half roughness) {
    half r = roughness + 1.0h;
    half k = (r * r) / 8.0h;
    half ggxV = NdotV / (NdotV * (1.0h - k) + k);
    half ggxL = NdotL / (NdotL * (1.0h - k) + k);
    return ggxV * ggxL;
}
inline half3 FresnelSchlick(half cosTheta, half3 F0) {
    half t = 1.0h - cosTheta;
    half t5 = t * t * t * t * t;
    return F0 + (1.0h - F0) * t5;
}
)";

constexpr const char* kBRDFGLSL = R"(
// Aether3D BRDF v2
float NDF_GGX(float NdotH, float roughness) {
    float a = roughness * roughness;
    float a2 = a * a;
    float denom = NdotH * NdotH * (a2 - 1.0) + 1.0;
    return a2 / (3.14159 * denom * denom);
}
float GeometrySmith(float NdotV, float NdotL, float roughness) {
    float r = roughness + 1.0;
    float k = (r * r) / 8.0;
    float ggxV = NdotV / (NdotV * (1.0 - k) + k);
    float ggxL = NdotL / (NdotL * (1.0 - k) + k);
    return ggxV * ggxL;
}
vec3 FresnelSchlick(float cosTheta, vec3 F0) {
    float t = 1.0 - cosTheta;
    float t5 = t * t * t * t * t;
    return F0 + (1.0 - F0) * t5;
}
)";

constexpr const char* kBRDFLUTMSL = R"(
inline half2 sampleSplitSumLUT(texture2d<half> brdfLUT, sampler lutSampler, half NdotV, half roughness) {
    const half2 uv = half2(clamp(NdotV, 0.0h, 1.0h), clamp(roughness, 0.0h, 1.0h));
    return brdfLUT.sample(lutSampler, uv).rg;
}
)";

constexpr const char* kBRDFLUTGLSL = R"(
vec2 sampleSplitSumLUT(sampler2D brdfLUT, float NdotV, float roughness) {
    vec2 uv = vec2(clamp(NdotV, 0.0, 1.0), clamp(roughness, 0.0, 1.0));
    return texture(brdfLUT, uv).rg;
}
)";

constexpr const char* kBRDFPolyMSL = R"(
inline half2 envBRDFPolynomial(half NdotV, half roughness) {
    half4 c0 = half4(-1.0h, -0.0275h, -0.572h, 0.022h);
    half4 c1 = half4(1.0h, 0.0425h, 1.04h, -0.04h);
    half4 r = roughness * c0 + c1;
    half a004 = min(r.x * r.x, exp2(-9.28h * NdotV)) * r.x + r.y;
    half2 ab = half2(-1.04h, 1.04h) * a004 + r.zw;
    return ab;
}
)";

constexpr const char* kBRDFPolyGLSL = R"(
vec2 envBRDFPolynomial(float NdotV, float roughness) {
    vec4 c0 = vec4(-1.0, -0.0275, -0.572, 0.022);
    vec4 c1 = vec4(1.0, 0.0425, 1.04, -0.04);
    vec4 r = roughness * c0 + c1;
    float a004 = min(r.x * r.x, exp2(-9.28 * NdotV)) * r.x + r.y;
    vec2 ab = vec2(-1.04, 1.04) * a004 + r.zw;
    return ab;
}
)";

constexpr const char* kSHMSL = R"(
// Aether3D SH Eval v2
inline half3 evalSH9(half3 n, const device half* c) {
    half x=n.x, y=n.y, z=n.z;
    return c[0] + c[1]*y + c[2]*z + c[3]*x + c[4]*(x*y) + c[5]*(y*z) + c[6]*(3.0h*z*z-1.0h)
         + c[7]*(x*z) + c[8]*(x*x-y*y);
}
)";

constexpr const char* kSHGLSL = R"(
// Aether3D SH Eval v2
vec3 evalSH9(vec3 n, vec3 c[9]) {
    float x=n.x, y=n.y, z=n.z;
    return c[0] + c[1]*y + c[2]*z + c[3]*x + c[4]*(x*y) + c[5]*(y*z) + c[6]*(3.0*z*z-1.0)
         + c[7]*(x*z) + c[8]*(x*x-y*y);
}
)";

constexpr const char* kFlipMSL = R"(
inline float3 rotateByQuat(float3 v, float4 q) {
    float3 u = q.xyz;
    float s = q.w;
    return v + 2.0 * cross(u, cross(u, v) + s * v);
}
)";

constexpr const char* kFlipGLSL = R"(
vec3 rotateByQuat(vec3 v, vec4 q) {
    vec3 u = q.xyz;
    float s = q.w;
    return v + 2.0 * cross(u, cross(u, v) + s * v);
}
)";

}  // namespace

const char* brdf_shader_source(ShaderLanguage lang) {
    switch (lang) {
        case ShaderLanguage::kMSL:
            return kBRDFMSL;
        case ShaderLanguage::kGLSL_ES300:
        case ShaderLanguage::kGLSL_Vulkan:
        case ShaderLanguage::kWGSL:  // TODO Phase 6+: translate BRDF utility shaders to WGSL
            return kBRDFGLSL;
    }
    return kBRDFGLSL;
}

const char* brdf_lut_source(ShaderLanguage lang) {
    switch (lang) {
        case ShaderLanguage::kMSL:
            return kBRDFLUTMSL;
        case ShaderLanguage::kGLSL_ES300:
        case ShaderLanguage::kGLSL_Vulkan:
        case ShaderLanguage::kWGSL:  // TODO Phase 6+: translate BRDF utility shaders to WGSL
            return kBRDFLUTGLSL;
    }
    return kBRDFLUTGLSL;
}

const char* brdf_polynomial_source(ShaderLanguage lang) {
    switch (lang) {
        case ShaderLanguage::kMSL:
            return kBRDFPolyMSL;
        case ShaderLanguage::kGLSL_ES300:
        case ShaderLanguage::kGLSL_Vulkan:
        case ShaderLanguage::kWGSL:  // TODO Phase 6+: translate BRDF utility shaders to WGSL
            return kBRDFPolyGLSL;
    }
    return kBRDFPolyGLSL;
}

const char* sh_evaluation_source(ShaderLanguage lang) {
    switch (lang) {
        case ShaderLanguage::kMSL:
            return kSHMSL;
        case ShaderLanguage::kGLSL_ES300:
        case ShaderLanguage::kGLSL_Vulkan:
        case ShaderLanguage::kWGSL:  // TODO Phase 6+: translate SH evaluation to WGSL
            return kSHGLSL;
    }
    return kSHGLSL;
}

const char* flip_rotation_source(ShaderLanguage lang) {
    switch (lang) {
        case ShaderLanguage::kMSL:
            return kFlipMSL;
        case ShaderLanguage::kGLSL_ES300:
        case ShaderLanguage::kGLSL_Vulkan:
        case ShaderLanguage::kWGSL:  // TODO Phase 6+: translate flip-rotation helper to WGSL
            return kFlipGLSL;
    }
    return kFlipGLSL;
}

BRDFApproximationChoice choose_brdf_approximation(const BRDFApproximationCaps& caps) {
    BRDFApproximationChoice choice{};
    const std::uint32_t resolution = std::max<std::uint32_t>(64u, caps.lut_resolution);
    const bool mobile = caps.platform != BRDFTargetPlatform::kDesktop;

    if (caps.supports_lut_texture && !caps.prefer_low_bandwidth && !mobile) {
        choice.path = BRDFApproximationPath::kLUT;
        choice.lut_resolution = resolution;
        choice.estimated_lut_bytes = split_sum_lut_bytes(resolution);
        choice.valid = true;
        return choice;
    }

    choice.path = BRDFApproximationPath::kPolynomial;
    choice.lut_resolution = resolution;
    choice.estimated_lut_bytes = split_sum_lut_bytes(resolution);
    choice.valid = true;
    return choice;
}

std::size_t split_sum_lut_bytes(std::uint32_t resolution) {
    const std::size_t r = static_cast<std::size_t>(resolution);
    // RGBA16F texture budget (8 bytes per texel), matching mobile stop-loss accounting.
    return r * r * 8u;
}

void env_brdf_polynomial(float ndotv, float roughness, float* out_a, float* out_b) {
    if (out_a == nullptr || out_b == nullptr) {
        return;
    }

    const float x = clamp01(ndotv);
    const float y = clamp01(roughness);
    const float c0x = -1.0f;
    const float c0y = -0.0275f;
    const float c0z = -0.572f;
    const float c0w = 0.022f;
    const float c1x = 1.0f;
    const float c1y = 0.0425f;
    const float c1z = 1.04f;
    const float c1w = -0.04f;

    const float rx = y * c0x + c1x;
    const float ry = y * c0y + c1y;
    const float rz = y * c0z + c1z;
    const float rw = y * c0w + c1w;
    const float a004 = std::min(rx * rx, std::exp2(-9.28f * x)) * rx + ry;
    *out_a = -1.04f * a004 + rz;
    *out_b = 1.04f * a004 + rw;
}

core::Status generate_split_sum_lut(std::uint32_t resolution, float* out_rg, std::size_t out_count) {
    if (resolution == 0u || out_rg == nullptr) {
        return core::Status::kInvalidArgument;
    }
    const std::size_t r = static_cast<std::size_t>(resolution);
    const std::size_t needed = r * r * 2u;
    if (out_count < needed) {
        return core::Status::kOutOfRange;
    }

    for (std::size_t y = 0u; y < r; ++y) {
        const float roughness = (r <= 1u) ? 0.0f : static_cast<float>(y) / static_cast<float>(r - 1u);
        for (std::size_t x = 0u; x < r; ++x) {
            const float ndotv = (r <= 1u) ? 0.0f : static_cast<float>(x) / static_cast<float>(r - 1u);
            float a = 0.0f;
            float b = 0.0f;
            env_brdf_polynomial(ndotv, roughness, &a, &b);
            const std::size_t idx = (y * r + x) * 2u;
            out_rg[idx + 0u] = a;
            out_rg[idx + 1u] = b;
        }
    }
    return core::Status::kOk;
}

std::uint32_t shader_source_version() {
    return kShaderSourceVersion;
}

}  // namespace render
}  // namespace aether
