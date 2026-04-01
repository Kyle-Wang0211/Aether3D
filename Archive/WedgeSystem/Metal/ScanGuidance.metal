//
// ScanGuidance.metal
// Aether3D
//
// PR#7 Scan Guidance UI — Metal Shaders
// Phase 2: Implements wedge fill + border stroke passes only
//

#include <metal_stdlib>
using namespace metal;

// ─── Structs ───

struct WedgeVertex {
    float3 position     [[attribute(0)]];
    float3 normal       [[attribute(1)]];
    float  metallic     [[attribute(2)]];
    float  roughness    [[attribute(3)]];
    float  display      [[attribute(4)]];
    float  thickness    [[attribute(5)]];
    uint   triangleId   [[attribute(6)]];
    uint   edgeMask     [[attribute(7)]];  // v4: 3 bits — bit0=v0v1, bit1=v1v2, bit2=v2v0
};

struct ScanGuidanceUniforms {
    float4x4 viewProjectionMatrix;
    float4x4 modelMatrix;
    float3   cameraPosition;
    float3   primaryLightDirection;
    float    primaryLightIntensity;
    float3   shCoeffs[9];
    uint     qualityTier;
    float    time;
    float    borderGamma;
};

// v7.0.1 FIX: Use float3 instead of uint8_t×3 to avoid Metal alignment issues
// Use packed_float3 to avoid 16-byte alignment padding (88 bytes total)
struct PerTriangleData {
    float  flipAngle;
    float  rippleAmplitude;
    float  borderWidth;
    float  borderAlpha;
    float  rippleMinAmplitude;
    float  rippleBoostScale;
    float  fillDitherStart;
    float  fillDitherEnd;
    float  borderMinWidth;
    float  borderMinAlpha;
    float  borderAAFactor;
    float  borderFwidthEpsilon;
    float  borderDiscardAlpha;
    packed_float3 flipAxisOrigin;
    packed_float3 flipAxisDirection;
    packed_float3 grayscaleColor;  // v7.0.1: was uint8_t×3, now float3 [0,1]
};

// ─── PBR Helper Functions ───

// fp16-safe GGX NDF (Filament approach: cross product avoids catastrophic cancellation)
// Reference: Google Filament v1.69 (2025), Romain Guy fp16 GGX gist
inline half NDF_GGX_Safe(half3 N, half3 H, half roughness) {
    half a = roughness * roughness;
    half a2 = a * a;
    // Use cross product: |N×H|² = 1 - (N·H)² without cancellation error in fp16
    float3 NxH = cross(float3(N), float3(H));
    half OneMinusNdotHSqr = half(dot(NxH, NxH));
    half d = OneMinusNdotHSqr * (a2 - 1.0h) + 1.00001h;  // +epsilon prevents d=0
    return a2 / (M_PI_H * d * d);
}

// Kelemen-Szirmay-Kalos Visibility (saves ~4 ALU vs full Smith-GGX)
// Reference: Filament PBR, optimized for mobile
inline half VisibilityKelemen(half LdotH, half roughness) {
    return 1.0h / (4.0h * max(0.1h, LdotH * LdotH) * (roughness + 0.5h));
}

// Legacy Smith-GGX kept for reference/fallback
inline half GeometrySchlickGGX(half NdotV, half roughness) {
    half r = roughness + 1.0h;
    half k = (r * r) / 8.0h;
    return NdotV / (NdotV * (1.0h - k) + k);
}

inline half GeometrySmith(half NdotV, half NdotL, half roughness) {
    return GeometrySchlickGGX(NdotV, roughness) * GeometrySchlickGGX(NdotL, roughness);
}

// Schlick Fresnel Approximation
inline half3 FresnelSchlick(half cosTheta, half3 F0) {
    half t = 1.0h - cosTheta;
    half t2 = t * t;
    half t5 = t2 * t2 * t;
    return F0 + (1.0h - F0) * t5;
}

// Evaluate L2 Spherical Harmonics (9 coefficients)
inline half3 evaluateSH(float3 n, constant float3 *shCoeffs) {
    // L0 band (ambient)
    half3 result = half3(shCoeffs[0]) * 0.282095h;
    
    // L1 band (directional)
    result += half3(shCoeffs[1]) * 0.488603h * half(n.y);
    result += half3(shCoeffs[2]) * 0.488603h * half(n.z);
    result += half3(shCoeffs[3]) * 0.488603h * half(n.x);
    
    // L2 band (detailed directional)
    result += half3(shCoeffs[4]) * 1.092548h * half(n.x * n.y);
    result += half3(shCoeffs[5]) * 1.092548h * half(n.y * n.z);
    result += half3(shCoeffs[6]) * 0.315392h * half(3.0 * n.z * n.z - 1.0);
    result += half3(shCoeffs[7]) * 1.092548h * half(n.x * n.z);
    result += half3(shCoeffs[8]) * 0.546274h * half(n.x * n.x - n.y * n.y);
    
    return max(result, 0.0h);
}

// ─── Oklab Perceptual Color Space (Layer 7.2) ───
// Reference: Björn Ottosson 2020, "A perceptual color space for image processing"
// Oklab provides perceptually uniform lightness, enabling smooth gradients
// that look visually even across the entire display [0,1] range.

/// Convert Oklab (L, a, b) → linear sRGB
/// Uses the exact matrix from Ottosson's paper (LMS→linear sRGB).
inline half3 oklabToLinearSRGB(half L, half a, half b) {
    // Oklab → LMS (cube root domain)
    half l_ = L + 0.3963377774h * a + 0.2158037573h * b;
    half m_ = L - 0.1055613458h * a - 0.0638541728h * b;
    half s_ = L - 0.0894841775h * a - 1.2914855480h * b;

    // Undo cube root
    half l = l_ * l_ * l_;
    half m = m_ * m_ * m_;
    half s = s_ * s_ * s_;

    // LMS → linear sRGB
    half3 rgb;
    rgb.r = +4.0767416621h * l - 3.3077115913h * m + 0.2309699292h * s;
    rgb.g = -1.2684380046h * l + 2.6097574011h * m - 0.3413193965h * s;
    rgb.b = -0.0041960863h * l - 0.7034186147h * m + 1.7076147010h * s;

    return clamp(rgb, 0.0h, 1.0h);
}

/// Apply IEC 61966-2-1 sRGB OETF (linear → sRGB gamma).
/// Required because render target uses .bgra8Unorm (no hardware conversion).
/// The precise piecewise function avoids banding artifacts in dark regions.
inline half3 linearToSRGB(half3 linear) {
    // Per-channel piecewise sRGB OETF:
    //   c <= 0.0031308: sRGB = c × 12.92
    //   c >  0.0031308: sRGB = 1.055 × c^(1/2.4) - 0.055
    half3 srgb;
    srgb.r = linear.r <= 0.0031308h ? linear.r * 12.92h : 1.055h * pow(linear.r, 1.0h / 2.4h) - 0.055h;
    srgb.g = linear.g <= 0.0031308h ? linear.g * 12.92h : 1.055h * pow(linear.g, 1.0h / 2.4h) - 0.055h;
    srgb.b = linear.b <= 0.0031308h ? linear.b * 12.92h : 1.055h * pow(linear.b, 1.0h / 2.4h) - 0.055h;
    return clamp(srgb, 0.0h, 1.0h);
}

/// Map display evidence [0,1] → Oklab perceptual color
/// Cold (subtle blue) at low evidence → warm neutral white at high evidence.
/// Chroma is kept very low to stay close to grayscale while adding depth.
inline half3 evidenceToOklabColor(half display) {
    // Lightness: 0.05 (near-black) → 0.97 (near-white)
    // S0 triangles appear nearly pure black with white borders
    half L = mix(0.05h, 0.97h, display);

    // Chroma via a,b: small cool offset at low display, fading to neutral
    // a (green-red): slight warm shift at high evidence
    half a_ok = mix(-0.005h, 0.003h, display);
    // b (blue-yellow): cool (negative) at low → neutral at high
    half b_ok = mix(-0.015h, 0.002h, display);

    return oklabToLinearSRGB(L, a_ok, b_ok);
}

// Quaternion from axis-angle
inline float4 quatFromAxisAngle(float3 axis, float angle) {
    float halfAngle = angle * 0.5;
    float s = sin(halfAngle);
    float c = cos(halfAngle);
    return float4(axis * s, c);
}

// Rotate vector by quaternion
inline float3 rotateByQuat(float3 v, float4 q) {
    float3 u = q.xyz;
    float w = q.w;
    return 2.0 * dot(u, v) * u
         + (w * w - dot(u, u)) * v
         + 2.0 * w * cross(u, v);
}

// ─── Vertex/Fragment Shaders ───

struct VertexOut {
    float4 position [[position]];
    float3 worldNormal;
    float3 worldPosition;
    float  metallic;
    float  roughness;
    float  display;
    float  rippleAmplitude;
    float3 grayscaleColor;
    float  borderWidth;
    float  borderAlpha;
    float  rippleMinAmplitude;
    float  rippleBoostScale;
    float  fillDitherStart;
    float  fillDitherEnd;
    float  borderMinWidth;
    float  borderMinAlpha;
    float  borderAAFactor;
    float  borderFwidthEpsilon;
    float  borderDiscardAlpha;
    uint   edgeMask;  // v4: per-triangle edge mask for selective border rendering
};

// ─── Pass 1: Wedge Fill ───

vertex VertexOut wedgeFillVertex(
    WedgeVertex in [[stage_in]],
    constant ScanGuidanceUniforms &uniforms [[buffer(1)]],
    constant PerTriangleData *triData [[buffer(2)]],
    uint vid [[vertex_id]]
) {
    VertexOut out;
    uint triId = in.triangleId;
    
    float3 pos = in.position;
    float3 norm = in.normal;
    
    // ── Step 1: Flip Rotation ──
    float angle = triData[triId].flipAngle;
    if (angle != 0.0) {
        float3 axisOrigin = triData[triId].flipAxisOrigin;
        float3 axisDir = triData[triId].flipAxisDirection;
        
        // Translate to axis-local space, rotate, translate back
        float3 localPos = pos - axisOrigin;
        float4 q = quatFromAxisAngle(axisDir, angle);
        localPos = rotateByQuat(localPos, q);
        pos = localPos + axisOrigin;
        
        // Rotate normal too
        norm = rotateByQuat(norm, q);
    }
    
    // ── Step 2: Ripple Displacement ──
    float ripple = triData[triId].rippleAmplitude;
    if (ripple != 0.0) {
        float displacement = ripple * in.thickness * 0.3;  // rippleThicknessMultiplier
        pos += norm * displacement;
    }
    
    // ── Step 3: Transform to clip space ──
    float4 worldPos = uniforms.modelMatrix * float4(pos, 1.0);
    out.position = uniforms.viewProjectionMatrix * worldPos;
    out.worldPosition = worldPos.xyz;
    out.worldNormal = normalize((uniforms.modelMatrix * float4(norm, 0.0)).xyz);
    
    // ── Step 4: Pass-through attributes ──
    out.metallic = in.metallic;
    out.roughness = in.roughness;
    out.display = in.display;
    out.rippleAmplitude = ripple;
    out.grayscaleColor = triData[triId].grayscaleColor;
    out.borderWidth = triData[triId].borderWidth;
    out.borderAlpha = triData[triId].borderAlpha;
    out.rippleMinAmplitude = triData[triId].rippleMinAmplitude;
    out.rippleBoostScale = triData[triId].rippleBoostScale;
    out.fillDitherStart = triData[triId].fillDitherStart;
    out.fillDitherEnd = triData[triId].fillDitherEnd;
    out.borderMinWidth = triData[triId].borderMinWidth;
    out.borderMinAlpha = triData[triId].borderMinAlpha;
    out.borderAAFactor = triData[triId].borderAAFactor;
    out.borderFwidthEpsilon = triData[triId].borderFwidthEpsilon;
    out.borderDiscardAlpha = triData[triId].borderDiscardAlpha;
    out.edgeMask = in.edgeMask;

    return out;
}

fragment half4 wedgeFillFragment(
    VertexOut in [[stage_in]],
    constant ScanGuidanceUniforms &uniforms [[buffer(1)]]
) {
    (void)uniforms;
    // Black/white capture style: rely on grayscale evidence directly and
    // avoid extra lighting tint so S0 stays visually black.
    half3 color = clamp(half3(in.grayscaleColor), 0.0h, 1.0h);

    // ── Ripple highlight ──
    if (in.rippleAmplitude > in.rippleMinAmplitude) {
        half rippleBoost = half(in.rippleAmplitude) * half(max(in.rippleBoostScale, 0.0));
        color = min(color + half3(rippleBoost), half3(1.0h));
    }

    // ── Alpha: S5 fade with stochastic blue-noise dithering ──
    half alpha = 1.0h;
    float fadeStart = in.fillDitherStart;
    float fadeEnd = in.fillDitherEnd;
    if (in.display > fadeStart && fadeEnd > fadeStart) {
        // Progressive fade controlled by core output thresholds.
        half fade = half(clamp((in.display - fadeStart) / (fadeEnd - fadeStart), 0.0, 1.0));
        // Position-based hash for blue-noise-like dithering (TAA-friendly)
        // Layer 3.8: Added temporal seed (uniforms.time * 60.0) so the dithering
        // pattern varies per frame, preventing persistent stipple artifacts.
        // Will upgrade to STBN 128×128×64 texture in future pass.
        float2 screenPos = in.position.xy + uniforms.time * 60.0;
        half noise = half(fract(sin(dot(screenPos, float2(12.9898, 78.233))) * 43758.5453));
        // Stochastic transparency: converges under temporal accumulation
        alpha = (fade < noise) ? 1.0h : 0.0h;
    }

    // sRGB gamma encoding — pixel format is .bgra8Unorm (no hardware conversion).
    // Apply OETF BEFORE pre-multiplied alpha to avoid double-gamma on blended edges.
    color = linearToSRGB(color);

    // Pre-multiplied alpha for AR compositing
    color *= alpha;

    return half4(color, alpha);
}

// ─── Pass 2: Border Stroke ───

// SDF helper functions
inline float sdTriangle2D(float2 p, float2 a, float2 b, float2 c) {
    float2 ba = b - a, cb = c - b, ac = a - c;
    float2 pa = p - a, pb = p - b, pc = p - c;
    float2 nor = float2(ba.y, -ba.x);
    float s = sign(dot(nor, pa));
    // NaN guard: degenerate triangles (coincident vertices) produce dot(ba,ba)=0
    float2 d1 = pa - ba * clamp(dot(pa, ba) / max(dot(ba, ba), 1e-10), 0.0, 1.0);
    float2 d2 = pb - cb * clamp(dot(pb, cb) / max(dot(cb, cb), 1e-10), 0.0, 1.0);
    float2 d3 = pc - ac * clamp(dot(pc, ac) / max(dot(ac, ac), 1e-10), 0.0, 1.0);
    float md = min(min(dot(d1,d1), dot(d2,d2)), dot(d3,d3));
    return sqrt(md) * s;
}

inline float sdRoundedTriangle(float2 p, float2 a, float2 b, float2 c, float r) {
    return sdTriangle2D(p, a, b, c) - r;
}

fragment half4 borderStrokeFragment(
    VertexOut in [[stage_in]],
    float3 bary [[barycentric_coord]],
    constant ScanGuidanceUniforms &uniforms [[buffer(1)]]
) {
    (void)uniforms;

    // Border width and alpha come from core capture style runtime.
    float borderWidth = max(in.borderWidth, 0.0);
    half borderAlpha = clamp(half(in.borderAlpha), 0.0h, 1.0h);

    // Skip if border width is effectively zero
    float borderMinWidth = max(in.borderMinWidth, 0.0);
    half borderMinAlpha = clamp(half(in.borderMinAlpha), 0.0h, 1.0h);
    if (borderWidth < borderMinWidth || borderAlpha <= borderMinAlpha) {
        discard_fragment();
    }

    // v4: Edge-mask selective border rendering.
    // Only draw borders on edges marked as outer boundary (edge_mask bits).
    // bary.x = distance from edge v1-v2 (bit1), bary.y = distance from edge v2-v0 (bit2),
    // bary.z = distance from edge v0-v1 (bit0).
    uint mask = in.edgeMask;
    float pixelToBary = max(fwidth(min(bary.x, min(bary.y, bary.z))), in.borderFwidthEpsilon);
    float borderBaryWidth = borderWidth * pixelToBary;
    float aa = pixelToBary * max(in.borderAAFactor, 0.0);

    // Compute per-edge SDF and mask with edge_mask bits
    float edgeMaskStrength = 0.0;
    if (mask & 0x02u) {  // bit1: edge v1-v2, distance = bary.x
        edgeMaskStrength = max(edgeMaskStrength, 1.0 - smoothstep(borderBaryWidth, borderBaryWidth + aa, bary.x));
    }
    if (mask & 0x04u) {  // bit2: edge v2-v0, distance = bary.y
        edgeMaskStrength = max(edgeMaskStrength, 1.0 - smoothstep(borderBaryWidth, borderBaryWidth + aa, bary.y));
    }
    if (mask & 0x01u) {  // bit0: edge v0-v1, distance = bary.z
        edgeMaskStrength = max(edgeMaskStrength, 1.0 - smoothstep(borderBaryWidth, borderBaryWidth + aa, bary.z));
    }

    half alpha = borderAlpha * half(clamp(edgeMaskStrength, 0.0, 1.0));

    if (alpha <= half(in.borderDiscardAlpha)) {
        discard_fragment();
    }

    // Pre-multiplied alpha
    half3 borderColor = half3(1.0h, 1.0h, 1.0h);
    borderColor *= alpha;

    return half4(borderColor, alpha);
}

// ─── Pass 3: Metallic Lighting Enhancement ───
// Adds screen-space metallic sheen for ALL patches (from S0 onwards).
// Fresnel-based rim light emphasizes surface curvature. Bigger/darker triangles
// show the most metallic character (area_factor boost applied in C++ Core layer).

fragment half4 metallicLightingFragment(
    VertexOut in [[stage_in]],
    constant ScanGuidanceUniforms &uniforms [[buffer(1)]]
) {
    // v4: Cook-Torrance PBR specular highlight
    half3 N = normalize(half3(in.worldNormal));
    half3 V = normalize(half3(uniforms.cameraPosition - in.worldPosition));
    half3 L = normalize(half3(-uniforms.primaryLightDirection));
    half3 H = normalize(V + L);

    half NdotL = max(dot(N, L), 0.0h);
    half NdotV = max(dot(N, V), 0.001h);
    half LdotH = max(dot(L, H), 0.001h);

    half metallic = clamp(half(in.metallic), 0.0h, 1.0h);
    half roughness = clamp(half(in.roughness), 0.05h, 1.0h);

    // F0 for dielectric=0.04, metallic lerps toward albedo
    half3 albedo = half3(in.grayscaleColor);
    half3 F0 = mix(half3(0.04h), albedo, metallic);

    // Cook-Torrance BRDF: D * V * F
    half D = NDF_GGX_Safe(N, H, roughness);
    half Vis = VisibilityKelemen(LdotH, roughness);
    half3 F = FresnelSchlick(LdotH, F0);

    half3 specular = D * Vis * F * NdotL * half(uniforms.primaryLightIntensity);

    // SH environment diffuse
    half3 irradiance = evaluateSH(float3(N), uniforms.shCoeffs);
    half3 diffuse = (1.0h - F) * (1.0h - metallic) * albedo * irradiance;

    // Combine: additive specular + subtle diffuse tint
    half3 color = specular + diffuse * 0.15h;

    // Scale by metallic intensity (non-metallic surfaces get minimal contribution)
    half intensity = metallic * 0.6h + 0.05h;
    color *= intensity;

    // Pre-multiplied alpha output
    half alpha = clamp(half(length(color)), 0.0h, 0.5h);
    return half4(color * alpha, alpha);
}

// ─── Pass 4: Color Correction ───
// Subtle color temperature shift: warm for high evidence, cool for low.
// Reinforces the Oklab cold→warm mapping with an additional composited layer.

fragment half4 colorCorrectionFragment(
    VertexOut in [[stage_in]],
    constant ScanGuidanceUniforms &uniforms [[buffer(1)]]
) {
    (void)uniforms;

    // v4: Oklab-based color temperature correction.
    // Low evidence → cool (subtle blue tint), high evidence → warm neutral.
    half display = clamp(half(in.display), 0.0h, 1.0h);

    // Use the Oklab mapping for perceptually uniform color grading
    half3 oklabColor = evidenceToOklabColor(display);
    half3 srgbColor = linearToSRGB(oklabColor);

    // Very subtle blend — this is an overlay, not a replacement
    half3 tint = srgbColor - half3(in.grayscaleColor);
    half intensity = 0.12h * (1.0h - display * 0.5h);  // Stronger at low evidence

    half alpha = intensity;
    half3 color = tint * alpha;

    return half4(color, alpha);
}

// ─── Pass 5: Screen-Space Ambient Occlusion (SSAO approximation) ───
// Per-fragment cavity detection using normal vs view angle.
// Darkens edges and crevices for depth perception without a separate depth pass.

fragment half4 ambientOcclusionFragment(
    VertexOut in [[stage_in]],
    constant ScanGuidanceUniforms &uniforms [[buffer(1)]]
) {
    // v4: Per-fragment cavity detection using view-dependent curvature proxy.
    // N·V near 0 → edge/cavity → darken. N·V near 1 → facing camera → no darken.
    half3 N = normalize(half3(in.worldNormal));
    half3 V = normalize(half3(uniforms.cameraPosition - in.worldPosition));
    half NdotV = max(dot(N, V), 0.0h);

    // Cavity factor: strong darkening at glancing angles
    half cavity = 1.0h - smoothstep(0.1h, 0.6h, NdotV);

    // Scale by evidence: low evidence gets more AO darkening (emphasizes depth)
    half display = clamp(half(in.display), 0.0h, 1.0h);
    half aoStrength = 0.15h * (1.0h - display * 0.7h);

    half darken = cavity * aoStrength;

    // Output as darkening overlay (multiply blend mode)
    // alpha = darken amount, color = black
    return half4(0.0h, 0.0h, 0.0h, darken);
}

// ─── Pass 6: Post-Processing (Film Grain) ───
// Subtle film grain for tactile quality feedback.
// Skipped at serious/critical thermal tiers to save fragment ALU.

fragment half4 postProcessFragment(
    VertexOut in [[stage_in]],
    constant ScanGuidanceUniforms &uniforms [[buffer(1)]]
) {
    // v4: Subtle film grain for tactile quality feedback.
    // Grain intensity decreases with evidence (high quality = clean look).
    half display = clamp(half(in.display), 0.0h, 1.0h);
    half grainIntensity = 0.04h * (1.0h - display * 0.8h);

    // Position + time-based hash for animated grain
    float2 screenPos = in.position.xy;
    float t = uniforms.time;
    float noise = fract(sin(dot(screenPos + t * 37.0, float2(12.9898, 78.233))) * 43758.5453);
    half grain = (half(noise) - 0.5h) * grainIntensity;

    // Additive grain overlay
    half alpha = abs(grain);
    half3 color = half3(grain);

    return half4(color * alpha, alpha);
}
