// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// CPUIntegrationBackend.swift
// Aether3D
//
// Pure Swift CPU backend for TSDF integration — pixel-by-pixel processing

import Foundation

/// CPU backend for TSDF integration — pure Swift, pixel-by-pixel.
/// Used for tests and Mac Catalyst fallback (no Metal support).
public final class CPUIntegrationBackend: TSDFIntegrationBackend {
    
    public init() {}
    
    /// Process one frame's depth data into the voxel volume (CPU path)
    /// BUG-9: Actually read/write voxels via volume.writeBlock using poolIndex from activeBlocks.
    public func processFrame(
        input: IntegrationInput,
        depthData: DepthDataProvider,
        volume: VoxelBlockAccessor,
        activeBlocks: [(BlockIndex, Int)]
    ) async -> IntegrationResult.IntegrationStats {
        let startTime = ProcessInfo.processInfo.systemUptime
        
        var blocksUpdated = 0
        var voxelsUpdated = 0
        
        let intrinsics = input.intrinsics
        #if canImport(simd)
        let intrinsicsInverse = intrinsics.inverse
        let worldToCamera = input.cameraToWorld.inverse
        let cameraPosition = tsdTranslation(input.cameraToWorld)
        #else
        let fx = intrinsics.columns.0.x
        let fy = intrinsics.columns.1.y
        let cx = intrinsics.columns.2.x
        let cy = intrinsics.columns.2.y
        let intrinsicsInverse = TSDFMatrix3x3(
            c0: TSDFFloat3(1.0/fx, 0, 0),
            c1: TSDFFloat3(0, 1.0/fy, 0),
            c2: TSDFFloat3(-cx/fx, -cy/fy, 1.0)
        )
        let worldToCamera = input.cameraToWorld
        let cameraPosition = tsdTranslation(input.cameraToWorld)
        #endif
        
        for (blockIdx, poolIndex) in activeBlocks {
            var block = volume.readBlock(at: poolIndex)
            let voxelSize = block.voxelSize
            let truncation = AdaptiveResolution.truncationDistance(voxelSize: voxelSize)
            let blockWorldSize = voxelSize * Float(TSDFConstants.blockSize)
            
            for x in 0..<TSDFConstants.blockSize {
                for y in 0..<TSDFConstants.blockSize {
                    for z in 0..<TSDFConstants.blockSize {
                        let voxelLocalPos = TSDFFloat3(
                            Float(x) * voxelSize + voxelSize * 0.5,
                            Float(y) * voxelSize + voxelSize * 0.5,
                            Float(z) * voxelSize + voxelSize * 0.5
                        )
                        let voxelWorldPos = TSDFFloat3(
                            Float(blockIdx.x) * blockWorldSize + voxelLocalPos.x,
                            Float(blockIdx.y) * blockWorldSize + voxelLocalPos.y,
                            Float(blockIdx.z) * blockWorldSize + voxelLocalPos.z
                        )
                        
                        let p_cam = tsdTransform(worldToCamera, voxelWorldPos)
                        if p_cam.z <= 0 { continue }
                        
                        #if canImport(simd)
                        let pixelX = intrinsics.columns.0.x * p_cam.x / p_cam.z + intrinsics.columns.2.x
                        let pixelY = intrinsics.columns.1.y * p_cam.y / p_cam.z + intrinsics.columns.2.y
                        #else
                        let pixelX = fx * p_cam.x / p_cam.z + cx
                        let pixelY = fy * p_cam.y / p_cam.z + cy
                        #endif
                        
                        let px = Int(pixelX.rounded())
                        let py = Int(pixelY.rounded())
                        if px < 0 || px >= depthData.width || py < 0 || py >= depthData.height { continue }
                        
                        let measuredDepth = depthData.depthAt(x: px, y: py)
                        if measuredDepth.isNaN || measuredDepth < TSDFConstants.depthMin { continue }
                        
                        let sdf = measuredDepth - p_cam.z
                        if sdf > truncation { continue }
                        
                        let confidence = depthData.confidenceAt(x: px, y: py)
                        let w_conf = AdaptiveResolution.confidenceWeight(level: confidence)
                        let w_dist = AdaptiveResolution.distanceWeight(depth: p_cam.z)
                        let viewRay = (cameraPosition - voxelWorldPos).normalized()
                        let w_angle = AdaptiveResolution.viewingAngleWeight(
                            viewRay: viewRay,
                            normal: TSDFFloat3(0, 1, 0)
                        )
                        let w_obs = w_conf * w_angle * w_dist
                        let sdf_normalized = max(-1.0, min(1.0, sdf / truncation))
                        
                        let voxelIndex = x + y * TSDFConstants.blockSize + z * TSDFConstants.blockSize * TSDFConstants.blockSize
                        let oldVoxel = block.voxels[voxelIndex]
                        let oldWeight = Float(oldVoxel.weight)
                        let oldSDF: Float
                        #if canImport(simd)
                        oldSDF = Float(oldVoxel.sdf)
                        #else
                        oldSDF = oldVoxel.sdf.floatValue
                        #endif
                        let newWeightF = min(oldWeight + w_obs, Float(TSDFConstants.weightMax))
                        let newSDF: Float
                        if oldWeight + w_obs > 0 {
                            newSDF = (oldSDF * oldWeight + sdf_normalized * w_obs) / (oldWeight + w_obs)
                        } else {
                            newSDF = sdf_normalized
                        }
                        block.voxels[voxelIndex] = Voxel(
                            sdf: SDFStorage(max(-1.0, min(1.0, newSDF))),
                            weight: UInt8(max(0, min(Int(TSDFConstants.weightMax), Int(newWeightF.rounded())))),
                            confidence: max(oldVoxel.confidence, confidence)
                        )
                        voxelsUpdated += 1
                    }
                }
            }
            
            block.integrationGeneration += 1
            block.lastObservedTimestamp = input.timestamp
            volume.writeBlock(at: poolIndex, block)
            blocksUpdated += 1
        }
        
        let totalTime = (ProcessInfo.processInfo.systemUptime - startTime) * 1000.0
        return IntegrationResult.IntegrationStats(
            blocksUpdated: blocksUpdated,
            blocksAllocated: 0,
            voxelsUpdated: voxelsUpdated,
            gpuTimeMs: totalTime,
            totalTimeMs: totalTime
        )
    }
}
