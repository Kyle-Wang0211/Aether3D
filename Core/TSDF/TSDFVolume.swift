// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// TSDFVolume.swift
// Aether3D
//
// Central TSDF volume manager — the heart of PR#6

import Foundation

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
    private var hashTable: SpatialHashTable
    private var integrationRecordRing: [IntegrationRecord]  // 300-frame ring buffer
    private var ringIndex: Int = 0
    private var frameCount: UInt64 = 0
    private var lastCameraPose: TSDFMatrix4x4?

    /// Backend for depth-to-voxel computation (injected, see Section 0.6).
    /// CPU backend for tests/fallback, Metal backend for production.
    private let backend: TSDFIntegrationBackend

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

    public init(backend: TSDFIntegrationBackend) {
        self.backend = backend
        hashTable = SpatialHashTable()
        integrationRecordRing = Array(repeating: .empty, count: TSDFConstants.integrationRecordCapacity)
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

        // Gate 4: Thermal AIMD skip — frameCount % currentIntegrationSkip != 0 → skip
        if frameCount % UInt64(currentIntegrationSkip) != 0 {
            consecutiveRejections += 1
            checkConsecutiveRejections()
            return .skipped(.thermalThrottle)
        }

        // Guardrail #3: Frame timeout check (start timing)
        let startTime = ProcessInfo.processInfo.systemUptime
        
        // Determine active blocks from depth data
        // Collect unique block indices that need to be allocated/updated
        var blockSet = Set<BlockIndex>()
        
        // Build inverse intrinsics matrix for back-projection
        let intrinsics = input.intrinsics
        // Inverse of 3x3 intrinsics matrix (simplified - assumes standard form)
        let fx = intrinsics.columns.0.x
        let fy = intrinsics.columns.1.y
        let cx = intrinsics.columns.2.x
        let cy = intrinsics.columns.2.y
        
        // Inverse intrinsics (for back-projection)
        let invFx = 1.0 / fx
        let invFy = 1.0 / fy
        let invCx = -cx / fx
        let invCy = -cy / fy
        
        // Collect block indices from depth pixels
        for y in 0..<depthData.height {
            for x in 0..<depthData.width {
                let depth = depthData.depthAt(x: x, y: y)
                guard !depth.isNaN && depth >= TSDFConstants.depthMin && depth <= TSDFConstants.depthMax else {
                    continue
                }
                
                let confidence = depthData.confidenceAt(x: x, y: y)
                if TSDFConstants.skipLowConfidencePixels && confidence == 0 {
                    continue
                }
                
                // Back-project to camera space
                let u = Float(x)
                let v = Float(y)
                let p_cam = TSDFFloat3(
                    (u * invFx + invCx) * depth,
                    (v * invFy + invCy) * depth,
                    depth
                )
                
                // Transform to world space
                let p_world = tsdTransform(input.cameraToWorld, p_cam)
                
                // Select voxel size and compute block index
                let voxelSize = AdaptiveResolution.voxelSize(forDepth: depth)
                let blockIdx = AdaptiveResolution.blockIndex(worldPosition: p_world, voxelSize: voxelSize)
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

        // Gate 5: Valid pixel ratio check (Guardrail #15)
        // This is checked AFTER GPU allocation pass (validPixelCount is computed by GPU)
        // For CPU backend, we compute it here
        let totalPixels = depthData.width * depthData.height
        var validPixels = 0
        for y in 0..<depthData.height {
            for x in 0..<depthData.width {
                let depth = depthData.depthAt(x: x, y: y)
                if !depth.isNaN && depth >= TSDFConstants.depthMin && depth <= TSDFConstants.depthMax {
                    let confidence = depthData.confidenceAt(x: x, y: y)
                    if !TSDFConstants.skipLowConfidencePixels || confidence > 0 {
                        validPixels += 1
                    }
                }
            }
        }
        let validPixelRatio = Float(validPixels) / Float(totalPixels)
        guard validPixelRatio >= TSDFConstants.minValidPixelRatio else {
            consecutiveRejections += 1
            checkConsecutiveRejections()
            return .skipped(.lowValidPixels)
        }
        
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
            input: input,
            depthData: depthData,
            volume: hashTable.voxelAccessor,
            activeBlocks: activeBlocks
        )
        
        // Guardrail #3: Frame timeout check
        let totalTimeMs = (ProcessInfo.processInfo.systemUptime - startTime) * 1000.0
        if totalTimeMs > TSDFConstants.integrationTimeoutMs {
            // Skip frame, log (simplified - would log in production)
            return .skipped(.frameTimeout)
        }
        
        // Gate 5 check for Metal backend (validPixelCount from GPU)
        // Note: For Metal backend, this check should be done after CB1 completes
        // For now, we do it here for CPU backend. Metal backend should check validPixelCount
        // and return early if ratio is too low before CB2 dispatch.

        // AIMD feedback: if stats.gpuTimeMs < integrationTimeoutMs × 0.8
        let goodFrameThreshold = TSDFConstants.integrationTimeoutMs * Double(TSDFConstants.thermalGoodFrameRatio)
        if stats.gpuTimeMs < goodFrameThreshold {
            consecutiveGoodFrames += 1
            if consecutiveGoodFrames >= TSDFConstants.thermalRecoverGoodFrames {
                // Additive increase: reduce skip by 1
                if currentIntegrationSkip > 1 {
                    currentIntegrationSkip -= 1
                    consecutiveGoodFrames = 0
                }
            }
        } else {
            // Multiplicative decrease: double skip
            consecutiveGoodFrames = 0
            currentIntegrationSkip = min(currentIntegrationSkip * 2, systemThermalCeiling, TSDFConstants.thermalMaxIntegrationSkip)
        }

        // Update ring buffer with IntegrationRecord
        let record = IntegrationRecord(
            timestamp: input.timestamp,
            cameraPose: input.cameraToWorld,
            intrinsics: input.intrinsics,
            affectedBlockIndices: activeBlocks.map { Int32($0.0.x) }, // Simplified
            isKeyframe: shouldMarkKeyframe(input: input),
            keyframeId: nil // TODO: Generate keyframe ID
        )
        integrationRecordRing[ringIndex] = record
        ringIndex = (ringIndex + 1) % TSDFConstants.integrationRecordCapacity

        lastCameraPose = input.cameraToWorld
        frameCount += 1
        
        // Track camera pose history for UX-11 and UX-12
        recentCameraPoses.append(input.cameraToWorld)
        if recentCameraPoses.count > maxPoseHistory {
            recentCameraPoses.removeFirst()
        }
        
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
                        let trans2 = tsdTranslation(pose2)
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
        
        let output = MarchingCubesExtractor.extractIncremental(
            hashTable: hashTable,
            maxTriangles: maxTriangles
        )
        
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
        
        // Update meshGeneration for processed blocks
        // Get processed blocks and update their meshGeneration
        let processedBlocks = MarchingCubesExtractor.getProcessedBlocks(
            hashTable: hashTable,
            maxTriangles: maxTriangles
        )
        
        for blockIdx in processedBlocks {
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
        guard let cameraPos = lastCameraPose.map({ tsdTranslation($0) }) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        
        // Collect blocks to evict
        var blocksToEvict: [BlockIndex] = []
        
        switch level {
        case .warning:
            // Evict stale blocks (lastObserved > 30s)
            let staleThreshold = now - TSDFConstants.staleBlockEvictionAge
            hashTable.forEachBlock { blockIdx, _, block in
                if block.lastObservedTimestamp > 0 && (now - block.lastObservedTimestamp) > staleThreshold {
                    blocksToEvict.append(blockIdx)
                }
            }
            
        case .critical:
            // Evict all blocks > 3m from camera
            let distanceThreshold: Float = 3.0
            hashTable.forEachBlock { blockIdx, _, block in
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
            // Evict all blocks except nearest 1m radius
            let keepRadius: Float = 1.0
            hashTable.forEachBlock { blockIdx, _, block in
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
        let targetCeiling: Int
        switch state {
        case 0: targetCeiling = 1
        case 1: targetCeiling = 2
        case 2: targetCeiling = 4
        case 3: targetCeiling = 12
        default: targetCeiling = 2
        }

        let now = ProcessInfo.processInfo.systemUptime
        let hysteresis = targetCeiling > systemThermalCeiling
            ? TSDFConstants.thermalDegradeHysteresisS     // 10s to degrade (conservative)
            : TSDFConstants.thermalRecoverHysteresisS     // 5s to recover (responsive)

        if (now - lastThermalChangeTime) > hysteresis {
            let oldCeiling = systemThermalCeiling
            systemThermalCeiling = targetCeiling

            if targetCeiling > oldCeiling {
                // Thermal WORSENED (ceiling increased = more aggressive skipping).
                // Force skip UP to at least the new ceiling immediately.
                // AIMD will NOT auto-recover past this ceiling.
                currentIntegrationSkip = max(currentIntegrationSkip, targetCeiling)
            } else {
                // Thermal IMPROVED (ceiling decreased = less skipping allowed).
                // Clamp skip DOWN to new ceiling. AIMD may further decrease within ceiling.
                currentIntegrationSkip = min(currentIntegrationSkip, targetCeiling)
            }

            lastThermalChangeTime = now
            consecutiveGoodFrames = 0
        }
    }

    /// Reset volume (new scan session)
    public func reset() {
        hashTable = SpatialHashTable()
        integrationRecordRing = Array(repeating: .empty, count: TSDFConstants.integrationRecordCapacity)
        ringIndex = 0
        frameCount = 0
        lastCameraPose = nil
        systemThermalCeiling = 1
        currentIntegrationSkip = 1
        consecutiveGoodFrames = 0
        lastThermalChangeTime = 0
    }

    // MARK: - Private Helpers

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
