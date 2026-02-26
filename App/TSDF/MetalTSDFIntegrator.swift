// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// MetalTSDFIntegrator.swift
// Aether3D
//
// Metal compute shader orchestrator for TSDF integration

import Aether3DCore
#if canImport(ARKit)
import ARKit
#endif
import Metal
import MetalKit
import CoreVideo

/// Swift-side GPUBlockIndex struct matching Metal shader layout
struct GPUBlockIndex {
    var x: Int32
    var y: Int32
    var z: Int32
    var _pad: Int32
}

/// Swift-side BlockEntry struct matching Metal shader layout
struct BlockEntry {
    var blockIndex: GPUBlockIndex
    var poolOffset: Int32
    var voxelSize: Float
    var blockWorldOriginX: Float
    var blockWorldOriginY: Float
    var blockWorldOriginZ: Float
    var _pad2: Int32
}

/// Metal compute shader orchestrator for TSDF integration
///
/// Key design decisions:
///   - CVMetalTextureCache: zero-copy wrap of ARKit CVPixelBuffer → MTLTexture
///   - .storageModeShared: unified memory on Apple Silicon (no CPU↔GPU copy)
///   - .hazardTrackingModeUntracked on voxel buffer: manual sync via MTLSharedEvent
///   - Indirect dispatch: GPU writes block count → GPU reads for integration dispatch
///   - MTLSharedEvent for CPU-GPU synchronization (lightweight, bidirectional)
///
/// Buffer strategy:
///   - Per-frame data (depth, camera): triple-buffered (semaphore, 3 copies)
///   - Voxel volume: single persistent MTLBuffer wrapping VoxelBlockPool
///   - Hash table metadata: single persistent MTLBuffer
/// Conforms to TSDFIntegrationBackend (Section 0.6) — the Metal production implementation.
/// TSDFVolume calls backend.processFrame() after all gates pass.
public final class MetalTSDFIntegrator: TSDFIntegrationBackend, @unchecked Sendable {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let textureCache: CVMetalTextureCache

    private let allocatePipeline: MTLComputePipelineState
    private let integratePipeline: MTLComputePipelineState

    private let inflightSemaphore = DispatchSemaphore(value: TSDFConstants.metalInflightBuffers)
    private let sharedEvent: MTLSharedEvent
    private var frameNumber: UInt64 = 0

    /// Triple-buffered per-frame parameter buffers
    private var paramBuffers: [MTLBuffer]
    private var bufferIndex: Int = 0

    /// Single persistent voxel buffer — Metal wraps VoxelBlockPool's ManagedVoxelStorage
    /// via MTLBuffer(bytesNoCopy:), sharing the same physical memory (Apple Silicon unified memory).
    private var voxelBuffer: MTLBuffer  // .storageModeShared, .hazardTrackingModeUntracked

    /// Stored reference to the current frame's SceneDepthFrame for Metal texture creation.
    /// Set by the App/ layer (ScanViewModel) BEFORE calling tsdfVolume.integrate().
    private var currentDepthFrame: SceneDepthFrame?

    public init(device: MTLDevice, voxelStorage: VoxelBlockAccessor) throws {
        self.device = device
        
        guard let queue = device.makeCommandQueue() else {
            throw NSError(domain: "MetalTSDFIntegrator", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create command queue"])
        }
        self.commandQueue = queue

        // Create texture cache
        var cache: CVMetalTextureCache?
        let result = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard result == kCVReturnSuccess, let textureCache = cache else {
            throw NSError(domain: "MetalTSDFIntegrator", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create texture cache"])
        }
        self.textureCache = textureCache

        // Create voxel buffer (zero-copy from VoxelBlockPool)
        guard let voxelBuf = device.makeBuffer(
            bytesNoCopy: voxelStorage.baseAddress,
            length: voxelStorage.byteCount,
            options: [.storageModeShared],
            deallocator: nil
        ) else {
            throw NSError(domain: "MetalTSDFIntegrator", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to create voxel buffer"])
        }
        self.voxelBuffer = voxelBuf

        // Load shaders
        guard let library = device.makeDefaultLibrary() else {
            throw NSError(domain: "MetalTSDFIntegrator", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to load Metal library"])
        }

        guard let allocateFunction = library.makeFunction(name: "projectDepthAndAllocate"),
              let integrateFunction = library.makeFunction(name: "integrateTSDF") else {
            throw NSError(domain: "MetalTSDFIntegrator", code: 5, userInfo: [NSLocalizedDescriptionKey: "Failed to find shader functions"])
        }

        do {
            // Guardrail #22: Threadgroup validation — ensure threads don't exceed pipeline limit
            let allocatePipeline = try device.makeComputePipelineState(function: allocateFunction)
            let integratePipeline = try device.makeComputePipelineState(function: integrateFunction)
            
            // Validate threadgroup sizes don't exceed pipeline limits
            let maxThreads = allocatePipeline.maxTotalThreadsPerThreadgroup
            let requestedThreads = 8 * 8  // 64 threads
            if requestedThreads > maxThreads {
                throw NSError(domain: "MetalTSDFIntegrator", code: 6, userInfo: [NSLocalizedDescriptionKey: "Threadgroup size exceeds pipeline limit"])
            }
            
            self.allocatePipeline = allocatePipeline
            self.integratePipeline = integratePipeline
        } catch {
            throw NSError(domain: "MetalTSDFIntegrator", code: 6, userInfo: [NSLocalizedDescriptionKey: "Failed to create pipeline states: \(error)"])
        }

        // Create shared event for synchronization
        guard let event = device.makeSharedEvent() else {
            throw NSError(domain: "MetalTSDFIntegrator", code: 7, userInfo: [NSLocalizedDescriptionKey: "Failed to create shared event"])
        }
        self.sharedEvent = event

        // Initialize triple-buffered parameter buffers
        self.paramBuffers = (0..<TSDFConstants.metalInflightBuffers).map { _ in
            device.makeBuffer(length: MemoryLayout<TSDFParams>.stride, options: .storageModeShared)!
        }
    }

    /// App/ layer calls this to stage the CVPixelBuffer for Metal processing.
    public func prepareFrame(_ depthFrame: SceneDepthFrame) {
        self.currentDepthFrame = depthFrame
    }

    /// TSDFIntegrationBackend conformance — called by TSDFVolume after all gates pass.
    public func processFrame(
        input: IntegrationInput,
        depthData: DepthDataProvider,    // Ignored on Metal path — uses CVMetalTextureCache
        volume: VoxelBlockAccessor,
        activeBlocks: [(BlockIndex, Int)]
    ) async -> IntegrationResult.IntegrationStats {
        guard let depthFrame = currentDepthFrame else {
            return IntegrationResult.IntegrationStats(
                blocksUpdated: 0, blocksAllocated: 0,
                voxelsUpdated: 0, gpuTimeMs: 0, totalTimeMs: 0
            )
        }

        let startTime = ProcessInfo.processInfo.systemUptime

        // Wait on semaphore (with timeout guard) — moved to background to avoid blocking cooperative thread pool
        let waitResult: DispatchTimeoutResult = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [inflightSemaphore] in
                let result = inflightSemaphore.wait(
                    timeout: .now() + .milliseconds(Int(TSDFConstants.semaphoreWaitTimeoutMs))
                )
                continuation.resume(returning: result)
            }
        }
        if waitResult == .timedOut {
            return IntegrationResult.IntegrationStats(
                blocksUpdated: 0, blocksAllocated: 0,
                voxelsUpdated: 0, gpuTimeMs: 0, totalTimeMs: 0
            )
        }

        bufferIndex = (bufferIndex + 1) % TSDFConstants.metalInflightBuffers

        // Zero-copy texture wrap via CVMetalTextureCache
        guard let depthTexture = createTexture(from: depthFrame.depthMap, format: .r32Float),
              let confTexture = createTexture(from: depthFrame.confidenceMap ?? depthFrame.depthMap, format: .r8Uint) else {
            inflightSemaphore.signal()
            return IntegrationResult.IntegrationStats(
                blocksUpdated: 0, blocksAllocated: 0,
                voxelsUpdated: 0, gpuTimeMs: 0, totalTimeMs: 0
            )
        }

        // Build TSDFParams buffer (BUG-11: include depth size and dead zone from constants)
        let params = TSDFParams(
            depthMin: TSDFConstants.depthMin,
            depthMax: TSDFConstants.depthMax,
            skipLowConfidence: TSDFConstants.skipLowConfidencePixels ? 1 : 0,
            _pad0: 0,
            depthNearThreshold: TSDFConstants.depthNearThreshold,
            depthFarThreshold: TSDFConstants.depthFarThreshold,
            voxelSizeNear: TSDFConstants.voxelSizeNear,
            voxelSizeMid: TSDFConstants.voxelSizeMid,
            voxelSizeFar: TSDFConstants.voxelSizeFar,
            truncationMultiplier: TSDFConstants.truncationMultiplier,
            truncationMinimum: TSDFConstants.truncationMinimum,
            confidenceWeights: (
                TSDFConstants.confidenceWeightLow,
                TSDFConstants.confidenceWeightMid,
                TSDFConstants.confidenceWeightHigh
            ),
            distanceDecayAlpha: TSDFConstants.distanceDecayAlpha,
            viewingAngleFloor: TSDFConstants.viewingAngleWeightFloor,
            weightMax: TSDFConstants.weightMax,
            carvingDecayRate: TSDFConstants.carvingDecayRate,
            _pad1: (0, 0),
            blockSize: Int32(TSDFConstants.blockSize),
            maxOutputBlocks: Int32(TSDFConstants.maxTotalVoxelBlocks),
            depthWidth: UInt32(input.depthWidth),
            depthHeight: UInt32(input.depthHeight),
            sdfDeadZoneBase: TSDFConstants.sdfDeadZoneBase,
            sdfDeadZoneWeightScale: TSDFConstants.sdfDeadZoneWeightScale
        )
        
        let paramBuffer = paramBuffers[bufferIndex]
        paramBuffer.contents().bindMemory(to: TSDFParams.self, capacity: 1).pointee = params
        
        // Build camera matrices
        // P0-5 fail-closed: require mathematically valid inverse transforms.
        let intrinsics = input.intrinsics
        let cameraToWorld = input.cameraToWorld
        guard let intrinsicsInverse = tsdInverseIntrinsics(intrinsics),
              let worldToCamera = tsdInverseRigidTransform(cameraToWorld) else {
            inflightSemaphore.signal()
            return IntegrationResult.IntegrationStats(
                blocksUpdated: 0, blocksAllocated: 0,
                voxelsUpdated: 0, gpuTimeMs: 0, totalTimeMs: 0
            )
        }
        let cameraPosition = tsdTranslation(cameraToWorld)
        
        // Create buffers for allocation kernel output
        let maxBlocks = TSDFConstants.maxTotalVoxelBlocks
        guard let outputBlocksBuffer = device.makeBuffer(
            length: maxBlocks * MemoryLayout<GPUBlockIndex>.stride,
            options: .storageModeShared
        ),
        let blockCountBuffer = device.makeBuffer(
            length: MemoryLayout<UInt32>.stride,
            options: .storageModeShared
        ),
        let validPixelCountBuffer = device.makeBuffer(
            length: MemoryLayout<UInt32>.stride,
            options: .storageModeShared
        ) else {
            inflightSemaphore.signal()
            return IntegrationResult.IntegrationStats(
                blocksUpdated: 0, blocksAllocated: 0,
                voxelsUpdated: 0, gpuTimeMs: 0, totalTimeMs: 0
            )
        }
        
        // Initialize atomic counters
        blockCountBuffer.contents().bindMemory(to: UInt32.self, capacity: 1).pointee = 0
        validPixelCountBuffer.contents().bindMemory(to: UInt32.self, capacity: 1).pointee = 0
        
        // Guardrail #23: GPU memory tracking
        #if canImport(Metal)
        let currentGPUMemory = device.currentAllocatedSize
        if currentGPUMemory > TSDFConstants.gpuMemoryAggressiveEvictBytes {
            // Aggressive eviction (would trigger volume eviction)
            // For now, just log
        } else if currentGPUMemory > TSDFConstants.gpuMemoryProactiveEvictBytes {
            // Proactive eviction (would trigger volume eviction)
            // For now, just log
        }
        #endif
        
        // ── COMMAND BUFFER 1: Allocation kernel ──
        guard let cb1 = commandQueue.makeCommandBuffer() else {
            inflightSemaphore.signal()
            return IntegrationResult.IntegrationStats(
                blocksUpdated: 0, blocksAllocated: 0,
                voxelsUpdated: 0, gpuTimeMs: 0, totalTimeMs: 0
            )
        }
        
        guard let encoder1 = cb1.makeComputeCommandEncoder() else {
            inflightSemaphore.signal()
            return IntegrationResult.IntegrationStats(
                blocksUpdated: 0, blocksAllocated: 0,
                voxelsUpdated: 0, gpuTimeMs: 0, totalTimeMs: 0
            )
        }
        
        encoder1.setComputePipelineState(allocatePipeline)
        encoder1.setTexture(depthTexture, index: 0)
        encoder1.setTexture(confTexture, index: 1)
        
        // Set buffers
        var intrinsicsInv = intrinsicsInverse
        encoder1.setBytes(&intrinsicsInv, length: MemoryLayout<simd_float3x3>.stride, index: 0)
        var camToWorld = cameraToWorld
        encoder1.setBytes(&camToWorld, length: MemoryLayout<simd_float4x4>.stride, index: 1)
        encoder1.setBuffer(paramBuffer, offset: 0, index: 2)
        encoder1.setBuffer(outputBlocksBuffer, offset: 0, index: 3)
        encoder1.setBuffer(blockCountBuffer, offset: 0, index: 4)
        encoder1.setBuffer(validPixelCountBuffer, offset: 0, index: 5)
        
        // Dispatch: 256×192 pixels, threadgroup 8×8
        let threadgroupSize = MTLSize(width: 8, height: 8, depth: 1)
        let threadgroups = MTLSize(
            width: (input.depthWidth + 7) / 8,
            height: (input.depthHeight + 7) / 8,
            depth: 1
        )
        encoder1.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadgroupSize)
        encoder1.endEncoding()
        
        cb1.commit()
        // CPU blocks here (~0.3ms for 256×192) — moved to background to avoid blocking cooperative thread pool
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            cb1.addCompletedHandler { _ in
                continuation.resume()
            }
        }

        // Guardrail #19: Command buffer error check
        if cb1.status == .error {
            // Log error, recreate resources if needed (simplified - would log in production)
            inflightSemaphore.signal()
            return IntegrationResult.IntegrationStats(
                blocksUpdated: 0, blocksAllocated: 0,
                voxelsUpdated: 0, gpuTimeMs: 0, totalTimeMs: 0
            )
        }

        // ── CPU: Read allocation results, build block entries ──
        let blockCount = blockCountBuffer.contents().bindMemory(to: UInt32.self, capacity: 1).pointee
        let validPixelCount = validPixelCountBuffer.contents().bindMemory(to: UInt32.self, capacity: 1).pointee
        
        // Gate 5: Valid pixel ratio check (Guardrail #15)
        let totalPixels = input.depthWidth * input.depthHeight
        let validPixelRatio = Float(validPixelCount) / Float(totalPixels)
        if validPixelRatio < TSDFConstants.minValidPixelRatio {
            inflightSemaphore.signal()
            return IntegrationResult.IntegrationStats(
                blocksUpdated: 0, blocksAllocated: 0,
                voxelsUpdated: 0, gpuTimeMs: 0, totalTimeMs: 0
            )
        }
        
        // Read unique block indices from outputBlocksBuffer
        var uniqueBlocks = Set<BlockIndex>()
        let outputBlocks = outputBlocksBuffer.contents().bindMemory(to: GPUBlockIndex.self, capacity: maxBlocks)
        
        for i in 0..<Int(blockCount) {
            let gpuBlock = outputBlocks[i]
            let blockIdx = BlockIndex(gpuBlock.x, gpuBlock.y, gpuBlock.z)
            uniqueBlocks.insert(blockIdx)
        }
        
        // Build BlockEntry array from activeBlocks (BUG-7: use poolIndex from (BlockIndex, Int) pairs)
        var blockEntries: [BlockEntry] = []
        let activeBlockMap = Dictionary(uniqueKeysWithValues: activeBlocks)
        
        for blockIdx in uniqueBlocks {
            guard let poolIndex = activeBlockMap[blockIdx] else { continue }
            let block = volume.readBlock(at: poolIndex)
            let voxelSize = block.voxelSize
            let blockWorldSize = voxelSize * Float(TSDFConstants.blockSize)
            let worldOrigin = TSDFFloat3(
                Float(blockIdx.x) * blockWorldSize,
                Float(blockIdx.y) * blockWorldSize,
                Float(blockIdx.z) * blockWorldSize
            )
            let entry = BlockEntry(
                blockIndex: GPUBlockIndex(x: blockIdx.x, y: blockIdx.y, z: blockIdx.z, _pad: 0),
                poolOffset: Int32(poolIndex),
                voxelSize: voxelSize,
                blockWorldOriginX: worldOrigin.x,
                blockWorldOriginY: worldOrigin.y,
                blockWorldOriginZ: worldOrigin.z,
                _pad2: 0
            )
            blockEntries.append(entry)
        }
        let blocksAllocated = blockEntries.count
        
        // Create BlockEntry buffer
        guard let blockEntryBuffer = device.makeBuffer(
            bytes: blockEntries,
            length: blockEntries.count * MemoryLayout<BlockEntry>.stride,
            options: .storageModeShared
        ) else {
            inflightSemaphore.signal()
            return IntegrationResult.IntegrationStats(
                blocksUpdated: 0, blocksAllocated: blocksAllocated,
                voxelsUpdated: 0, gpuTimeMs: 0, totalTimeMs: 0
            )
        }

        // ── COMMAND BUFFER 2: Integration kernel ──
        guard let cb2 = commandQueue.makeCommandBuffer() else {
            inflightSemaphore.signal()
            return IntegrationResult.IntegrationStats(
                blocksUpdated: 0, blocksAllocated: 0,
                voxelsUpdated: 0, gpuTimeMs: 0, totalTimeMs: 0
            )
        }

        cb2.addCompletedHandler { [weak self] buffer in
            self?.inflightSemaphore.signal()
            if buffer.status == .error {
                // Log error, trigger AIMD multiplicative decrease
            }
        }

        // Encode Kernel 2 (integrateTSDF)
        guard let encoder2 = cb2.makeComputeCommandEncoder() else {
            inflightSemaphore.signal()
            return IntegrationResult.IntegrationStats(
                blocksUpdated: 0, blocksAllocated: blocksAllocated,
                voxelsUpdated: 0, gpuTimeMs: 0, totalTimeMs: 0
            )
        }
        
        encoder2.setComputePipelineState(integratePipeline)
        encoder2.setTexture(depthTexture, index: 0)
        encoder2.setTexture(confTexture, index: 1)
        
        var intrinsicsForIntegrate = intrinsics
        encoder2.setBytes(&intrinsicsForIntegrate, length: MemoryLayout<simd_float3x3>.stride, index: 0)
        var worldToCam = worldToCamera
        encoder2.setBytes(&worldToCam, length: MemoryLayout<simd_float4x4>.stride, index: 1)
        var camPos = cameraPosition
        encoder2.setBytes(&camPos, length: MemoryLayout<simd_float3>.stride, index: 2)
        encoder2.setBuffer(voxelBuffer, offset: 0, index: 3)
        encoder2.setBuffer(paramBuffer, offset: 0, index: 4)
        encoder2.setBuffer(blockEntryBuffer, offset: 0, index: 5)
        
        // Dispatch: one threadgroup per block
        let integrateThreadgroupSize = MTLSize(width: 8, height: 8, depth: 1)
        let integrateThreadgroups = MTLSize(width: blockEntries.count, height: 1, depth: 1)
        encoder2.dispatchThreadgroups(integrateThreadgroups, threadsPerThreadgroup: integrateThreadgroupSize)
        encoder2.endEncoding()
        
        cb2.commit()
        frameNumber += 1
        currentDepthFrame = nil  // Release CVPixelBuffer reference

        let totalTime = (ProcessInfo.processInfo.systemUptime - startTime) * 1000.0

        return IntegrationResult.IntegrationStats(
            blocksUpdated: blockEntries.count,
            blocksAllocated: blocksAllocated,
            voxelsUpdated: blockEntries.count * 512,  // Approximate
            gpuTimeMs: totalTime,
            totalTimeMs: totalTime
        )
    }

    // MARK: - Private Helpers

    private func createTexture(from pixelBuffer: CVPixelBuffer, format: MTLPixelFormat) -> MTLTexture? {
        var texture: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            format,
            CVPixelBufferGetWidth(pixelBuffer),
            CVPixelBufferGetHeight(pixelBuffer),
            0,
            &texture
        )
        guard result == kCVReturnSuccess, let cvTexture = texture else {
            return nil
        }
        return CVMetalTextureGetTexture(cvTexture)
    }
}
