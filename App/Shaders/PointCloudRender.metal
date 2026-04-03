// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// PointCloudRender.metal
// Aether3D
//
// Dense point cloud rendering from Depth Anything V2 depth maps.
// Uses instanced point sprites for fast rendering (~0.5ms for 100K points).
//
// Pipeline:
//   1. pointCloudVertex  — world-space position → clip-space + point size
//   2. pointCloudFragment — circular point with alpha falloff
//   3. Blending          — additive alpha (sourceAlpha, oneMinusSourceAlpha)

#include <metal_stdlib>
using namespace metal;

// ═══════════════════════════════════════════════════════════════════════
// Types
// ═══════════════════════════════════════════════════════════════════════

struct PointCloudVertex {
    packed_float3 position;    // World space
    packed_float3 color;       // sRGB [0, 1]
    float size;                // Point size in pixels
    float alpha;               // Blend alpha
};

// Must match Swift PointCloudUniforms and QualityOverlay.metal (112 bytes)
struct PointCloudUniforms {
    float4x4 viewProjection;   // Combined view-projection matrix
    float globalAlpha;         // Point cloud fade (1.0 → 0.0 as 3DGS takes over)
    float pointSizeScale;      // Screen DPI scale factor
    float _pad0;
    float _pad1;
    packed_float3 cameraPosition;
    float _pad2;
    packed_float3 cameraBack;
    float _pad3;
};

struct PointCloudOut {
    float4 position [[position]];
    float3 color;
    float alpha;
    float pointSize [[point_size]];
};

// ═══════════════════════════════════════════════════════════════════════
// Vertex Shader
// ═══════════════════════════════════════════════════════════════════════

vertex PointCloudOut pointCloudVertex(
    uint vid [[vertex_id]],
    device const PointCloudVertex* vertices [[buffer(0)]],
    constant PointCloudUniforms& uniforms [[buffer(1)]])
{
    PointCloudVertex v = vertices[vid];

    PointCloudOut out;
    float4 worldPos = float4(v.position[0], v.position[1], v.position[2], 1.0);
    out.position = uniforms.viewProjection * worldPos;
    out.color = float3(v.color[0], v.color[1], v.color[2]);
    out.alpha = v.alpha * uniforms.globalAlpha;
    out.pointSize = v.size * uniforms.pointSizeScale;

    // Depth-based size attenuation
    float depth = out.position.w;
    if (depth > 0.1) {
        out.pointSize *= clamp(2.0 / depth, 0.5, 4.0);
    }

    return out;
}

// ═══════════════════════════════════════════════════════════════════════
// Fragment Shader
// ═══════════════════════════════════════════════════════════════════════

fragment float4 pointCloudFragment(
    PointCloudOut in [[stage_in]],
    float2 pointCoord [[point_coord]])
{
    // Circular point with smooth falloff
    float dist = length(pointCoord - 0.5);
    if (dist > 0.5) discard_fragment();

    // Soft edge (anti-aliased circle)
    float edge = smoothstep(0.5, 0.35, dist);
    float finalAlpha = in.alpha * edge;

    float3 srgbColor = clamp(in.color, 0.0, 1.0);
    if (!all(isfinite(srgbColor)) || max(srgbColor.r, max(srgbColor.g, srgbColor.b)) < 0.02) {
        srgbColor = float3(1.0, 0.82, 0.12);
    }

    // sRGB → linear for correct blending
    float3 linearColor = float3(
        (srgbColor.r <= 0.04045) ? srgbColor.r / 12.92 : pow((srgbColor.r + 0.055) / 1.055, 2.4),
        (srgbColor.g <= 0.04045) ? srgbColor.g / 12.92 : pow((srgbColor.g + 0.055) / 1.055, 2.4),
        (srgbColor.b <= 0.04045) ? srgbColor.b / 12.92 : pow((srgbColor.b + 0.055) / 1.055, 2.4)
    );

    return float4(linearColor * finalAlpha, finalAlpha);
}
