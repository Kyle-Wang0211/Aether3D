// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// QualityOverlay.metal
// Aether3D
//
// Multi-factor quality heatmap overlay with REVERSE LOGIC.
// C++ generates surface-aligned overlay vertices (32 bytes each).
// Each vertex carries a composite quality score [0,1] computed from:
//   - Geometric confidence (TSDF voxel weight)
//   - Angular diversity (24theta x 12phi directional bitmask)
//   - Training observation coverage
//   - Depth confidence (voxel confidence from DAv2/LiDAR)
//
// REVERSE LOGIC: overlay is VISIBLE on low-quality regions,
// TRANSPARENT on high-quality (S6+) regions.
//   quality=0.0 → bright red overlay (needs scanning)
//   quality=0.5 → orange/yellow (partial coverage)
//   quality=0.85+ → faint green → transparent (S6+ certified)
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
    float quality;
    float2 uv;    // Quad UV for soft edge
};

// ═══════════════════════════════════════════════════════════════════════
// Vertex Shader — SURFACE-NORMAL instanced quad rendering
// ═══════════════════════════════════════════════════════════════════════
// 4 vertices per instance (triangle strip: BL, BR, TL, TR → 2 triangles).
//
// Each TSDF block carries a surface normal. The quad is oriented to lie
// FLAT on the actual surface, using the normal to compute an orthonormal
// tangent frame. This makes tiles follow curved and sloped surfaces,
// forming a continuous mesh-like coverage overlay.
//
// Fallback: if the surface normal is zero (degenerate), falls back to
// axis-aligned cube-face selection based on camera direction.

vertex OverlayOut overlayVertex(
    uint vid [[vertex_id]],
    uint iid [[instance_id]],
    device const OverlayVertex* verts [[buffer(0)]],
    constant PointCloudUniforms& uniforms [[buffer(1)]])
{
    OverlayOut out;

    float3 center = float3(verts[iid].position);
    float halfSize = verts[iid].size;  // = block_world / 2
    float3 surfaceNormal = float3(verts[iid].normal);
    float3 camPos = float3(uniforms.cameraPosition);

    // ─── SURFACE-NORMAL MODE: orient quad along actual surface ───
    float3 faceNormal;
    float3 tangent;
    float3 bitangent;

    float nLen = length(surfaceNormal);
    if (nLen > 0.01) {
        // Valid surface normal — use it for orientation
        faceNormal = surfaceNormal / nLen;  // normalize

        // Ensure normal faces the camera (flip if pointing away)
        float3 viewDir = camPos - center;
        if (dot(faceNormal, viewDir) < 0.0) {
            faceNormal = -faceNormal;
        }

        // Compute tangent frame from surface normal via Gram-Schmidt.
        // Pick a reference vector not parallel to the normal.
        float3 ref = abs(faceNormal.y) < 0.95 ? float3(0, 1, 0) : float3(1, 0, 0);
        tangent   = normalize(cross(ref, faceNormal));
        bitangent = cross(faceNormal, tangent);
    } else {
        // Degenerate normal — fallback to axis-aligned cube face
        float3 viewDir = camPos - center;
        float3 absDir = abs(viewDir);

        if (absDir.x >= absDir.y && absDir.x >= absDir.z) {
            faceNormal = float3(sign(viewDir.x), 0, 0);
            tangent    = float3(0, 0, 1);
            bitangent  = float3(0, 1, 0);
        } else if (absDir.y >= absDir.x && absDir.y >= absDir.z) {
            faceNormal = float3(0, sign(viewDir.y), 0);
            tangent    = float3(1, 0, 0);
            bitangent  = float3(0, 0, 1);
        } else {
            faceNormal = float3(0, 0, sign(viewDir.z));
            tangent    = float3(1, 0, 0);
            bitangent  = float3(0, 1, 0);
        }
    }

    // Quad corners (triangle strip: BL, BR, TL, TR)
    float2 offsets[4] = {
        float2(-1, -1),
        float2( 1, -1),
        float2(-1,  1),
        float2( 1,  1),
    };
    float2 uv = offsets[vid % 4];

    // Position quad directly on the surface.
    // C++ passes surface_center (interpolated SDF zero-crossing average),
    // so 'center' IS already the actual surface position.
    // Only a tiny 2mm normal offset to prevent z-fighting with depth buffer.
    float3 worldPos = center
                    + faceNormal * 0.002
                    + tangent   * (uv.x * halfSize)
                    + bitangent * (uv.y * halfSize);

    out.position = uniforms.viewProjection * float4(worldPos, 1.0);
    out.quality = verts[iid].quality;
    out.uv = uv * 0.5 + 0.5;

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
//   q ∈ [0.85, 1.00] → Transparent — S6+ certified, overlay disappears
//
// Quality-to-Alpha (REVERSE logic — lower quality = MORE visible):
//   base_alpha = 0.50 × (1 - smoothstep(0.70, 0.95, q))
//   Ensures overlay fades gracefully as quality improves.
//   Lyapunov monotonic guarantee: quality only increases → overlay never
//   reappears once it has faded away.

fragment float4 overlayFragment(
    OverlayOut in [[stage_in]])
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

    // ── Reverse-Logic Alpha (lower quality = more visible) ──
    // Base alpha peaks at 0.55 for worst quality, fades to 0 at q≥0.85.
    //   Phase 1 (q < 0.65): strong overlay, alpha ≈ 0.55
    //   Phase 2 (q ∈ [0.65, 0.85]): graceful fade-out
    float fade = 1.0 - smoothstep(0.65, 0.85, q);
    float base_alpha = 0.55 * fade;

    // ── Grid-aligned tiles: no soft edge (cube-face fills entire block) ──
    // With cube-face rendering, adjacent tiles share exact edges.
    // Soft edges would create visible seams. Tiles fill 100% of block face.
    // A thin 1-pixel border at edges helps distinguish adjacent tiles:
    float2 d = abs(in.uv - 0.5) * 2.0;  // Distance from center [0,1]
    float edge = max(d.x, d.y);
    float border = edge > 0.95 ? 0.6 : 1.0;  // Subtle grid line at tile edges

    float finalAlpha = base_alpha * border;

    // ── S6+ PUNCH-THROUGH ──
    // For high-quality tiles, output alpha=0 to "erase" the red clear-color
    // background via the MIN alpha blend operation. This makes S6+ areas
    // transparent, revealing the camera feed below.
    // Without TSDF tiles: red background remains (unscanned).
    // With S6+ tiles: alpha=0 punches through → camera visible.
    if (q >= 0.85) {
        // Output zero alpha to erase the red background at this pixel
        return float4(0, 0, 0, 0);
    }

    // Discard very transparent fragments (GPU early-out)
    if (finalAlpha < 0.004) {
        discard_fragment();
    }

    // Premultiplied alpha output
    return float4(color * finalAlpha, finalAlpha);
}
