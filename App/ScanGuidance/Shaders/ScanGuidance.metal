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
// Use packed_float3 to avoid 16-byte alignment padding (48 bytes total)
struct PerTriangleData {
    float  flipAngle;
    float  rippleAmplitude;
    float  borderWidth;
    packed_float3 flipAxisOrigin;
    packed_float3 flipAxisDirection;
    packed_float3 grayscaleColor;  // v7.0.1: was uint8_t×3, now float3 [0,1]
};

// ─── PBR Helper Functions ───

// GGX/Trowbridge-Reitz Normal Distribution Function
inline half NDF_GGX(half NdotH, half roughness) {
    half a = roughness * roughness;
    half a2 = a * a;
    half NdotH2 = NdotH * NdotH;
    half denom = NdotH2 * (a2 - 1.0h) + 1.0h;
    denom = M_PI_H * denom * denom;
    return a2 / max(denom, 1e-7h);
}

// Schlick-GGX Geometry sub-function
inline half GeometrySchlickGGX(half NdotV, half roughness) {
    half r = roughness + 1.0h;
    half k = (r * r) / 8.0h;
    return NdotV / (NdotV * (1.0h - k) + k);
}

// Smith's Geometry Function
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
    if (angle > 0.001) {
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
    if (ripple > 0.001) {
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
    
    return out;
}

fragment half4 wedgeFillFragment(
    VertexOut in [[stage_in]],
    constant ScanGuidanceUniforms &uniforms [[buffer(1)]]
) {
    // ── Material Properties ──
    half metallic = half(in.metallic);
    half roughness = half(in.roughness);
    
    // Base color: grayscale mapped by coverage
    half3 baseColor = half3(in.grayscaleColor);
    
    // For metallic surfaces, F0 = base color
    // For dielectric, F0 = 0.04
    half3 F0 = mix(half3(0.04h), baseColor, metallic);
    
    // ── Vectors ──
    float3 N = normalize(in.worldNormal);
    float3 V = normalize(uniforms.cameraPosition - in.worldPosition);
    float3 L = normalize(-uniforms.primaryLightDirection);
    float3 H = normalize(V + L);
    
    half NdotL = half(max(dot(N, L), 0.0));
    half NdotV = half(max(dot(N, V), 0.001));
    half NdotH = half(max(dot(N, H), 0.0));
    half HdotV = half(max(dot(H, V), 0.0));
    
    // ── Cook-Torrance Specular BRDF ──
    half D = NDF_GGX(NdotH, roughness);
    half G = GeometrySmith(NdotV, NdotL, roughness);
    half3 F = FresnelSchlick(HdotV, F0);
    
    half3 numerator = D * G * F;
    half denominator = 4.0h * NdotV * NdotL + 0.0001h;
    half3 specular = numerator / denominator;
    
    // ── Energy Conservation ──
    half3 kS = F;
    half3 kD = (1.0h - kS) * (1.0h - metallic);
    
    // ── Diffuse: Lambertian ──
    half3 diffuse = kD * baseColor / M_PI_H;
    
    // ── Direct Lighting ──
    half lightIntensity = half(uniforms.primaryLightIntensity);
    half normalizedIntensity = clamp(lightIntensity / 1000.0h, 0.1h, 3.0h);
    half3 directLight = (diffuse + specular) * NdotL * normalizedIntensity;
    
    // ── Indirect Lighting (SH-based IBL) ──
    half3 irradiance = evaluateSH(N, uniforms.shCoeffs);
    irradiance = irradiance / max(half3(uniforms.shCoeffs[0]) * 0.282095h, 0.01h) * 0.3h;
    half3 indirectDiffuse = kD * baseColor * irradiance;
    
    // Indirect specular: approximate with SH evaluated at reflection direction
    float3 R = reflect(-V, N);
    half3 reflectedIrradiance = evaluateSH(R, uniforms.shCoeffs);
    reflectedIrradiance = reflectedIrradiance / max(half3(uniforms.shCoeffs[0]) * 0.282095h, 0.01h) * 0.5h;
    half3 indirectSpecular = F0 * reflectedIrradiance * (1.0h - roughness * 0.7h);
    
    half3 indirect = indirectDiffuse + indirectSpecular;
    
    // ── Combine ──
    half3 color = directLight + indirect;
    
    // ── Ambient minimum ──
    color = max(color, baseColor * 0.02h);
    
    // ── Ripple highlight ──
    if (in.rippleAmplitude > 0.001) {
        half rippleBoost = half(in.rippleAmplitude) * 0.15h;
        color += rippleBoost;
    }
    
    // ── Tone mapping (simple Reinhard) ──
    color = color / (color + 1.0h);
    
    // ── Alpha: opaque for visible triangles, fade at S5 ──
    half alpha = 1.0h;
    if (in.display > 0.88h) {  // s4ToS5Threshold
        alpha = 1.0h - (half(in.display) - 0.88h) / (1.0h - 0.88h);
        alpha = clamp(alpha, 0.0h, 1.0h);
    }
    
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
    float2 d1 = pa - ba * clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    float2 d2 = pb - cb * clamp(dot(pb, cb) / dot(cb, cb), 0.0, 1.0);
    float2 d3 = pc - ac * clamp(dot(pc, ac) / dot(ac, ac), 0.0, 1.0);
    float md = min(min(dot(d1,d1), dot(d2,d2)), dot(d3,d3));
    return sqrt(md) * s;
}

inline float sdRoundedTriangle(float2 p, float2 a, float2 b, float2 c, float r) {
    return sdTriangle2D(p, a, b, c) - r;
}

fragment half4 borderStrokeFragment(
    VertexOut in [[stage_in]],
    constant ScanGuidanceUniforms &uniforms [[buffer(1)]]
) {
    // Border width from AdaptiveBorderCalculator
    half borderWidth = half(in.borderWidth);
    
    // Skip if border width is effectively zero
    if (borderWidth < 0.5h) {
        discard_fragment();
    }
    
    // Border color: bright white
    half3 borderColor = half3(1.0h, 1.0h, 1.0h);
    
    // Alpha: modulated by display value
    half baseAlpha = 1.0h;  // borderAlphaAtS0
    half displayFade = 1.0h - half(in.display) * 0.5h;
    half alpha = baseAlpha * displayFade;
    
    // Apply Stevens' Power Law gamma correction
    half gamma = half(uniforms.borderGamma);  // 1.4
    alpha = pow(alpha, 1.0h / gamma);
    
    // Anti-aliasing: smooth edge based on screen-space derivatives
    half edgeSoftness = half(fwidth(in.position.x) + fwidth(in.position.y)) * 0.5h;
    alpha *= smoothstep(0.0h, edgeSoftness * 2.0h, borderWidth * 0.1h);
    
    // Pre-multiplied alpha
    borderColor *= alpha;
    
    return half4(borderColor, alpha);
}

// ─── Phase 3: Metallic Lighting Pass (not implemented in Phase 2) ───
// Will be added in Phase 3
