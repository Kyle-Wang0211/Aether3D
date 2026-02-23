// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// TSDFVolume.swift
// Aether3D
//
// Central TSDF volume manager — the heart of PR#6

import Foundation
#if canImport(simd)
import simd
#endif

/// Central TSDF volume manager — the heart of PR#6
///
/// Actor isolation ensures:
///   - hashTable is never accessed concurrently
///   - All mutations go through actor-isolated methods
///   - Metal dispatch is non-isolated (@concurrent) for GPU parallelism
///
/// Performance targets (A14 baseline):
///   - integrate(): < 2ms CPU dispatch + < 5ms GPU compute = < 7ms total
///   - extractMesh(): < 3ms for dirty blocks (incremental, P0 priority)
///
/// Memory targets:
///   - Idle: ~1 MB (hash table + empty pool metadata)
///   - Active room scan: ~100–200 MB (25K–50K blocks)
///   - Maximum: 400 MB (100K blocks, safety cap)
public actor TSDFVolume {
    private struct VolumeControlSnapshot {
        var shouldSkipFrame: Bool
        var integrationSkipRate: Int
        var shouldEvict: Bool
        var blocksToEvict: Int
        var shouldMarkKeyframe: Bool
        var blocksToPreallocate: Int
    }

    private var hashTable: SpatialHashTable
    private var integrationRecordRing: [IntegrationRecord]  // 300-frame ring buffer
    private var ringIndex: Int = 0
    private var frameCount: UInt64 = 0
    private var lastIntegratedTimestamp: TimeInterval = 0
    private var lastCameraPose: TSDFMatrix4x4?

    /// Backend for depth-to-voxel computation (injected, see Section 0.6).
    /// CPU backend for tests/fallback, Metal backend for production.
    private let backend: TSDFIntegrationBackend
    private let nativeRuntimeBridge: NativeTSDFRuntimeBridge?
    private let nativeVolumeController = NativeVolumeControllerBridge()
    private var nativeDepthFilter: NativeDepthFilter?
    private var depthFilterResolution: (width: Int, height: Int)?
    private let nativeColorCorrector = NativeColorCorrector()
    private var lastFrameDurationMs: Float = Float(TSDFConstants.integrationTimeoutMs)
    private var lastValidPixelCount: Int = 0
    private var lastTotalPixelCount: Int = 1
    private var lastControlQualityWeight: Float = 1.0

#if canImport(simd)
    private struct ICPCloudFrame {
        var points: [SIMD3<Float>]
        var normals: [SIMD3<Float>]
        var pose: TSDFMatrix4x4
        var timestamp: TimeInterval
    }

    private struct LoopKeyframe {
        var id: UInt32
        var pose: TSDFMatrix4x4
        var blockCodes: [UInt64]
        var timestamp: TimeInterval
    }

    private var lastICPCloudFrame: ICPCloudFrame?
    private var loopKeyframes: [LoopKeyframe] = []
    private var lastLoopScore: Float = 0.0
    private var lastICPResidual: Float = 0.0
#endif

    // Thermal AIMD state:
    //   systemThermalCeiling: max integration rate allowed by ProcessInfo.ThermalState
    //   currentIntegrationSkip: actual skip count (1=every frame, 2=every other, 4=every 4th)
    //   consecutiveGoodFrames: frames where GPU time < integrationTimeoutMs × 0.8
    //   lastThermalChangeTime: hysteresis timer (10s cooldown for system-driven changes)
    private var systemThermalCeiling: Int = 1       // skip count ceiling from system thermal state
    private var currentIntegrationSkip: Int = 1     // actual skip count (AIMD-managed)
    private var consecutiveGoodFrames: Int = 0
    private var lastThermalChangeTime: TimeInterval = 0
    
    // Guardrail #10: Pose teleport tracking
    private var consecutiveTeleportCount: Int = 0
    
    // Guardrail #11: Rotation speed tracking
    private var lastAngularVelocity: Float = 0.0
    
    // Guardrail #12: Consecutive rejections tracking
    private var consecutiveRejections: Int = 0
    
    // UX-9: Congestion control state for mesh extraction
    private var currentMaxBlocksPerExtraction: Int = TSDFConstants.maxBlocksPerExtraction
    private var consecutiveGoodMeshingCycles: Int = 0
    private var forgivenessWindowRemaining: Int = 0
    
    // UX-11: Motion tracking for mesh deferral
    private var recentCameraPoses: [TSDFMatrix4x4] = []  // Last 10 poses for velocity calculation
    private let maxPoseHistory: Int = 10
    
    // UX-12: Idle detection and preallocation
    private var lastIdleCheckTime: TimeInterval = 0
    
    // Memory pressure runtime mirror (C++ single source of truth for policy)
    private var memoryWaterLevel: Int = 0
    private var memoryPressureRatio: Float = 0
    private var lastMemoryPressureChangeTime: TimeInterval = 0
    private var freeBlockSlotCount: Int = 0
    private var lastEvictedBlocks: Int = 0

    public init(backend: TSDFIntegrationBackend) {
        self.backend = backend
        self.nativeRuntimeBridge = NativeTSDFRuntimeBridge()
        hashTable = SpatialHashTable()
        integrationRecordRing = Array(repeating: .empty, count: TSDFConstants.integrationRecordCapacity)
        nativeRuntimeBridge?.setRuntimeState(
            TSDFRuntimeStateSnapshot(
                frameCount: 0,
                hasLastPose: false,
                lastPose: Array(repeating: 0, count: 16),
                lastTimestamp: 0,
                systemThermalCeiling: 1,
                currentIntegrationSkip: 1,
                consecutiveGoodFrames: 0,
                consecutiveRejections: 0,
                lastThermalChangeTimeS: 0,
                hashTableSize: hashTable.count,
                hashTableCapacity: hashTable.tableCapacity,
                currentMaxBlocksPerExtraction: currentMaxBlocksPerExtraction,
                consecutiveGoodMeshingCycles: consecutiveGoodMeshingCycles,
                forgivenessWindowRemaining: forgivenessWindowRemaining,
                consecutiveTeleportCount: consecutiveTeleportCount,
                lastAngularVelocity: lastAngularVelocity,
                recentPoseCount: recentCameraPoses.count,
                lastIdleCheckTimeS: lastIdleCheckTime,
                memoryWaterLevel: memoryWaterLevel,
                memoryPressureRatio: memoryPressureRatio,
                lastMemoryPressureChangeTimeS: lastMemoryPressureChangeTime,
                freeBlockSlotCount: freeBlockSlotCount,
                lastEvictedBlocks: lastEvictedBlocks
            )
        )
    }

    /// Integrate a single depth frame into the volume.
    /// Called every frame (~60fps) from App/ layer.
    ///
    /// NOTE: Takes IntegrationInput (platform-agnostic) + DepthDataProvider (pixel access).
    /// App/ layer constructs IntegrationInput by unpacking SceneDepthFrame + ARCamera.
    /// TSDFVolume handles ALL gate checks and AIMD logic, then delegates pixel-level
    /// integration work to the injected backend (CPU or Metal).
    ///
    /// Returns IntegrationResult with statistics for telemetry.
    /// MUST be async — backend.processFrame() is async.
    public func integrate(
        input: IntegrationInput,
        depthData: DepthDataProvider
    ) async -> IntegrationResult {
        defer { syncNativeRuntimeState() }
        if let snapshot = nativeRuntimeBridge?.runtimeState() {
            applyNativeControlState(snapshot)
        }

        // Gate 1: Tracking state (Guardrail #9)
        guard input.trackingState == 2 else {
            consecutiveRejections += 1
            // Guardrail #12: Consecutive rejections tracking
            checkConsecutiveRejections()
            return .skipped(.trackingLost)
        }

        // Gate 2: Pose teleport detection (Guardrail #10)
        if let lastPose = lastCameraPose {
            let translation = tsdTranslation(input.cameraToWorld)
            let lastTranslation = tsdTranslation(lastPose)
            let delta = (translation - lastTranslation).length()
            guard delta < TSDFConstants.maxPoseDeltaPerFrame else {
                consecutiveTeleportCount += 1
                // Guardrail #10: 3 consecutive teleports → pause integration + toast
                if consecutiveTeleportCount >= 3 {
                    // Would trigger toast notification (App/ layer responsibility)
                    // For now, just skip frame
                }
                return .skipped(.poseTeleport)
            }
            consecutiveTeleportCount = 0
        }
        
        // Guardrail #11: Rotation speed check
        if let lastPose = lastCameraPose {
            let rotationDelta = calculateRotationDelta(from: lastPose, to: input.cameraToWorld)
            let timeDelta: Float = 1.0 / 60.0  // Assume 60fps
            let angularVelocity = Float(rotationDelta) / timeDelta
            
            if angularVelocity > TSDFConstants.maxAngularVelocity {
                // Guardrail #11: Skip frame, fire haptic (would be handled by App/ layer)
                return .skipped(.poseTeleport)  // Reuse skip reason
            }
            lastAngularVelocity = angularVelocity
        }

        // Gate 3: Pose jitter gate (UX-7) — skip if camera nearly still
        if let lastPose = lastCameraPose {
            let translation = tsdTranslation(input.cameraToWorld)
            let lastTranslation = tsdTranslation(lastPose)
            let translationDelta = (translation - lastTranslation).length()
            let rotationDelta = calculateRotationDelta(from: lastPose, to: input.cameraToWorld)
            
            guard translationDelta >= TSDFConstants.poseJitterGateTranslation ||
                  rotationDelta >= TSDFConstants.poseJitterGateRotation else {
                consecutiveRejections += 1
                checkConsecutiveRejections()
                return .skipped(.poseJitter)
            }
        }

        // Guardrail #3: Frame timeout check (start timing)
        let startTime = ProcessInfo.processInfo.systemUptime

        // Build a dense depth/confidence view once, then run native M10 filter.
        let pixelCount = depthData.width * depthData.height
        var depthBuffer = Array(repeating: Float.nan, count: pixelCount)
        var confidenceBuffer = Array(repeating: UInt8(0), count: pixelCount)
        if pixelCount > 0 {
            for y in 0..<depthData.height {
                for x in 0..<depthData.width {
                    let idx = y * depthData.width + x
                    depthBuffer[idx] = depthData.depthAt(x: x, y: y)
                    confidenceBuffer[idx] = depthData.confidenceAt(x: x, y: y)
                }
            }
        }
        if let filtered = runNativeDepthFilter(
            width: depthData.width,
            height: depthData.height,
            depthBuffer: depthBuffer,
            confidenceBuffer: confidenceBuffer
        ) {
            depthBuffer = filtered.depth
            confidenceBuffer = filtered.confidence
        }
        let workingDepthData = ArrayDepthData(
            width: depthData.width,
            height: depthData.height,
            depths: depthBuffer,
            confidences: confidenceBuffer
        )

        // Gate 5: Valid pixel ratio check (Guardrail #15)
        let totalPixels = max(1, pixelCount)
        var validPixels = 0
        for i in 0..<pixelCount {
            let depth = depthBuffer[i]
            if depth.isNaN || depth < TSDFConstants.depthMin || depth > TSDFConstants.depthMax {
                continue
            }
            if !TSDFConstants.skipLowConfidencePixels || confidenceBuffer[i] > 0 {
                validPixels += 1
            }
        }
        lastValidPixelCount = validPixels
        lastTotalPixelCount = totalPixels
        let validPixelRatio = Float(validPixels) / Float(totalPixels)
        guard validPixelRatio >= TSDFConstants.minValidPixelRatio else {
            consecutiveRejections += 1
            checkConsecutiveRejections()
            return .skipped(.lowValidPixels)
        }

        // Gate 4: C++ M04 volume controller (skip/evict/preallocate decisions).
        let controlSnapshot = resolveVolumeControl(
            trackingState: input.trackingState,
            validPixels: validPixels,
            totalPixels: totalPixels,
            timestamp: input.timestamp
        )
        if controlSnapshot.shouldSkipFrame {
            consecutiveRejections += 1
            checkConsecutiveRejections()
            return .skipped(.thermalThrottle)
        }

        // Conservative second gate: keep deterministic skip cadence even if runtime signal jitters.
        if frameCount % UInt64(currentIntegrationSkip) != 0 {
            consecutiveRejections += 1
            checkConsecutiveRejections()
            return .skipped(.thermalThrottle)
        }
        if controlSnapshot.shouldEvict && controlSnapshot.blocksToEvict > 0 {
            evictOldestBlocks(limit: controlSnapshot.blocksToEvict)
        }
        if controlSnapshot.blocksToPreallocate > 0 {
            preallocateAlongHeading(from: input.cameraToWorld, count: controlSnapshot.blocksToPreallocate)
        }

        var resolvedCameraPose = input.cameraToWorld
#if canImport(simd)
        if let refinedPose = refinePoseWithICP(
            depthData: workingDepthData,
            intrinsics: input.intrinsics,
            cameraToWorld: input.cameraToWorld,
            timestamp: input.timestamp
        ) {
            resolvedCameraPose = refinedPose
        }
#endif
        let resolvedInput = IntegrationInput(
            timestamp: input.timestamp,
            intrinsics: input.intrinsics,
            cameraToWorld: resolvedCameraPose,
            depthWidth: input.depthWidth,
            depthHeight: input.depthHeight,
            trackingState: input.trackingState
        )

        // Determine active blocks from filtered depth data.
        var blockSet = Set<BlockIndex>()

        // Build inverse intrinsics matrix for back-projection.
        let intrinsics = resolvedInput.intrinsics
        let fx = intrinsics.columns.0.x
        let fy = intrinsics.columns.1.y
        let cx = intrinsics.columns.2.x
        let cy = intrinsics.columns.2.y

        let invFx = 1.0 / fx
        let invFy = 1.0 / fy
        let invCx = -cx / fx
        let invCy = -cy / fy

        for y in 0..<workingDepthData.height {
            for x in 0..<workingDepthData.width {
                let depth = workingDepthData.depthAt(x: x, y: y)
                guard !depth.isNaN && depth >= TSDFConstants.depthMin && depth <= TSDFConstants.depthMax else {
                    continue
                }

                let confidence = workingDepthData.confidenceAt(x: x, y: y)
                if TSDFConstants.skipLowConfidencePixels && confidence == 0 {
                    continue
                }

                let u = Float(x)
                let v = Float(y)
                let pCam = TSDFFloat3(
                    (u * invFx + invCx) * depth,
                    (v * invFy + invCy) * depth,
                    depth
                )
                let pWorld = tsdTransform(resolvedInput.cameraToWorld, pCam)
                let voxelSize = AdaptiveResolution.voxelSize(forDepth: depth)
                let blockIdx = AdaptiveResolution.blockIndex(worldPosition: pWorld, voxelSize: voxelSize)
                blockSet.insert(blockIdx)
            }
        }
        
        // Allocate blocks in hash table (BUG-7: pass (BlockIndex, poolIndex) for correct pool index use)
        var activeBlocks: [(BlockIndex, Int)] = []
        for blockIdx in blockSet {
            if let poolIndex = hashTable.insertOrGet(key: blockIdx, voxelSize: AdaptiveResolution.voxelSize(forDepth: 1.0)) {
                activeBlocks.append((blockIdx, poolIndex))
            }
        }
        
        hashTable.rehashIfNeeded()

        // Reset consecutive rejections on successful integration
        consecutiveRejections = 0

        // Guardrail #4: Voxel block cap check
        if hashTable.count > TSDFConstants.maxTotalVoxelBlocks {
            // LRU eviction by lastObservedTimestamp
            // Simplified: evict oldest blocks
            let blocksToEvict = hashTable.getAllBlocks().sorted { blockIdx1, blockIdx2 in
                let block1 = hashTable.readBlock(at: blockIdx1.1)
                let block2 = hashTable.readBlock(at: blockIdx2.1)
                return block1.lastObservedTimestamp < block2.lastObservedTimestamp
            }
            for (blockIdx, _) in blocksToEvict.prefix(hashTable.count - TSDFConstants.maxTotalVoxelBlocks) {
                hashTable.remove(key: blockIdx)
            }
        }
        
        // Dispatch to backend
        let stats = await backend.processFrame(
            input: resolvedInput,
            depthData: workingDepthData,
            volume: hashTable.voxelAccessor,
            activeBlocks: activeBlocks
        )
        
        // Guardrail #3: Frame timeout check
        let totalTimeMs = (ProcessInfo.processInfo.systemUptime - startTime) * 1000.0
        lastFrameDurationMs = Float(totalTimeMs)
        if totalTimeMs > TSDFConstants.integrationTimeoutMs {
            // Skip frame, log (simplified - would log in production)
            return .skipped(.frameTimeout)
        }
        
        // Gate 5 check for Metal backend (validPixelCount from GPU)
        // Note: For Metal backend, this check should be done after CB1 completes
        // For now, we do it here for CPU backend. Metal backend should check validPixelCount
        // and return early if ratio is too low before CB2 dispatch.

        // Runtime feedback is core-authoritative: C++ policy kernel owns AIMD state.
        if let nativeRuntimeBridge {
            nativeRuntimeBridge.applyFrameFeedback(gpuTimeMs: stats.gpuTimeMs)
            if let snapshot = nativeRuntimeBridge.runtimeState() {
                applyNativeControlState(snapshot)
            }
        }

        // Update ring buffer with IntegrationRecord
        let isKeyframe = controlSnapshot.shouldMarkKeyframe || shouldMarkKeyframe(input: resolvedInput)
        let record = IntegrationRecord(
            timestamp: resolvedInput.timestamp,
            cameraPose: resolvedInput.cameraToWorld,
            intrinsics: resolvedInput.intrinsics,
            affectedBlockIndices: activeBlocks.map { Int32($0.0.x) }, // Simplified
            isKeyframe: isKeyframe,
            keyframeId: isKeyframe ? UInt32(truncatingIfNeeded: frameCount) : nil
        )
        integrationRecordRing[ringIndex] = record
        ringIndex = (ringIndex + 1) % TSDFConstants.integrationRecordCapacity
        lastIntegratedTimestamp = resolvedInput.timestamp

        lastCameraPose = resolvedInput.cameraToWorld
        frameCount += 1

        // Track camera pose history for UX-11 and UX-12
        recentCameraPoses.append(resolvedInput.cameraToWorld)
        if recentCameraPoses.count > maxPoseHistory {
            recentCameraPoses.removeFirst()
        }

#if canImport(simd)
        if isKeyframe {
            updateLoopClosureState(
                frameID: UInt32(truncatingIfNeeded: frameCount),
                pose: resolvedInput.cameraToWorld,
                timestamp: resolvedInput.timestamp,
                blockSet: blockSet
            )
        }
#endif
        
        // UX-12: Idle preallocation — predict blocks ahead of camera motion
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastIdleCheckTime > 0.1 {  // Check every 100ms
            lastIdleCheckTime = now
            
            // Check if camera is idle
            if recentCameraPoses.count >= 2 {
                let currentPose = recentCameraPoses.last!
                let previousPose = recentCameraPoses[recentCameraPoses.count - 2]
                
                let currentTranslation = tsdTranslation(currentPose)
                let previousTranslation = tsdTranslation(previousPose)
                let translationDelta = (currentTranslation - previousTranslation).length()
                
                let timeDelta: Float = 1.0 / 60.0
                let translationSpeed = translationDelta / timeDelta
                
                let rotationDelta = calculateRotationDelta(from: previousPose, to: currentPose)
                let angularSpeed = Float(rotationDelta) / timeDelta
                
                // UX-12: If idle, preallocate blocks along predicted motion vector
                if translationSpeed < TSDFConstants.idleTranslationSpeed &&
                   angularSpeed < TSDFConstants.idleAngularSpeed {
                    // Camera is idle - predict future blocks
                    if recentCameraPoses.count >= 3 {
                        // Compute velocity vector from last 3 poses
                        let pose1 = recentCameraPoses[recentCameraPoses.count - 3]
                        let pose2 = recentCameraPoses[recentCameraPoses.count - 2]
                        let pose3 = recentCameraPoses.last!
                        
                        let trans1 = tsdTranslation(pose1)
                        _ = tsdTranslation(pose2)
                        let trans3 = tsdTranslation(pose3)
                        
                        // Estimate velocity (simplified linear extrapolation)
                        let velocity = (trans3 - trans1) / Float(2.0 / 60.0)  // Approximate velocity
                        
                        // Preallocate blocks along predicted path (BUG-8: avoid division by zero when camera is still)
                        let lookAheadDistance = TSDFConstants.anticipatoryPreallocationDistance
                        let speed = velocity.length()
                        let predictedPosition: TSDFFloat3
                        if speed > 1e-6 {
                            predictedPosition = trans3 + velocity * (lookAheadDistance / speed)
                        } else {
                            predictedPosition = trans3
                        }
                        
                        // Estimate depth for voxel size selection
                        let estimatedDepth = predictedPosition.z
                        let voxelSize = AdaptiveResolution.voxelSize(forDepth: estimatedDepth)
                        let predictedBlockIdx = AdaptiveResolution.blockIndex(
                            worldPosition: predictedPosition,
                            voxelSize: voxelSize
                        )
                        
                        // Preallocate predicted block (if not already allocated)
                        _ = hashTable.insertOrGet(key: predictedBlockIdx, voxelSize: voxelSize)
                    }
                }
            }
        }

        return .success(stats)
    }

    /// Extract mesh from dirty blocks with priority ordering
    ///
    /// Priority = integrationGeneration - meshGeneration (higher = dirtier = higher priority)
    /// Budget: maxTrianglesPerCycle triangles per call
    ///
    /// IMPORTANT: When meshing a dirty block, also mesh its 6 face-adjacent neighbors.
    /// Marching Cubes samples voxels across block boundaries — without neighbor meshing,
    /// visible seam artifacts appear. (Reference: nvblox ICRA 2024)
    ///
    /// UX-11: Motion deferral — skip meshing if camera moving fast
    /// UX-9: Congestion control — adaptive block budget based on meshing time
    public func extractMesh() -> MeshOutput {
        let startTime = ProcessInfo.processInfo.systemUptime
        
        // UX-11: Check camera motion speed — defer meshing if moving fast
        if recentCameraPoses.count >= 2 {
            let currentPose = recentCameraPoses.last!
            let previousPose = recentCameraPoses[recentCameraPoses.count - 2]
            
            let currentTranslation = tsdTranslation(currentPose)
            let previousTranslation = tsdTranslation(previousPose)
            let translationDelta = (currentTranslation - previousTranslation).length()
            
            // Estimate time delta (simplified - would use actual timestamps)
            let timeDelta: Float = 1.0 / 60.0  // Assume 60fps
            let translationSpeed = translationDelta / timeDelta
            
            let rotationDelta = calculateRotationDelta(from: previousPose, to: currentPose)
            let angularSpeed = Float(rotationDelta) / timeDelta
            
            // UX-11: Defer meshing if moving too fast
            if translationSpeed > TSDFConstants.motionDeferTranslationSpeed ||
               angularSpeed > TSDFConstants.motionDeferAngularSpeed {
                // Return empty mesh - meshing deferred
                return MeshOutput()
            }
        }
        
        // UX-9: Use congestion-controlled block budget
        let maxTriangles = TSDFConstants.maxTrianglesPerCycle
        
        let extractionResult = MarchingCubesExtractor.extractIncrementalDetailed(
            hashTable: hashTable,
            maxTriangles: maxTriangles,
            maxBlocks: currentMaxBlocksPerExtraction
        )
        let output = extractionResult.output
        
        let meshExtractionTimeMs = (ProcessInfo.processInfo.systemUptime - startTime) * 1000.0
        
        // UX-9: Congestion control — adjust block budget based on meshing time
        if meshExtractionTimeMs > TSDFConstants.meshBudgetOverrunMs {
            // Multiplicative decrease: halve block budget
            currentMaxBlocksPerExtraction = max(
                currentMaxBlocksPerExtraction / 2,
                TSDFConstants.minBlocksPerExtraction
            )
            consecutiveGoodMeshingCycles = 0
            forgivenessWindowRemaining = TSDFConstants.forgivenessWindowCycles
        } else if meshExtractionTimeMs < TSDFConstants.meshBudgetGoodMs {
            // Good cycle
            consecutiveGoodMeshingCycles += 1
            
            if forgivenessWindowRemaining > 0 {
                forgivenessWindowRemaining -= 1
            } else if consecutiveGoodMeshingCycles >= TSDFConstants.consecutiveGoodCyclesBeforeRamp {
                // Additive increase: add blocks gradually
                currentMaxBlocksPerExtraction = min(
                    currentMaxBlocksPerExtraction + TSDFConstants.blockRampPerCycle,
                    TSDFConstants.maxBlocksPerExtraction
                )
                consecutiveGoodMeshingCycles = 0
            }
        } else {
            // Between good and overrun - reset streak
            consecutiveGoodMeshingCycles = 0
        }
        
        // Update meshGeneration for processed blocks using exact extraction output.
        for blockIdx in extractionResult.processedBlocks {
            if let poolIndex = hashTable.lookup(key: blockIdx) {
                hashTable.updateBlock(at: poolIndex) { block in
                    block.meshGeneration = block.integrationGeneration
                }
            }
        }
        
        return output
    }

    /// Query voxel at world position (for PR#5 evidence system)
    public func queryVoxel(at worldPosition: TSDFFloat3) -> Voxel? {
        // Estimate depth for voxel size selection (simplified)
        let estimatedDepth = worldPosition.z
        let voxelSize = AdaptiveResolution.voxelSize(forDepth: estimatedDepth)
        let blockIdx = AdaptiveResolution.blockIndex(worldPosition: worldPosition, voxelSize: voxelSize)
        
        guard let poolIndex = hashTable.lookup(key: blockIdx) else {
            return nil
        }
        
        let block = hashTable.readBlock(at: poolIndex)
        let blockWorldSize = voxelSize * Float(TSDFConstants.blockSize)
        let localPos = TSDFFloat3(
            worldPosition.x - Float(blockIdx.x) * blockWorldSize,
            worldPosition.y - Float(blockIdx.y) * blockWorldSize,
            worldPosition.z - Float(blockIdx.z) * blockWorldSize
        )
        
        let voxelLocalIdx = TSDFFloat3(
            localPos.x / voxelSize,
            localPos.y / voxelSize,
            localPos.z / voxelSize
        )
        
        let x = Int(max(0, min(7, voxelLocalIdx.x)))
        let y = Int(max(0, min(7, voxelLocalIdx.y)))
        let z = Int(max(0, min(7, voxelLocalIdx.z)))
        
        let voxelIndex = x * 64 + y * 8 + z
        guard voxelIndex < block.voxels.count else { return nil }
        
        return block.voxels[voxelIndex]
    }

    /// Memory pressure handler — tiered response
    /// Level 1 (warning): Evict stale blocks (lastObserved > 30s)
    /// Level 2 (critical): Evict all blocks > 3m from camera, reduce maxBlocks by 50%
    /// Level 3 (terminal): Evict all blocks except nearest 1m radius
    public func handleMemoryPressure(level: MemoryPressureLevel) {
        nativeRuntimeBridge?.applyMemoryPressure(level.rawValue)
        if let snapshot = nativeRuntimeBridge?.runtimeState() {
            applyNativeControlState(snapshot)
        }

        let now = ProcessInfo.processInfo.systemUptime
        let staleCutoff = now - TSDFConstants.staleBlockEvictionAge
        let cameraPos = lastCameraPose.map { tsdTranslation($0) }
        
        // Collect blocks to evict
        var blocksToEvict: [BlockIndex] = []
        
        switch level {
        case .warning:
            // Evict stale blocks (lastObserved > 30s)
            hashTable.forEachBlock { blockIdx, _, block in
                if block.lastObservedTimestamp <= 0 || block.lastObservedTimestamp < staleCutoff {
                    blocksToEvict.append(blockIdx)
                }
            }
            
        case .critical:
            // Evict all blocks > 3m from camera. If camera pose is unavailable, fallback to stale eviction.
            let distanceThreshold: Float = 3.0
            hashTable.forEachBlock { blockIdx, _, block in
                guard let cameraPos else {
                    if block.lastObservedTimestamp <= 0 || block.lastObservedTimestamp < staleCutoff {
                        blocksToEvict.append(blockIdx)
                    }
                    return
                }
                // Compute block center position
                let blockWorldSize = block.voxelSize * Float(TSDFConstants.blockSize)
                let blockCenter = TSDFFloat3(
                    Float(blockIdx.x) * blockWorldSize + blockWorldSize * 0.5,
                    Float(blockIdx.y) * blockWorldSize + blockWorldSize * 0.5,
                    Float(blockIdx.z) * blockWorldSize + blockWorldSize * 0.5
                )
                let distance = (blockCenter - cameraPos).length()
                if distance > distanceThreshold {
                    blocksToEvict.append(blockIdx)
                }
            }
            
        case .terminal:
            // Evict all blocks except nearest 1m radius.
            // If camera pose is unavailable, evict all blocks.
            let keepRadius: Float = 1.0
            hashTable.forEachBlock { blockIdx, _, block in
                guard let cameraPos else {
                    blocksToEvict.append(blockIdx)
                    return
                }
                // Compute block center position
                let blockWorldSize = block.voxelSize * Float(TSDFConstants.blockSize)
                let blockCenter = TSDFFloat3(
                    Float(blockIdx.x) * blockWorldSize + blockWorldSize * 0.5,
                    Float(blockIdx.y) * blockWorldSize + blockWorldSize * 0.5,
                    Float(blockIdx.z) * blockWorldSize + blockWorldSize * 0.5
                )
                let distance = (blockCenter - cameraPos).length()
                if distance > keepRadius {
                    blocksToEvict.append(blockIdx)
                }
            }
        }
        
        // Remove evicted blocks
        for blockIdx in blocksToEvict {
            hashTable.remove(key: blockIdx)
        }

        syncNativeRuntimeState()
    }

    /// Guardrail #12: Check consecutive rejections and trigger warnings
    private func checkConsecutiveRejections() {
        if consecutiveRejections >= TSDFConstants.poseRejectFailCount {
            // 180 frames: prominent warning overlay (rendering continues with stale mesh)
            // Would be handled by App/ layer
        } else if consecutiveRejections >= TSDFConstants.poseRejectWarningCount {
            // 30 frames: toast "Move slower"
            // Would be handled by App/ layer
        }
    }
    
    /// System thermal state changed — update the CEILING for AIMD
    ///
    /// Called by ScanViewModel when ProcessInfo.thermalStateDidChangeNotification fires.
    /// This sets the MAXIMUM integration rate (ceiling). The actual rate may be lower
    /// if GPU frame times are high (AIMD manages the actual skip count).
    ///
    /// State mapping (ProcessInfo.ThermalState.rawValue):
    ///   0 = .nominal → ceiling = 1  (every frame, 60fps)
    ///   1 = .fair    → ceiling = 2  (every 2nd frame, 30fps)
    ///   2 = .serious → ceiling = 4  (every 4th frame, 15fps)
    ///   3 = .critical→ ceiling = 12 (every 12th frame, 5fps)
    ///
    /// Hysteresis: 10s for degradation (ceiling increase), 5s for recovery (ceiling decrease).
    /// Asymmetric because recovery benefits the user immediately.
    public func handleThermalState(_ state: Int) {
        guard let nativeRuntimeBridge else {
            return
        }
        nativeRuntimeBridge.applyThermalState(state)
        if let snapshot = nativeRuntimeBridge.runtimeState() {
            applyNativeControlState(snapshot)
        }
        syncNativeRuntimeState()
    }

    /// Reset volume (new scan session)
    public func reset() {
        hashTable = SpatialHashTable()
        integrationRecordRing = Array(repeating: .empty, count: TSDFConstants.integrationRecordCapacity)
        ringIndex = 0
        frameCount = 0
        lastIntegratedTimestamp = 0
        lastCameraPose = nil
        systemThermalCeiling = 1
        currentIntegrationSkip = 1
        consecutiveGoodFrames = 0
        consecutiveRejections = 0
        consecutiveTeleportCount = 0
        lastAngularVelocity = 0
        currentMaxBlocksPerExtraction = TSDFConstants.maxBlocksPerExtraction
        consecutiveGoodMeshingCycles = 0
        forgivenessWindowRemaining = 0
        recentCameraPoses.removeAll(keepingCapacity: true)
        lastIdleCheckTime = 0
        lastThermalChangeTime = 0
        memoryWaterLevel = 0
        memoryPressureRatio = 0
        lastMemoryPressureChangeTime = 0
        freeBlockSlotCount = 0
        lastEvictedBlocks = 0
        nativeVolumeController.reset()
        nativeDepthFilter = nil
        depthFilterResolution = nil
        lastFrameDurationMs = Float(TSDFConstants.integrationTimeoutMs)
        lastValidPixelCount = 0
        lastTotalPixelCount = 1
        lastControlQualityWeight = 1
#if canImport(simd)
        lastICPCloudFrame = nil
        loopKeyframes.removeAll(keepingCapacity: true)
        lastLoopScore = 0
        lastICPResidual = 0
#endif
        nativeRuntimeBridge?.reset()
        syncNativeRuntimeState()
    }

    /// Snapshot of the C++ TSDF runtime state mirror.
    /// This is the migration bridge for iOS/Android/Harmony shared diagnostics.
    public func nativeRuntimeStateSnapshot() -> TSDFRuntimeStateSnapshot? {
        nativeRuntimeBridge?.runtimeState()
    }

    /// M12 entrypoint: cross-platform native color consistency correction.
    public func colorCorrectRGB(image: Data, width: Int, height: Int, rowBytes: Int) -> Data? {
        nativeColorCorrector.correctRGB(image: image, width: width, height: height, rowBytes: rowBytes)?.0
    }

    // MARK: - Private Helpers

    private func runNativeDepthFilter(
        width: Int,
        height: Int,
        depthBuffer: [Float],
        confidenceBuffer: [UInt8]
    ) -> (depth: [Float], confidence: [UInt8])? {
        guard width > 0, height > 0, depthBuffer.count == confidenceBuffer.count else {
            return nil
        }
        if nativeDepthFilter == nil ||
            depthFilterResolution?.width != width ||
            depthFilterResolution?.height != height {
            nativeDepthFilter = NativeDepthFilter(width: width, height: height)
            depthFilterResolution = (width, height)
        }
        guard let filter = nativeDepthFilter else {
            return nil
        }
        guard let output = filter.run(
            depthIn: depthBuffer,
            confidenceIn: confidenceBuffer,
            angularVelocity: lastAngularVelocity
        ) else {
            return nil
        }

        var adjustedConfidence = confidenceBuffer
        let noisePenalty = output.quality.noiseResidual > 0.02 ? 1 : 0
        let edgePenalty = output.quality.edgeRiskScore > 0.18 ? 1 : 0
        let confidencePenalty = UInt8(min(2, noisePenalty + edgePenalty))
        for i in 0..<adjustedConfidence.count {
            let depth = output.depth[i]
            if depth.isNaN || depth < TSDFConstants.depthMin || depth > TSDFConstants.depthMax {
                adjustedConfidence[i] = 0
                continue
            }
            if confidencePenalty > 0 {
                adjustedConfidence[i] = adjustedConfidence[i] > confidencePenalty
                    ? (adjustedConfidence[i] - confidencePenalty)
                    : 0
            }
        }
        return (output.depth, adjustedConfidence)
    }

    private func resolveVolumeControl(
        trackingState: Int,
        validPixels: Int,
        totalPixels: Int,
        timestamp: TimeInterval
    ) -> VolumeControlSnapshot {
        let thermalLevel = max(0, min(9, systemThermalCeiling - 1))
        let thermalHeadroom = max(0.0, min(1.0, 1.0 - Float(systemThermalCeiling - 1) / 11.0))
        guard let decision = nativeVolumeController.decide(
            NativeVolumeSignals(
                thermalLevel: thermalLevel,
                thermalHeadroom: thermalHeadroom,
                memoryWaterLevel: max(0, min(4, memoryWaterLevel)),
                trackingState: trackingState,
                angularVelocity: lastAngularVelocity,
                frameActualDurationMs: max(0.1, lastFrameDurationMs),
                validPixelCount: validPixels,
                totalPixelCount: max(1, totalPixels),
                timestampS: timestamp
            )
        ) else {
            return VolumeControlSnapshot(
                shouldSkipFrame: false,
                integrationSkipRate: max(1, currentIntegrationSkip),
                shouldEvict: false,
                blocksToEvict: 0,
                shouldMarkKeyframe: false,
                blocksToPreallocate: 0
            )
        }
        currentIntegrationSkip = max(1, decision.integrationSkipRate)
        lastControlQualityWeight = max(0.05, min(1.0, decision.qualityWeight))
        return VolumeControlSnapshot(
            shouldSkipFrame: decision.shouldSkipFrame,
            integrationSkipRate: decision.integrationSkipRate,
            shouldEvict: decision.shouldEvict,
            blocksToEvict: max(0, decision.blocksToEvict),
            shouldMarkKeyframe: decision.isKeyframe,
            blocksToPreallocate: max(0, decision.blocksToPreallocate)
        )
    }

    private func evictOldestBlocks(limit: Int) {
        guard limit > 0, hashTable.count > 0 else { return }
        let sorted = hashTable.getAllBlocks().sorted { lhs, rhs in
            let block1 = hashTable.readBlock(at: lhs.1)
            let block2 = hashTable.readBlock(at: rhs.1)
            return block1.lastObservedTimestamp < block2.lastObservedTimestamp
        }
        for (blockIdx, _) in sorted.prefix(limit) {
            hashTable.remove(key: blockIdx)
        }
    }

    private func preallocateAlongHeading(from cameraPose: TSDFMatrix4x4, count: Int) {
        guard count > 0 else { return }
        let origin = tsdTranslation(cameraPose)
        let forwardRaw = TSDFFloat3(cameraPose.columns.2.x, cameraPose.columns.2.y, cameraPose.columns.2.z)
        let forwardLength = forwardRaw.length()
        guard forwardLength > 1e-6 else { return }
        let forward = forwardRaw / forwardLength
        let clampedCount = min(count, 24)
        for step in 1...clampedCount {
            let predicted = origin + forward * (0.20 * Float(step))
            let estimatedDepth = max(0.1, predicted.z)
            let voxelSize = AdaptiveResolution.voxelSize(forDepth: estimatedDepth)
            let blockIdx = AdaptiveResolution.blockIndex(worldPosition: predicted, voxelSize: voxelSize)
            _ = hashTable.insertOrGet(key: blockIdx, voxelSize: voxelSize)
        }
    }

#if canImport(simd)
    private func refinePoseWithICP(
        depthData: ArrayDepthData,
        intrinsics: TSDFMatrix3x3,
        cameraToWorld: TSDFMatrix4x4,
        timestamp: TimeInterval
    ) -> TSDFMatrix4x4? {
        guard let currentCloud = buildICPCloud(
            depthData: depthData,
            intrinsics: intrinsics,
            cameraToWorld: cameraToWorld,
            timestamp: timestamp
        ) else {
            return nil
        }
        defer { lastICPCloudFrame = currentCloud }
        guard let previousCloud = lastICPCloudFrame else {
            return nil
        }
        if timestamp <= previousCloud.timestamp || (timestamp - previousCloud.timestamp) > 0.40 {
            return nil
        }

        let minPoints = 64
        guard currentCloud.points.count >= minPoints, previousCloud.points.count >= minPoints else {
            return nil
        }

        guard let icpResult = NativeICPRefiner.refine(
            sourcePoints: currentCloud.points,
            targetPoints: previousCloud.points,
            targetNormals: previousCloud.normals,
            initialPose: matrix_identity_float4x4,
            angularVelocity: lastAngularVelocity
        ) else {
            return nil
        }
        guard icpResult.converged,
              icpResult.correspondenceCount >= 48,
              icpResult.rmse <= 0.03 else {
            return nil
        }

        lastICPResidual = icpResult.rmse
        return icpResult.pose * cameraToWorld
    }

    private func buildICPCloud(
        depthData: ArrayDepthData,
        intrinsics: TSDFMatrix3x3,
        cameraToWorld: TSDFMatrix4x4,
        timestamp: TimeInterval
    ) -> ICPCloudFrame? {
        let width = depthData.width
        let height = depthData.height
        if width < 8 || height < 8 {
            return nil
        }
        let fx = intrinsics.columns.0.x
        let fy = intrinsics.columns.1.y
        let cx = intrinsics.columns.2.x
        let cy = intrinsics.columns.2.y
        if !fx.isFinite || !fy.isFinite || abs(fx) < 1e-6 || abs(fy) < 1e-6 {
            return nil
        }

        let sx = max(2, width / 80)
        let sy = max(2, height / 60)
        var points: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        points.reserveCapacity(512)
        normals.reserveCapacity(512)

        func pointAt(_ x: Int, _ y: Int) -> TSDFFloat3? {
            let d = depthData.depthAt(x: x, y: y)
            guard d.isFinite, d >= TSDFConstants.depthMin, d <= TSDFConstants.depthMax else {
                return nil
            }
            let xf = Float(x)
            let yf = Float(y)
            return TSDFFloat3(
                (xf - cx) * d / fx,
                (yf - cy) * d / fy,
                d
            )
        }

        var y = sy
        while y + sy < height {
            var x = sx
            while x + sx < width {
                guard let pCam = pointAt(x, y),
                      let pRightCam = pointAt(x + sx, y),
                      let pDownCam = pointAt(x, y + sy) else {
                    x += sx
                    continue
                }

                let nCamRaw = cross(pRightCam - pCam, pDownCam - pCam)
                let nCamLen = nCamRaw.length()
                if !(nCamLen > 1e-6) {
                    x += sx
                    continue
                }
                let nCam = nCamRaw / nCamLen
                let pWorld = tsdTransform(cameraToWorld, pCam)
                let nWorldTip = tsdTransform(cameraToWorld, pCam + nCam * 0.03)
                let nWorldRaw = nWorldTip - pWorld
                let nWorldLen = nWorldRaw.length()
                if !(nWorldLen > 1e-6) {
                    x += sx
                    continue
                }
                points.append(pWorld)
                normals.append(nWorldRaw / nWorldLen)
                x += sx
            }
            y += sy
        }

        if points.count < 64 {
            return nil
        }
        return ICPCloudFrame(points: points, normals: normals, pose: cameraToWorld, timestamp: timestamp)
    }

    private func updateLoopClosureState(
        frameID: UInt32,
        pose: TSDFMatrix4x4,
        timestamp: TimeInterval,
        blockSet: Set<BlockIndex>
    ) {
        let blockCodes = Array(Set(blockSet.map(packBlockIndex))).sorted()
        guard !blockCodes.isEmpty else { return }

        loopKeyframes.append(LoopKeyframe(
            id: frameID,
            pose: pose,
            blockCodes: blockCodes,
            timestamp: timestamp
        ))
        if loopKeyframes.count > 256 {
            loopKeyframes.removeFirst(loopKeyframes.count - 256)
        }
        guard loopKeyframes.count >= 8 else { return }

        let current = loopKeyframes[loopKeyframes.count - 1]
        var historyBlocks: [UInt64] = []
        historyBlocks.reserveCapacity(loopKeyframes.dropLast().reduce(0) { $0 + $1.blockCodes.count })
        var historyOffsets: [UInt32] = [0]
        var yawDeltas: [Float] = []
        var timeDeltas: [Float] = []
        yawDeltas.reserveCapacity(loopKeyframes.count - 1)
        timeDeltas.reserveCapacity(loopKeyframes.count - 1)

        for frame in loopKeyframes.dropLast() {
            historyBlocks.append(contentsOf: frame.blockCodes)
            historyOffsets.append(UInt32(historyBlocks.count))
            yawDeltas.append(calculateRotationDelta(from: frame.pose, to: current.pose))
            timeDeltas.append(Float(max(0, current.timestamp - frame.timestamp)))
        }
        guard historyOffsets.count >= 2 else { return }

        guard let candidate = NativeLoopDetector.detect(
            currentBlocks: current.blockCodes,
            historyBlocks: historyBlocks,
            historyOffsets: historyOffsets,
            skipRecent: 10,
            overlapThreshold: 0.18,
            yawDeltas: yawDeltas,
            timeDeltas: timeDeltas
        ) else {
            return
        }
        lastLoopScore = candidate.score
        if candidate.score < 0.20 || candidate.frameIndex < 0 || candidate.frameIndex >= loopKeyframes.count - 1 {
            return
        }

        var nodes = loopKeyframes.enumerated().map { index, frame in
            NativePoseGraphNode(id: UInt32(index), pose: frame.pose, fixed: index == 0)
        }
        var edges: [NativePoseGraphEdge] = []
        if loopKeyframes.count >= 2 {
            for i in 1..<loopKeyframes.count {
                guard let rel = relativePose(from: loopKeyframes[i - 1].pose, to: loopKeyframes[i].pose) else {
                    continue
                }
                edges.append(NativePoseGraphEdge(
                    fromId: UInt32(i - 1),
                    toId: UInt32(i),
                    transform: rel,
                    isLoop: false
                ))
            }
        }
        guard let loopRel = relativePose(
            from: loopKeyframes[candidate.frameIndex].pose,
            to: loopKeyframes[loopKeyframes.count - 1].pose
        ) else {
            return
        }
        edges.append(NativePoseGraphEdge(
            fromId: UInt32(candidate.frameIndex),
            toId: UInt32(loopKeyframes.count - 1),
            transform: loopRel,
            isLoop: true
        ))

        guard let result = NativePoseGraphOptimizer.optimize(nodes: &nodes, edges: edges),
              result.converged,
              result.finalError <= result.initialError * 1.05 else {
            return
        }

        for i in 0..<min(nodes.count, loopKeyframes.count) {
            loopKeyframes[i].pose = nodes[i].pose
        }
        if let optimizedCurrent = nodes.last?.pose {
            lastCameraPose = optimizedCurrent
            if !recentCameraPoses.isEmpty {
                recentCameraPoses[recentCameraPoses.count - 1] = optimizedCurrent
            }
        }
    }

    private func packBlockIndex(_ block: BlockIndex) -> UInt64 {
        let x = UInt32(bitPattern: Int32(truncatingIfNeeded: block.x))
        let y = UInt32(bitPattern: Int32(truncatingIfNeeded: block.y))
        let z = UInt32(bitPattern: Int32(truncatingIfNeeded: block.z))
        var h: UInt64 = 0xcbf29ce484222325
        h ^= UInt64(x)
        h &*= 0x100000001b3
        h ^= UInt64(y)
        h &*= 0x100000001b3
        h ^= UInt64(z)
        h &*= 0x100000001b3
        return h
    }

    private func relativePose(from: TSDFMatrix4x4, to: TSDFMatrix4x4) -> TSDFMatrix4x4? {
        guard let inv = tsdInverseRigidTransform(from) else {
            return nil
        }
        return inv * to
    }
#endif

    private func applyNativeControlState(_ snapshot: TSDFRuntimeStateSnapshot) {
        frameCount = snapshot.frameCount
        lastIntegratedTimestamp = max(0, snapshot.lastTimestamp)
        lastCameraPose = snapshot.hasLastPose ? poseFromFlattened(snapshot.lastPose) : nil
        systemThermalCeiling = max(1, snapshot.systemThermalCeiling)
        currentIntegrationSkip = max(1, snapshot.currentIntegrationSkip)
        consecutiveGoodFrames = max(0, snapshot.consecutiveGoodFrames)
        consecutiveRejections = max(0, snapshot.consecutiveRejections)
        lastThermalChangeTime = max(0, snapshot.lastThermalChangeTimeS)
        currentMaxBlocksPerExtraction = min(
            TSDFConstants.maxBlocksPerExtraction,
            max(TSDFConstants.minBlocksPerExtraction, snapshot.currentMaxBlocksPerExtraction)
        )
        consecutiveGoodMeshingCycles = max(0, snapshot.consecutiveGoodMeshingCycles)
        forgivenessWindowRemaining = max(0, snapshot.forgivenessWindowRemaining)
        consecutiveTeleportCount = max(0, snapshot.consecutiveTeleportCount)
        lastAngularVelocity = max(0, snapshot.lastAngularVelocity)
        let cappedRecentPoseCount = max(0, min(snapshot.recentPoseCount, maxPoseHistory))
        if cappedRecentPoseCount == 0 {
            recentCameraPoses.removeAll(keepingCapacity: true)
        } else if recentCameraPoses.count > cappedRecentPoseCount {
            recentCameraPoses = Array(recentCameraPoses.suffix(cappedRecentPoseCount))
        }
        lastIdleCheckTime = max(0, snapshot.lastIdleCheckTimeS)
        memoryWaterLevel = min(4, max(0, snapshot.memoryWaterLevel))
        memoryPressureRatio = min(1.5, max(0, snapshot.memoryPressureRatio))
        lastMemoryPressureChangeTime = max(0, snapshot.lastMemoryPressureChangeTimeS)
        freeBlockSlotCount = max(0, snapshot.freeBlockSlotCount)
        lastEvictedBlocks = max(0, snapshot.lastEvictedBlocks)
    }

    private func syncNativeRuntimeState() {
        guard let nativeRuntimeBridge else { return }
        let snapshot = TSDFRuntimeStateSnapshot(
            frameCount: frameCount,
            hasLastPose: lastCameraPose != nil,
            lastPose: flattenedPose(lastCameraPose),
            lastTimestamp: lastIntegratedTimestamp,
            systemThermalCeiling: systemThermalCeiling,
            currentIntegrationSkip: currentIntegrationSkip,
            consecutiveGoodFrames: consecutiveGoodFrames,
            consecutiveRejections: consecutiveRejections,
            lastThermalChangeTimeS: lastThermalChangeTime,
            hashTableSize: hashTable.count,
            hashTableCapacity: hashTable.tableCapacity,
            currentMaxBlocksPerExtraction: currentMaxBlocksPerExtraction,
            consecutiveGoodMeshingCycles: consecutiveGoodMeshingCycles,
            forgivenessWindowRemaining: forgivenessWindowRemaining,
            consecutiveTeleportCount: consecutiveTeleportCount,
            lastAngularVelocity: lastAngularVelocity,
            recentPoseCount: recentCameraPoses.count,
            lastIdleCheckTimeS: lastIdleCheckTime,
            memoryWaterLevel: memoryWaterLevel,
            memoryPressureRatio: memoryPressureRatio,
            lastMemoryPressureChangeTimeS: lastMemoryPressureChangeTime,
            freeBlockSlotCount: freeBlockSlotCount,
            lastEvictedBlocks: lastEvictedBlocks
        )
        nativeRuntimeBridge.setRuntimeState(snapshot)
    }

    private func poseFromFlattened(_ values: [Float]) -> TSDFMatrix4x4? {
        guard values.count == 16 else { return nil }
        return TSDFMatrix4x4(
            SIMD4<Float>(values[0], values[1], values[2], values[3]),
            SIMD4<Float>(values[4], values[5], values[6], values[7]),
            SIMD4<Float>(values[8], values[9], values[10], values[11]),
            SIMD4<Float>(values[12], values[13], values[14], values[15])
        )
    }

    private func flattenedPose(_ pose: TSDFMatrix4x4?) -> [Float] {
        guard let pose else {
            return Array(repeating: 0, count: 16)
        }
        let c0 = pose.columns.0
        let c1 = pose.columns.1
        let c2 = pose.columns.2
        let c3 = pose.columns.3
        return [
            c0.x, c0.y, c0.z, c0.w,
            c1.x, c1.y, c1.z, c1.w,
            c2.x, c2.y, c2.z, c2.w,
            c3.x, c3.y, c3.z, c3.w,
        ]
    }

    private func calculateRotationDelta(from: TSDFMatrix4x4, to: TSDFMatrix4x4) -> Float {
        // Extract rotation matrices (3x3 upper-left)
        let r0 = TSDFFloat3(from.columns.0.x, from.columns.0.y, from.columns.0.z)
        let r1 = TSDFFloat3(from.columns.1.x, from.columns.1.y, from.columns.1.z)
        let r2 = TSDFFloat3(from.columns.2.x, from.columns.2.y, from.columns.2.z)
        
        let r0_new = TSDFFloat3(to.columns.0.x, to.columns.0.y, to.columns.0.z)
        let r1_new = TSDFFloat3(to.columns.1.x, to.columns.1.y, to.columns.1.z)
        let r2_new = TSDFFloat3(to.columns.2.x, to.columns.2.y, to.columns.2.z)
        
        // Compute relative rotation matrix: R_rel = R_new * R_old^T
        // Simplified: use trace to get rotation angle
        // trace(R) = 1 + 2*cos(θ) for rotation matrix
        let trace = dot(r0, r0_new) + dot(r1, r1_new) + dot(r2, r2_new)
        let cosAngle = max(-1.0, min(1.0, (trace - 1.0) / 2.0))
        let angle = acos(cosAngle)
        
        return angle
    }

    private func shouldMarkKeyframe(input: IntegrationInput) -> Bool {
        // Check interval-based trigger
        if frameCount % UInt64(TSDFConstants.keyframeInterval) == 0 {
            return true
        }
        
        // Check angular/translation triggers
        guard let lastPose = lastCameraPose else { return false }
        
        let translation = tsdTranslation(input.cameraToWorld)
        let lastTranslation = tsdTranslation(lastPose)
        let translationDelta = (translation - lastTranslation).length()
        
        if translationDelta >= TSDFConstants.keyframeTranslationTrigger {
            return true
        }
        
        let rotationDelta = calculateRotationDelta(from: lastPose, to: input.cameraToWorld)
        let rotationDeltaDeg = rotationDelta * 180.0 / Float.pi
        
        if rotationDeltaDeg >= TSDFConstants.keyframeAngularTriggerDeg {
            return true
        }
        
        return false
    }
}
