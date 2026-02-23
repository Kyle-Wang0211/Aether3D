// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// TSDFShaderTypes.h
// Aether3D
//
// Shared header between Swift and Metal — defines GPU-side struct layouts.

#ifndef TSDFShaderTypes_h
#define TSDFShaderTypes_h

#include <simd/simd.h>

/// GPU-side voxel — must match Swift Voxel struct layout (8 bytes)
struct TSDFVoxel {
    half sdf;              // 2 bytes — SDFStorage on Swift side
    uint8_t weight;        // 1 byte — NOT half, UInt8
    uint8_t confidence;    // 1 byte
    uint8_t reserved[4];   // 4 bytes
};

/// GPU-side block index — 16 bytes (padded from Swift's 12-byte BlockIndex)
struct GPUBlockIndex {
    int32_t x;
    int32_t y;
    int32_t z;
    int32_t _pad;  // Explicit padding to match Metal int3 alignment
};

/// Active block entry for integration kernel dispatch
struct BlockEntry {
    struct GPUBlockIndex blockIndex;
    int32_t poolOffset;      // Index into voxel buffer (pool index × 512)
    float voxelSize;         // Adaptive: 0.005 / 0.01 / 0.02
    float blockWorldOriginX; // Pre-computed world-space origin
    float blockWorldOriginY;
    float blockWorldOriginZ;
    int32_t _pad2;           // Align to 32 bytes
};

/// Per-frame parameters — all constants the GPU kernels need
struct TSDFParams {
    // Depth filtering
    float depthMin;
    float depthMax;
    int skipLowConfidence;   // bool as int for Metal
    int _pad0;

    // Adaptive resolution thresholds
    float depthNearThreshold;
    float depthFarThreshold;
    float voxelSizeNear;
    float voxelSizeMid;
    float voxelSizeFar;

    // Truncation
    float truncationMultiplier;
    float truncationMinimum;

    // Fusion weights
    float confidenceWeights[3];  // [low, mid, high] = [0.1, 0.5, 1.0]
    float distanceDecayAlpha;
    float viewingAngleFloor;
    uint8_t weightMax;
    uint8_t carvingDecayRate;
    uint8_t _pad1[2];

    // Block geometry
    int blockSize;           // 8

    // Limits
    int maxOutputBlocks;     // Allocation kernel output cap

    // BUG-11: Depth resolution and SDF dead zone (no hardcoding in shader)
    uint32_t depthWidth;
    uint32_t depthHeight;
    float sdfDeadZoneBase;
    float sdfDeadZoneWeightScale;
};

#endif /* TSDFShaderTypes_h */
