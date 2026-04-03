// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// QualityOverlay.metal
// Aether3D
//
// Multi-factor quality heatmap overlay with always-visible red / yellow / green.
// C++ generates surface-aligned overlay vertices (32 bytes each).
// Each vertex carries a composite quality score [0,1] computed from:
//   - Geometric confidence (TSDF voxel weight)
//   - Angular diversity (24theta x 12phi directional bitmask)
//   - Training observation coverage
//   - Depth confidence (voxel confidence from DAv2/LiDAR)
//
// All quality bands stay visible during capture:
//   quality=0.0 → red
//   quality=0.5 → yellow
//   quality=0.85+ → green
//
// Surpasses Polycam/Scaniverse binary coverage with quality-graded
// multi-factor feedback. Color gradient provides actionable guidance:
// user sees exactly WHERE and HOW MUCH more scanning is needed.

#include <metal_stdlib>
using namespace metal;

// ═══════════════════════════════════════════════════════════════════════
// Types (must match C++ OverlayVertex layout: 32 bytes)
// ═══════════════════════════════════════════════════════════════════════

struct OverlayVertex {
    packed_float3 position;   // 12 bytes: world space center
    packed_float3 normal;     // 12 bytes: surface normal
    float size;               // 4 bytes: quad half-size (world meters)
    float quality;            // 4 bytes: composite quality [0,1]
};

// Reuse PointCloudUniforms (same buffer layout as Swift)
// IMPORTANT: Swift uses individual Float fields (not SIMD3<Float>) to guarantee
// byte-identical layout with Metal's packed_float3. Total: 112 bytes.
struct PointCloudUniforms {
    float4x4 viewProjection;
    float globalAlpha;
    float pointSizeScale;
    float _pad0;
    float _pad1;
    packed_float3 cameraPosition;   // Billboard: camera world pos
    float _pad2;
    packed_float3 cameraBack;       // Camera Z axis in world (points behind camera)
    float _pad3;
};

struct OverlayOut {
    float4 position [[position]];
    float pointSize [[point_size]];
    float quality;
};

// ═══════════════════════════════════════════════════════════════════════
// Vertex Shader — point-sprite rendering
// ═══════════════════════════════════════════════════════════════════════
// Each dense-map cell emits ONE circular point sprite instead of a
// surface-aligned quad. This keeps the feedback looking like sparse
// dense-map evidence instead of tile/mesh fragments.

vertex OverlayOut overlayVertex(
    uint vid [[vertex_id]],
    device const OverlayVertex* verts [[buffer(0)]],
    constant PointCloudUniforms& uniforms [[buffer(1)]])
{
    OverlayOut out;

    const OverlayVertex v = verts[vid];
    float3 center = float3(v.position);
    float3 normal = float3(v.normal);
    float nLen = length(normal);
    float3 faceNormal = nLen > 0.01 ? normal / nLen : -float3(uniforms.cameraBack);
    float3 worldPos = center + faceNormal * 0.002;

    out.position = uniforms.viewProjection * float4(worldPos, 1.0);
    float depth = max(0.001, out.position.w);
    float projectedSize = (v.size * uniforms.pointSizeScale * 420.0) / depth;
    out.pointSize = clamp(projectedSize, 4.0, 9.0);
    out.quality = v.quality;

    return out;
}

// ═══════════════════════════════════════════════════════════════════════
// Fragment Shader — Multi-Factor Quality Heatmap (Reverse Logic)
// ═══════════════════════════════════════════════════════════════════════
//
// Quality-to-Color mapping (5-stop gradient, perceptually uniform):
//   q ∈ [0.00, 0.20) → Red        (#E53935) — Critical: unscanned
//   q ∈ [0.20, 0.45) → Orange     (#FB8C00) — Poor: needs more angles
//   q ∈ [0.45, 0.65) → Yellow     (#FDD835) — Fair: partial coverage
//   q ∈ [0.65, 0.85) → Green      (#43A047) — Good: nearly complete
//   q ∈ [0.85, 1.00] → Bright Green — strong evidence
//
// Quality-to-Alpha:
// Keep red / yellow / green similarly visible so the user can compare
// evidence states directly on the surface.

fragment float4 overlayFragment(
    OverlayOut in [[stage_in]],
    float2 pointCoord [[point_coord]])
{
    // ── NaN/Inf defense (Risk D) ──
    // C++ composite_quality could be NaN if voxel data is corrupted
    // (e.g., division by zero in confidence computation).
    // saturate() maps NaN to 0 on Metal, but isnan() guard is belt-and-suspenders.
    float q = saturate(in.quality);
    if (isnan(in.quality) || isinf(in.quality)) {
        q = 0.0;  // Treat corrupted data as "worst quality" (bright red)
    }

    // ── 5-Stop Color Gradient (sRGB, Material Design inspired) ──
    // Smooth interpolation between stops for continuous feedback.
    //
    // Stop colors (linear-ish, tuned for AR overlay visibility):
    //   Red:    (0.90, 0.22, 0.21)  — #E53935
    //   Orange: (0.98, 0.55, 0.00)  — #FB8C00
    //   Yellow: (0.99, 0.85, 0.21)  — #FDD835
    //   Green:  (0.26, 0.63, 0.28)  — #43A047

    float3 red    = float3(0.90, 0.22, 0.21);
    float3 orange = float3(0.98, 0.55, 0.00);
    float3 yellow = float3(0.99, 0.85, 0.21);
    float3 green  = float3(0.26, 0.63, 0.28);

    // Piecewise smooth interpolation
    float3 color;
    if (q < 0.20) {
        // Pure red zone (critical)
        color = red;
    } else if (q < 0.45) {
        // Red → Orange transition
        float t = smoothstep(0.20, 0.45, q);
        color = mix(red, orange, t);
    } else if (q < 0.65) {
        // Orange → Yellow transition
        float t = smoothstep(0.45, 0.65, q);
        color = mix(orange, yellow, t);
    } else {
        // Yellow → Green transition
        float t = smoothstep(0.65, 0.85, q);
        color = mix(yellow, green, t);
    }

    float base_alpha = 0.42;

    // Circular point with soft falloff.
    float dist = length(pointCoord - 0.5);
    if (dist > 0.5) {
        discard_fragment();
    }
    float radial = smoothstep(0.5, 0.18, dist);
    float finalAlpha = base_alpha * radial;

    // Discard very transparent fragments (GPU early-out)
    if (finalAlpha < 0.004) {
        discard_fragment();
    }

    // Premultiplied alpha output
    return float4(color * finalAlpha, finalAlpha);
}
