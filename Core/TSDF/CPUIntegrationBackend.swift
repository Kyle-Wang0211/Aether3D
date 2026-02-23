// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// CPUIntegrationBackend.swift
// Aether3D
//
// Pure Swift CPU backend for TSDF integration — pixel-by-pixel processing

import Foundation
import CAetherNativeBridge

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

        // M02 cutover path: prefer C++ integration kernel and write back updated blocks.
        // Swift loop remains only as fail-safe fallback.
        let pixelCount = depthData.width * depthData.height
        var depthBuffer = Array(repeating: Float.nan, count: pixelCount)
        var confidenceBuffer = Array(repeating: UInt8(0), count: pixelCount)
        let voxelsPerBlock = TSDFConstants.blockSize * TSDFConstants.blockSize * TSDFConstants.blockSize
        for y in 0..<depthData.height {
            for x in 0..<depthData.width {
                let idx = y * depthData.width + x
                depthBuffer[idx] = depthData.depthAt(x: x, y: y)
                confidenceBuffer[idx] = depthData.confidenceAt(x: x, y: y)
            }
        }
        let intrinsics = input.intrinsics
        let (fx, fy, cx, cy) = tsdIntrinsicsParameters(intrinsics)
        var viewMatrix = [Float](repeating: 0, count: 16)
        for c in 0..<4 {
            for r in 0..<4 {
                viewMatrix[c * 4 + r] = input.cameraToWorld[c][r]
            }
        }
        if !activeBlocks.isEmpty {
            var nativeBlocks = Array(
                repeating: aether_external_block_t(
                    x: 0,
                    y: 0,
                    z: 0,
                    voxel_size: AdaptiveResolution.voxelSize(forDepth: 1.0),
                    integration_generation: 0,
                    mesh_generation: 0,
                    last_observed_timestamp: 0,
                    voxels: nil,
                    voxel_count: 0
                ),
                count: activeBlocks.count
            )
            var nativeVoxels = Array(
                repeating: aether_external_voxel_t(sdf_bits: 0, weight: 0, confidence: 0),
                count: activeBlocks.count * voxelsPerBlock
            )

            for (blockSlot, (blockIdx, poolIndex)) in activeBlocks.enumerated() {
                let block = volume.readBlock(at: poolIndex)
                let base = blockSlot * voxelsPerBlock
                for i in 0..<voxelsPerBlock {
                    nativeVoxels[base + i] = toNativeVoxel(block.voxels[i])
                }
                nativeBlocks[blockSlot] = aether_external_block_t(
                    x: Int32(blockIdx.x),
                    y: Int32(blockIdx.y),
                    z: Int32(blockIdx.z),
                    voxel_size: block.voxelSize,
                    integration_generation: block.integrationGeneration,
                    mesh_generation: block.meshGeneration,
                    last_observed_timestamp: block.lastObservedTimestamp,
                    voxels: nil,
                    voxel_count: UInt32(voxelsPerBlock)
                )
            }

            var nativeResult = aether_integration_result_t(
                voxels_integrated: 0,
                blocks_updated: 0,
                success: 0,
                skipped: 0,
                skip_reason: 0
            )

            let nativeRC = depthBuffer.withUnsafeBufferPointer { depthPtr in
                confidenceBuffer.withUnsafeBufferPointer { confPtr in
                    viewMatrix.withUnsafeBufferPointer { viewPtr in
                        nativeVoxels.withUnsafeMutableBufferPointer { voxelPtr in
                            nativeBlocks.withUnsafeMutableBufferPointer { blockPtr in
                                guard let voxelBase = voxelPtr.baseAddress else { return -1 }
                                for blockSlot in 0..<blockPtr.count {
                                    blockPtr[blockSlot].voxels = voxelBase.advanced(by: blockSlot * voxelsPerBlock)
                                }
                                var nativeInput = aether_integration_input_t(
                                    depth_data: depthPtr.baseAddress,
                                    depth_width: Int32(depthData.width),
                                    depth_height: Int32(depthData.height),
                                    confidence_data: confPtr.baseAddress,
                                    voxel_size: AdaptiveResolution.voxelSize(forDepth: 1.0),
                                    fx: fx,
                                    fy: fy,
                                    cx: cx,
                                    cy: cy,
                                    view_matrix: viewPtr.baseAddress,
                                    timestamp: input.timestamp,
                                    tracking_state: Int32(input.trackingState)
                                )
                                return Int(
                                    aether_tsdf_integrate_external_blocks(
                                        &nativeInput,
                                        blockPtr.baseAddress,
                                        Int32(blockPtr.count),
                                        &nativeResult
                                    )
                                )
                            }
                        }
                    }
                }
            }

            if nativeRC == 0 {
                for (blockSlot, (_, poolIndex)) in activeBlocks.enumerated() {
                    var block = volume.readBlock(at: poolIndex)
                    let base = blockSlot * voxelsPerBlock
                    for i in 0..<voxelsPerBlock {
                        block.voxels[i] = fromNativeVoxel(nativeVoxels[base + i])
                    }
                    block.integrationGeneration = nativeBlocks[blockSlot].integration_generation
                    block.meshGeneration = nativeBlocks[blockSlot].mesh_generation
                    block.lastObservedTimestamp = nativeBlocks[blockSlot].last_observed_timestamp
                    block.voxelSize = nativeBlocks[blockSlot].voxel_size
                    volume.writeBlock(at: poolIndex, block)
                }

                let totalTime = (ProcessInfo.processInfo.systemUptime - startTime) * 1000.0
                return IntegrationResult.IntegrationStats(
                    blocksUpdated: Int(nativeResult.blocks_updated),
                    blocksAllocated: 0,
                    voxelsUpdated: Int(nativeResult.voxels_integrated),
                    gpuTimeMs: totalTime,
                    totalTimeMs: totalTime
                )
            }
        }
        
        // Hard fail-closed: C++ core is the single integration semantic source.
        // If native integration fails, we do not keep a Swift-side voxel update path.
        return IntegrationResult.IntegrationStats(
            blocksUpdated: 0,
            blocksAllocated: 0,
            voxelsUpdated: 0,
            gpuTimeMs: 0,
            totalTimeMs: (ProcessInfo.processInfo.systemUptime - startTime) * 1000.0
        )
    }

    private func toNativeVoxel(_ voxel: Voxel) -> aether_external_voxel_t {
        aether_external_voxel_t(
            sdf_bits: sdfBitPattern(voxel.sdf),
            weight: voxel.weight,
            confidence: voxel.confidence
        )
    }

    private func fromNativeVoxel(_ voxel: aether_external_voxel_t) -> Voxel {
        Voxel(
            sdf: sdfFromBitPattern(voxel.sdf_bits),
            weight: voxel.weight,
            confidence: voxel.confidence
        )
    }

    private func sdfBitPattern(_ sdf: SDFStorage) -> UInt16 {
        #if canImport(simd) || arch(arm64)
        return sdf.bitPattern
        #else
        return sdf.bitPattern
        #endif
    }

    private func sdfFromBitPattern(_ bits: UInt16) -> SDFStorage {
        #if canImport(simd) || arch(arm64)
        return SDFStorage(bitPattern: bits)
        #else
        var value = SDFStorage(0)
        value.bitPattern = bits
        return value
        #endif
    }
}
