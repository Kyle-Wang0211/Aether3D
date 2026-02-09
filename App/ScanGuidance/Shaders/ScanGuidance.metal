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
struct PerTriangleData {
    float  flipAngle;
    float  rippleAmplitude;
    float  borderWidth;
    float3 flipAxisOrigin;
    float3 flipAxisDirection;
    float3 grayscaleColor;  // v7.0.1: was uint8_t×3, now float3 [0,1]
};

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
    float4 pos = float4(in.position, 1.0);
    
    // Phase 2: Flip rotation not implemented (Phase 3)
    // float angle = triData[triId].flipAngle;
    // if (angle > 0.001) {
    //     // Apply flip rotation
    // }
    
    out.position = uniforms.viewProjectionMatrix * uniforms.modelMatrix * pos;
    out.worldNormal = normalize((uniforms.modelMatrix * float4(in.normal, 0.0)).xyz);
    out.worldPosition = (uniforms.modelMatrix * pos).xyz;
    out.metallic = in.metallic;
    out.roughness = in.roughness;
    out.display = in.display;
    out.rippleAmplitude = triData[triId].rippleAmplitude;
    out.grayscaleColor = triData[triId].grayscaleColor;
    out.borderWidth = triData[triId].borderWidth;
    return out;
}

fragment float4 wedgeFillFragment(
    VertexOut in [[stage_in]],
    constant ScanGuidanceUniforms &uniforms [[buffer(1)]]
) {
    // Phase 2: Simple grayscale rendering
    return float4(in.grayscaleColor, 1.0);
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

fragment float4 borderStrokeFragment(
    VertexOut in [[stage_in]],
    constant ScanGuidanceUniforms &uniforms [[buffer(1)]]
) {
    // Phase 2: Simple border rendering using SDF
    // Project to screen space for SDF calculation
    float2 screenPos = in.position.xy;
    
    // Adaptive border width based on display value
    float borderWidth = in.borderWidth;
    
    // Simple border: white border with adaptive width
    // Phase 2: Simplified implementation
    float borderAlpha = 1.0;
    float3 borderColor = float3(1.0, 1.0, 1.0);  // White
    
    return float4(borderColor, borderAlpha);
}

// ─── Phase 3: Metallic Lighting Pass (not implemented in Phase 2) ───
// Will be added in Phase 3
