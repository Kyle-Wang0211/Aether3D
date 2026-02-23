// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// TSDFShaders.metal
// Aether3D
//
// Metal compute shaders for TSDF integration

#include <metal_stdlib>
#include "TSDFShaderTypes.h"

using namespace metal;

/// For each depth pixel, compute world-space position and determine which VoxelBlocks are needed.
/// Threadgroup: 8×8 = 64 threads (2 SIMD-groups, optimal for high register pressure)
kernel void projectDepthAndAllocate(
    texture2d<float, access::read> depthMap [[texture(0)]],
    texture2d<uint, access::read> confidenceMap [[texture(1)]],
    constant float3x3& intrinsicsInverse [[buffer(0)]],
    constant float4x4& cameraToWorld [[buffer(1)]],
    constant TSDFParams& params [[buffer(2)]],
    device GPUBlockIndex* outputBlocks [[buffer(3)]],
    device atomic_uint& blockCount [[buffer(4)]],
    device atomic_uint& validPixelCount [[buffer(5)]],
    uint2 gid [[thread_position_in_grid]]
) {
    // Bounds check (BUG-11: use params instead of hardcoded 256×192)
    if (gid.x >= params.depthWidth || gid.y >= params.depthHeight) return;

    float depth = depthMap.read(gid).r;

    // Depth range filter
    if (depth < params.depthMin || depth > params.depthMax || isnan(depth) || isinf(depth)) return;

    // Confidence filter: skip confidence 0 if configured
    uint confidence = confidenceMap.read(gid).r;
    if (params.skipLowConfidence && confidence == 0) return;

    // Count valid pixels (for frame quality gate)
    atomic_fetch_add_explicit(&validPixelCount, 1, memory_order_relaxed);

    // Back-project to camera space
    float3 pixel = float3(float(gid.x), float(gid.y), 1.0) * depth;
    float3 p_cam = intrinsicsInverse * pixel;
    float4 p_world = cameraToWorld * float4(p_cam, 1.0);

    // Select voxel size based on depth
    float voxelSize = depth < params.depthNearThreshold ? params.voxelSizeNear
                    : depth < params.depthFarThreshold  ? params.voxelSizeMid
                    :                                     params.voxelSizeFar;

    float blockWorldSize = voxelSize * float(params.blockSize);
    int3 blockIdx = int3(floor(p_world.xyz / blockWorldSize));

    // Atomic append (with overflow guard)
    uint idx = atomic_fetch_add_explicit(&blockCount, 1, memory_order_relaxed);
    if (idx < params.maxOutputBlocks) {
        outputBlocks[idx] = GPUBlockIndex{blockIdx.x, blockIdx.y, blockIdx.z, 0};
    }
}

/// For each active voxel in truncation band, update SDF and weight.
kernel void integrateTSDF(
    texture2d<float, access::sample> depthMap [[texture(0)]],
    texture2d<uint, access::read> confidenceMap [[texture(1)]],
    constant float3x3& intrinsics [[buffer(0)]],
    constant float4x4& worldToCamera [[buffer(1)]],
    constant float3& cameraPosition [[buffer(2)]],
    device TSDFVoxel* voxelBuffer [[buffer(3)]],
    constant TSDFParams& params [[buffer(4)]],
    device BlockEntry* activeBlocks [[buffer(5)]],
    uint3 gid [[thread_position_in_grid]],
    uint3 tgid [[threadgroup_position_in_grid]]
) {
    // Map threadgroup → active block
    BlockEntry block = activeBlocks[tgid.x];
    float voxelSize = block.voxelSize;
    // Guardrail #25: Truncation sanity — ensure τ >= 2 × voxelSize
    float truncation = max(max(params.truncationMultiplier * voxelSize, params.truncationMinimum), 2.0f * voxelSize);

    float3 blockOrigin = float3(block.blockWorldOriginX, block.blockWorldOriginY, block.blockWorldOriginZ);

    // Map local thread position → voxel world position
    // Each thread handles one column of 8 voxels (Z-axis)
    for (int z = 0; z < 8; z++) {
        float3 voxelCenter = blockOrigin + float3(float(gid.x), float(gid.y), float(z)) * voxelSize + voxelSize * 0.5;

        // Project to camera space
        float4 p_cam = worldToCamera * float4(voxelCenter, 1.0);
        if (p_cam.z <= 0) continue;  // Behind camera

        // Project to pixel coordinates
        float2 pixel = float2(
            intrinsics[0][0] * p_cam.x / p_cam.z + intrinsics[0][2],
            intrinsics[1][1] * p_cam.y / p_cam.z + intrinsics[1][2]
        );

        // Bounds check (BUG-11: use params, fix off-by-one: valid range [0, width) and [0, height))
        if (pixel.x < 0 || pixel.x >= float(params.depthWidth) || pixel.y < 0 || pixel.y >= float(params.depthHeight)) continue;

        // Bilinear-sampled depth (hardware-accelerated, improves sub-pixel quality)
        constexpr sampler depthSampler(coord::pixel, filter::linear, address::clamp_to_edge);
        float measured_depth = depthMap.sample(depthSampler, pixel + 0.5).r;

        if (isnan(measured_depth) || measured_depth < params.depthMin) continue;

        float sdf = measured_depth - p_cam.z;  // precise: prevent reordering

        if (sdf > truncation) continue;  // Too far in front

        // Load current voxel
        uint voxelIdx = block.poolOffset * 512 + gid.x * 64 + gid.y * 8 + z;
        half old_sdf = voxelBuffer[voxelIdx].sdf;
        // CRITICAL: weight is uint8_t on both Swift and Metal side.
        // Read as uint8_t, cast to float for arithmetic. NEVER read as half.
        float old_weight = float(voxelBuffer[voxelIdx].weight);

        if (sdf < -truncation) {
            // SPACE CARVING: ray passed through previously-observed surface
            if (old_weight > 0) {
                float decayed = max(0.0f, old_weight - float(params.carvingDecayRate));
                voxelBuffer[voxelIdx].weight = uint8_t(decayed);
                if (decayed == 0.0f) {
                    voxelBuffer[voxelIdx].sdf = half(1.0);  // Reset to empty
                }
            }
            continue;
        }

        // Within truncation band — fuse
        uint confidence = confidenceMap.read(uint2(pixel)).r;
        float w_conf = params.confidenceWeights[confidence];

        // Viewing angle weight (approximate normal from SDF gradient)
        float3 viewRay = normalize(cameraPosition - voxelCenter);
        float w_angle = max(params.viewingAngleFloor, abs(dot(viewRay, float3(0,1,0))));  // Simplified

        // Distance-dependent weight
        float depth = p_cam.z;
        float w_dist = 1.0 / (1.0 + params.distanceDecayAlpha * depth * depth);

        float w_obs = w_conf * w_angle * w_dist;
        float sdf_normalized = clamp(sdf / truncation, -1.0f, 1.0f);

        // Running weighted average fusion (Curless & Levoy 1996)
        float new_sdf = (float(old_sdf) * old_weight + sdf_normalized * w_obs)
                               / (old_weight + w_obs);
        
        // Guardrail #26: SDF range check — clamp normalized SDF to [-1.0, +1.0]
        new_sdf = clamp(new_sdf, -1.0f, 1.0f);
        
        // UX-1: SDF Dead Zone (BUG-11: from params)
        float sdfDelta = abs(new_sdf - float(old_sdf));
        float deadZone = params.sdfDeadZoneBase + params.sdfDeadZoneWeightScale * (float(old_weight) / float(params.weightMax));
        if (sdfDelta < deadZone) {
            continue;  // Skip update — no visible change
        }
        
        // Guardrail #8: Weight overflow — clamp to weightMax
        float new_weight = min(old_weight + w_obs, float(params.weightMax));

        voxelBuffer[voxelIdx].sdf = half(new_sdf);
        voxelBuffer[voxelIdx].weight = uint8_t(clamp(new_weight, 0.0f, 255.0f));
        voxelBuffer[voxelIdx].confidence = max(voxelBuffer[voxelIdx].confidence, uint8_t(confidence));
    }
}
