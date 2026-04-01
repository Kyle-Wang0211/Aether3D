// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// OIRSplatRender.metal
// Aether3D
//
// Order-Independent Rendering for 3D Gaussian Splatting.
// Based on Mobile-GS (ICLR 2026): eliminates GPU radix sort.
// Uses Weighted Blended OIT (McGuire & Bavoil 2013) for transparency.
//
// Two-pass pipeline:
//   Pass 1 (Accumulation): oirSplatVertex + oirSplatAccumFragment
//     - Renders all splats without sorting
//     - Writes to accumulation texture (float4) and revealage texture (float)
//   Pass 2 (Composite): oirCompositeVertex + oirCompositeFragment
//     - Full-screen quad combines accumulation with revealage
//     - Produces final composited image
//
// GPU budget: ~2.5ms vs ~5ms with sort (40% savings on A14)

#include <metal_stdlib>
using namespace metal;

// ═══════════════════════════════════════════════════════════════════════
// Shared Types (from GaussianSplatTypes.h compatible)
// ═══════════════════════════════════════════════════════════════════════

struct OIRPackedSplat {
    uint8_t rgba[4];           // sRGB color + linear opacity       [bytes 0-3]
    uint16_t center_xy[2];     // float16-encoded x, y              [bytes 4-7]
    uint16_t center_z_pad;     // float16-encoded z                 [bytes 8-9]
    uint8_t rot_uv[2];        // Octahedral rotation axis           [bytes 10-11]
    uint8_t scale[3];          // Log-encoded scale xyz              [bytes 12-14]
    uint8_t rot_angle;         // Rotation angle                     [byte  15]
};

struct OIRCameraUniforms {
    float4x4 viewMatrix;       // World → camera
    float4x4 projMatrix;       // Camera → clip
    float4x4 viewProjMatrix;   // Combined
    float2 focal;              // (fx, fy) in pixels
    float2 viewport;           // (width, height)
    float near_plane;
    float far_plane;
};

// ═══════════════════════════════════════════════════════════════════════
// Pass 1: Accumulation (no sorting needed)
// ═══════════════════════════════════════════════════════════════════════

struct OIRVertexOut {
    float4 position [[position]];
    float2 uv;                  // Quad UV [-1, 1]
    float3 color;               // Linear RGB
    float opacity;              // [0, 1]
    float sigma;                // Gaussian sigma in screen space
    float viewDepth;            // Normalized depth for weight
};

// Utility functions
inline float srgb_to_linear_oir(uint8_t srgb) {
    float s = float(srgb) / 255.0;
    return (s <= 0.04045) ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4);
}

inline float decode_half_oir(uint16_t h) {
    return float(as_type<half>(h));
}

inline float3 octahedral_decode_oir(uint8_t u_byte, uint8_t v_byte) {
    float ox = float(u_byte) / 255.0 * 2.0 - 1.0;
    float oy = float(v_byte) / 255.0 * 2.0 - 1.0;
    float az = 1.0 - abs(ox) - abs(oy);
    float ax, ay;
    if (az >= 0.0) { ax = ox; ay = oy; }
    else {
        ax = (1.0 - abs(oy)) * (ox >= 0.0 ? 1.0 : -1.0);
        ay = (1.0 - abs(ox)) * (oy >= 0.0 ? 1.0 : -1.0);
    }
    return normalize(float3(ax, ay, az));
}

inline float decode_log_scale_oir(uint8_t encoded) {
    float normalized = float(encoded) / 255.0;
    return exp(normalized * 16.0 - 8.0);
}

inline float4 decode_quaternion_oir(uint8_t uv0, uint8_t uv1, uint8_t angle_byte) {
    float3 axis = octahedral_decode_oir(uv0, uv1);
    float theta = float(angle_byte) * (M_PI_2_F / 255.0);
    float sin_t = sin(theta);
    return float4(cos(theta), axis.x * sin_t, axis.y * sin_t, axis.z * sin_t);
}

inline float3x3 quat_to_matrix_oir(float4 q) {
    float w = q.x, x = q.y, y = q.z, z = q.w;
    float xx = x*x, yy = y*y, zz = z*z;
    float xy = x*y, xz = x*z, yz = y*z;
    float wx = w*x, wy = w*y, wz = w*z;
    return float3x3(
        float3(1-2*(yy+zz), 2*(xy+wz), 2*(xz-wy)),
        float3(2*(xy-wz), 1-2*(xx+zz), 2*(yz+wx)),
        float3(2*(xz+wy), 2*(yz-wx), 1-2*(xx+yy)));
}

vertex OIRVertexOut oirSplatVertex(
    uint vid [[vertex_id]],
    uint iid [[instance_id]],
    device const OIRPackedSplat* splats [[buffer(0)]],
    constant OIRCameraUniforms& camera [[buffer(1)]])
{
    OIRVertexOut out;

    // Decode packed splat
    OIRPackedSplat s = splats[iid];

    float3 center = float3(
        decode_half_oir(s.center_xy[0]),
        decode_half_oir(s.center_xy[1]),
        decode_half_oir(s.center_z_pad));

    float3 scale = float3(
        decode_log_scale_oir(s.scale[0]),
        decode_log_scale_oir(s.scale[1]),
        decode_log_scale_oir(s.scale[2]));

    float4 quat = decode_quaternion_oir(s.rot_uv[0], s.rot_uv[1], s.rot_angle);
    float3x3 rot = quat_to_matrix_oir(quat);

    // Color & opacity
    out.color = float3(
        srgb_to_linear_oir(s.rgba[0]),
        srgb_to_linear_oir(s.rgba[1]),
        srgb_to_linear_oir(s.rgba[2]));
    out.opacity = float(s.rgba[3]) / 255.0;

    // Transform to camera space
    float4 viewPos = camera.viewMatrix * float4(center, 1.0);
    float viewZ = viewPos.z;

    // LOD culling: skip very distant or very small splats
    if (viewZ > camera.far_plane || viewZ < camera.near_plane) {
        out.position = float4(0, 0, -2, 1); // Behind near plane
        out.uv = float2(0);
        out.sigma = 0;
        out.viewDepth = 0;
        return out;
    }

    // EWA splatting: project 3D covariance to 2D
    float3x3 S = rot * float3x3(
        float3(scale.x, 0, 0),
        float3(0, scale.y, 0),
        float3(0, 0, scale.z));
    float3x3 cov3D = S * transpose(S);

    // Jacobian of perspective projection
    float invZ = 1.0 / viewZ;
    float invZ2 = invZ * invZ;
    float3x3 viewRot = float3x3(
        camera.viewMatrix[0].xyz,
        camera.viewMatrix[1].xyz,
        camera.viewMatrix[2].xyz);

    float3x3 W = viewRot;
    float2x3 J = float2x3(
        float3(camera.focal.x * invZ, 0, -camera.focal.x * viewPos.x * invZ2),
        float3(0, camera.focal.y * invZ, -camera.focal.y * viewPos.y * invZ2));

    float2x3 T = J;
    float3x3 Vrk = W * cov3D * transpose(W);
    float2x2 cov2D = float2x2(
        float2(dot(T[0], Vrk * float3(T[0])),
               dot(T[0], Vrk * float3(T[1]))),
        float2(dot(T[1], Vrk * float3(T[0])),
               dot(T[1], Vrk * float3(T[1]))));

    // Low-pass filter (Mip-Splatting inspired anti-aliasing)
    cov2D[0][0] += 0.3;
    cov2D[1][1] += 0.3;

    // Eigendecomposition for quad extent
    float a = cov2D[0][0], b = cov2D[0][1], d = cov2D[1][1];
    float det = a * d - b * b;
    float trace = a + d;
    float disc = max(0.1, trace * trace * 0.25 - det);
    float sqrt_disc = sqrt(disc);

    float lambda1 = max(trace * 0.5 + sqrt_disc, 0.01);
    float lambda2 = max(trace * 0.5 - sqrt_disc, 0.01);
    float radius = 3.0 * sqrt(max(lambda1, lambda2));

    // Screen-space size culling (< 1px → skip)
    if (radius < 0.5) {
        out.position = float4(0, 0, -2, 1);
        out.uv = float2(0);
        out.sigma = 0;
        out.viewDepth = 0;
        return out;
    }

    // Cap maximum screen radius
    radius = min(radius, 512.0);

    // Instanced quad vertices
    constexpr float2 quadVerts[4] = {
        float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1)
    };
    float2 offset = quadVerts[vid % 4] * radius;

    // Project center to screen
    float4 clipPos = camera.projMatrix * viewPos;
    float2 screenCenter = clipPos.xy / clipPos.w;

    // Offset in NDC
    float2 ndcOffset = offset * 2.0 / camera.viewport;
    out.position = float4(
        (screenCenter + ndcOffset) * clipPos.w,
        clipPos.z, clipPos.w);

    out.uv = quadVerts[vid % 4];
    out.sigma = sqrt(lambda1);
    out.viewDepth = clamp((viewZ - camera.near_plane) /
                          (camera.far_plane - camera.near_plane), 0.0, 1.0);

    return out;
}

// ═══════════════════════════════════════════════════════════════════════
// Pass 1 Fragment: Weighted Blended OIT accumulation
// ═══════════════════════════════════════════════════════════════════════
// Outputs:
//   color0 (RGBA16Float): premultiplied_color * weight, alpha * weight
//   color1 (R16Float):    revealage (product of 1-alpha)

struct OIRAccumOut {
    float4 accum [[color(0)]];    // Accumulation buffer
    float  reveal [[color(1)]];   // Revealage buffer
};

fragment OIRAccumOut oirSplatAccumFragment(
    OIRVertexOut in [[stage_in]])
{
    // Gaussian evaluation
    float d2 = dot(in.uv, in.uv);
    if (d2 > 1.0) discard_fragment();

    // Gaussian falloff: exp(-d^2 / (2 * sigma^2)), sigma normalized to UV space
    float gaussian = exp(-0.5 * d2 * 4.0);  // sigma ~= 0.5 in UV space
    float alpha = clamp(in.opacity * gaussian, 0.0, 0.99);

    if (alpha < 0.004) discard_fragment();  // Below visibility threshold

    // Depth-based weight (McGuire & Bavoil 2013)
    // Higher weight for closer, more opaque fragments
    float z = in.viewDepth;
    float weight = alpha * max(1e-2, 3e3 * pow(1.0 - z, 3.0));

    OIRAccumOut out;
    out.accum = float4(in.color * alpha * weight, alpha * weight);
    out.reveal = 1.0 - alpha;  // Will be multiplied (blendOp = multiply)

    return out;
}

// ═══════════════════════════════════════════════════════════════════════
// Pass 2: Full-screen composite — S6+ Quality-Gated Progressive Reveal
// ═══════════════════════════════════════════════════════════════════════
//
// Polycam/Scaniverse-style progressive reveal:
//   1. Screen starts BLACK (drawable cleared to 0,0,0,0 in overlay pass)
//   2. Non-S6+ surfaces show quality heatmap overlay (red → yellow → green)
//   3. S6+ certified surfaces (overlay faded to alpha≈0) reveal 3DGS colors
//   4. As quality improves, heatmap fades → full 3DGS reconstruction appears
//
// Quality gate uses overlay alpha from Pass 1.5 as a natural mask:
//   overlayAlpha > 0 → heatmap tile present → NON-S6+ → block splat rendering
//   overlayAlpha ≈ 0 → no overlay → S6+ certified → composite 3DGS splats

struct CompositeVertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex CompositeVertexOut oirCompositeVertex(uint vid [[vertex_id]]) {
    // Full-screen triangle (3 vertices cover entire screen)
    float2 pos[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
    float2 uv[3]  = { float2(0, 1),   float2(2, 1),  float2(0, -1) };

    CompositeVertexOut out;
    out.position = float4(pos[vid], 0, 1);
    out.uv = uv[vid];
    return out;
}

// Composite approach: Metal Framebuffer Fetch [[color(0)]]
// Apple TBDR GPUs can read existing tile memory for FREE (zero extra bandwidth).
// This is superior to:
//   (A) Alpha blending: shader can't see existing content, limited flexibility
//   (B) Blit-copy texture: requires expensive blit pass + extra memory
// Framebuffer fetch gives full compositing control at zero cost.
// NOTE: Pipeline blending MUST be disabled — we blend manually in shader.

fragment float4 oirCompositeFragment(
    CompositeVertexOut in [[stage_in]],
    float4 existingColor [[color(0)]],   // Framebuffer fetch: reads existing drawable (FREE on Apple TBDR)
    texture2d<float> accumTexture [[texture(0)]],
    texture2d<float> revealTexture [[texture(1)]])
{
    constexpr sampler s(mag_filter::nearest, min_filter::nearest);

    float4 accum = accumTexture.sample(s, in.uv);
    float reveal = revealTexture.sample(s, in.uv).r;

    // No splat coverage at this pixel — preserve existing content (overlay or black)
    if (accum.a < 1e-5) {
        return existingColor;
    }

    // ── S6+ Quality Gate (Progressive Reveal) ──────────────────────────
    //
    // existingColor comes from the quality overlay pass (Pass 1.5):
    //   overlayAlpha ≥ 0.10 → heatmap tile present → non-S6+ → keep overlay
    //   overlayAlpha ≈ 0.05 → S6+ boundary → smooth half-blend transition
    //   overlayAlpha = 0.00 → no overlay → S6+ certified → full 3DGS
    //
    // The smooth transition (smoothstep) prevents hard edges at S6+ boundary.
    // Overlay alpha values from QualityOverlay.metal:
    //   q < 0.70:  alpha ≈ 0.55 (strong overlay)     → qualityGate = 0
    //   q = 0.80:  alpha ≈ 0.33 (fading overlay)     → qualityGate = 0
    //   q = 0.89:  alpha ≈ 0.15 (minimum floor)      → qualityGate = 0
    //   q = 0.92:  alpha ≈ 0.02 (nearly transparent)  → qualityGate ≈ 0.8
    //   q ≥ 0.95:  alpha = 0.00 (S6+ certified)      → qualityGate = 1.0
    float qualityGate = 1.0 - smoothstep(0.0, 0.10, existingColor.a);

    // Reconstruct average color from weighted sums (McGuire & Bavoil 2013)
    float3 avgColor = accum.rgb / max(accum.a, 1e-5);

    // Coverage = how much of this pixel is covered by splats
    float coverage = clamp(1.0 - reveal, 0.0, 1.0);

    // Gate splat coverage by S6+ certification
    // Non-S6+: gatedCoverage ≈ 0 → pixel shows heatmap overlay
    // S6+:     gatedCoverage = coverage → pixel shows 3DGS reconstruction
    float gatedCoverage = coverage * qualityGate;

    // Composite: blend 3DGS over existing content (black background or fading overlay)
    float3 composited = mix(existingColor.rgb, avgColor, gatedCoverage);
    float  finalAlpha = existingColor.a * (1.0 - gatedCoverage) + gatedCoverage;

    return float4(composited, finalAlpha);
}
