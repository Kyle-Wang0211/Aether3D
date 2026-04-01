// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// GaussianSplatTypes.h
// Aether3D
//
// Shared GPU struct definitions for Gaussian Splatting rendering.
// Used by both GaussianSplat.metal and Swift (via bridging).

#ifndef GAUSSIAN_SPLAT_TYPES_H
#define GAUSSIAN_SPLAT_TYPES_H

#include <simd/simd.h>

// ═══════════════════════════════════════════════════════════════════════
// PackedSplat: 16-byte compact Gaussian (Spark encoding)
// ═══════════════════════════════════════════════════════════════════════

struct PackedSplatGPU {
    uint8_t  rgba[4];         // sRGB color + linear opacity
    uint16_t center[3];       // float16 xyz position
    uint8_t  quat_uv[2];     // octahedral-encoded rotation axis
    uint8_t  log_scale[3];   // log-encoded xyz scale
    uint8_t  quat_angle;     // quantized rotation angle [0, pi]
};

// ═══════════════════════════════════════════════════════════════════════
// Camera Uniforms
// ═══════════════════════════════════════════════════════════════════════

struct SplatCameraUniforms {
    simd_float4x4 viewMatrix;
    simd_float4x4 projMatrix;
    simd_float4x4 viewProjMatrix;
    float fx, fy;               // focal length (pixels)
    float cx, cy;               // principal point (pixels)
    uint32_t vpWidth;           // viewport width
    uint32_t vpHeight;          // viewport height
    uint32_t splatCount;        // total splats to process
    uint32_t renderSplatLimit;  // 0 = unlimited
};

// ═══════════════════════════════════════════════════════════════════════
// Sort Pass Parameters
// ═══════════════════════════════════════════════════════════════════════

struct SortPassParams {
    uint32_t passIndex;         // current radix sort pass (0-3)
    uint32_t totalCount;        // total elements to sort
    uint32_t bitOffset;         // bit shift for this pass (passIndex * 8)
    uint32_t _pad;
};

// ═══════════════════════════════════════════════════════════════════════
// Vertex Output (Vertex → Fragment)
// ═══════════════════════════════════════════════════════════════════════

struct SplatVertexOut {
    simd_float4 position;       // [[position]]
    simd_float2 uv;             // quad UV [-1,1]
    simd_float4 color;          // rgba (premultiplied)
    simd_float2 axis;           // ellipse axes (major, minor)
    float       cosTheta;       // ellipse rotation
    float       sinTheta;
};

#endif  // GAUSSIAN_SPLAT_TYPES_H
