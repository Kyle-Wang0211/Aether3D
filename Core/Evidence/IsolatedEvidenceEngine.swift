// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// IsolatedEvidenceEngine.swift
// Aether3D
//
// PR2 Patch V4 - Isolated Evidence Engine (Actor Model)
// Single-writer concurrency model with immutable snapshots
//

import Foundation

/// Evidence system thread model
///
/// ACTORS:
/// 1. EvidenceActor - owns all mutable state, single writer
/// 2. ReaderSnapshot - immutable snapshots for reading
///
/// INVARIANTS:
/// - All mutations go through EvidenceActor
/// - Readers receive immutable snapshots
/// - No shared mutable state
@globalActor
public actor EvidenceActor {
    public static let shared = EvidenceActor()
    private init() {}
}

/// Evidence engine with actor isolation
@EvidenceActor
public final class IsolatedEvidenceEngine {
    
    // MARK: - State (isolated to actor)
    
    private var splitLedger: SplitLedger
    private var gateDisplay: Double = 0.0
    private var softDisplay: Double = 0.0
    private var aggregator: BucketedAmortizedAggregator
    private var patchDisplay: PatchDisplayMap
    private var gateDeltaTracker: AsymmetricDeltaTracker
    private var softDeltaTracker: AsymmetricDeltaTracker

    // Runtime audit sampling state (Phase 14 automatic signal bridge)
    private var auditObservationCount: Int = 0
    private var auditTriTetBoundCount: Int = 0
    private var auditTriTetMerkleBoundCount: Int = 0
    private var auditReplaySampleCount: Int = 0
    private var auditReplayStableCount: Int = 0
    private var lastCoverageScore: Double = 0.0
    private var lastPersistentPizRegionCount: Int = 0
    private var lastOcclusionExcludedAreaRatio: Double = 0.0
    private var lastCaptureMotionScore: Double = 0.0
    private var lastCaptureOverexposureRatio: Double = 0.0
    private var lastCaptureUnderexposureRatio: Double = 0.0
    private var lastCaptureHasLargeBlownRegion: Bool = false

    
    // MARK: - PR3 Gate Quality Computer
    
    /// Gate quality computer (PR3)
    /// Computes gateQuality from view coverage, geometry, and basic quality metrics
    private let gateComputer: GateQualityComputer
    
    // MARK: - PR6 Evidence Grid Components
    
    /// Evidence grid (PR6)
    private var evidenceGrid: EvidenceGrid?
    
    /// Multi-ledger (PR6)
    private var multiLedger: MultiLedger?
    
    /// Coverage estimator (PR6)
    private var coverageEstimator: CoverageEstimator?
    
    /// PIZ grid analyzer (PR6)
    private var pizGridAnalyzer: PIZGridAnalyzer?
    
    /// PIZ occlusion filter (PR6)
    private var pizOcclusionFilter: PIZOcclusionFilter?
    
    /// State machine (PR6)
    private var stateMachine: EvidenceStateMachine?
    
    // MARK: - Initialization
    
    public init() {
        self.splitLedger = SplitLedger()
        self.aggregator = BucketedAmortizedAggregator()
        self.patchDisplay = PatchDisplayMap()
        self.gateDeltaTracker = AsymmetricDeltaTracker()
        self.softDeltaTracker = AsymmetricDeltaTracker()
        self.gateComputer = GateQualityComputer()
    }
    
    // MARK: - Processing (isolated to actor)
    
    /// Process observation (isolated to actor)
    public func processObservation(
        _ observation: EvidenceObservation,
        gateQuality: Double,
        softQuality: Double,
        verdict: ObservationVerdict
    ) {
        // All mutations happen here, on actor
        
        // Update split ledger
        splitLedger.update(
            observation: observation,
            gateQuality: gateQuality,
            softQuality: softQuality,
            verdict: verdict,
            frameId: observation.frameId,
            timestamp: observation.timestamp
        )

        auditObservationCount += 1
        if let triTetMetadata = observation.triTetMetadata {
            if !triTetMetadata.triTetBindingDigest.isEmpty {
                auditTriTetBoundCount += 1
            }
            if !triTetMetadata.triTetBindingDigest.isEmpty && !triTetMetadata.crossValidationReasonCode.isEmpty {
                auditTriTetMerkleBoundCount += 1
            }
        }

        
        // Compute patch evidence with dynamic weights
        let currentProgress = aggregator.totalEvidence
        let patchEvidence = splitLedger.patchEvidence(
            for: observation.patchId,
            currentProgress: currentProgress
        )
        
        // Update patch display (monotonic)
        let isLocked = splitLedger.gateLedger.entry(for: observation.patchId)?.isLocked ?? false
        let timestampMs = Int64(observation.timestamp * 1000.0)
        patchDisplay.update(
            patchId: observation.patchId,
            target: patchEvidence,
            timestampMs: timestampMs,
            isLocked: isLocked
        )
        
        // Update aggregator
        let entry = splitLedger.gateLedger.entry(for: observation.patchId)
        let weight = PatchWeightComputer.computeWeight(
            observationCount: entry?.observationCount ?? 0,
            lastUpdate: observation.timestamp,
            currentTime: observation.timestamp,
            viewDiversityScore: 1.0  // Will be computed from ViewDiversityTracker
        )
        
        aggregator.updatePatch(
            patchId: observation.patchId,
            evidence: patchEvidence,
            baseWeight: weight,
            timestamp: observation.timestamp
        )
        
        // Update displays with EMA
        let emaAlpha = EvidenceConstants.patchDisplayAlpha
        let smoothedGate = emaAlpha * gateQuality + (1 - emaAlpha) * gateDisplay
        let smoothedSoft = emaAlpha * softQuality + (1 - emaAlpha) * softDisplay
        
        // Store previous values BEFORE update (Rule D)
        let prevGateDisplay = gateDisplay
        let prevSoftDisplay = softDisplay
        
        // Update display (monotonic)
        gateDisplay = max(gateDisplay, smoothedGate)
        softDisplay = max(softDisplay, smoothedSoft)
        
        // Update delta trackers (Rule D: computed BEFORE update)
        gateDeltaTracker.update(newDelta: gateDisplay - prevGateDisplay)
        softDeltaTracker.update(newDelta: softDisplay - prevSoftDisplay)
    }
    
    /// Get immutable snapshot for reading
    public func snapshot() -> EvidenceSnapshot {
        return EvidenceSnapshot(
            gateDisplay: gateDisplay,
            softDisplay: softDisplay,
            totalEvidence: aggregator.totalEvidence,
            gateDelta: gateDeltaTracker.smoothed,
            softDelta: softDeltaTracker.smoothed
        )
    }
    
    /// **Rule ID:** PR6_GRID_ENGINE_001
    /// Process frame with Evidence Grid (PR6 extension)
    ///
    /// This method:
    /// 1. Calls existing processObservation() (unchanged)
    /// 2. Runs PR6 post-processing (collected to batch)
    /// 3. Applies batch: await evidenceGrid.apply(batch)
    ///
    /// - Parameters:
    ///   - observation: Evidence observation
    ///   - gateQuality: Gate quality
    ///   - softQuality: Soft quality (from dimensional evidence)
    ///   - verdict: Observation verdict
    ///   - dimensionalScores: Dimensional scores (PR6)
    ///   - worldPosition: World position for grid quantization
    public func processFrameWithGrid(
        observation: EvidenceObservation,
        gateQuality: Double,
        softQuality: Double,
        verdict: ObservationVerdict,
        dimensionalScores: DimensionalScoreSet? = nil,
        worldPosition: EvidenceVector3? = nil
    ) async {
        // Step 1: Call existing processObservation() (unchanged)
        processObservation(
            observation,
            gateQuality: gateQuality,
            softQuality: softQuality,
            verdict: verdict
        )
        
        // Step 2: Initialize PR6 components if needed
        if evidenceGrid == nil {
            let cellSize = GridResolutionPolicy.recommendedCaptureFloor(for: .standard)
            evidenceGrid = EvidenceGrid(cellSize: cellSize)
            multiLedger = MultiLedger()
            coverageEstimator = CoverageEstimator()
            pizGridAnalyzer = PIZGridAnalyzer()
            pizOcclusionFilter = PIZOcclusionFilter()
            stateMachine = EvidenceStateMachine()
        }
        
        guard let grid = evidenceGrid,
              let ledger = multiLedger,
              let estimator = coverageEstimator,
              let analyzer = pizGridAnalyzer,
              let filter = pizOcclusionFilter,
              let machine = stateMachine else {
            return
        }
        
        // Step 3: Create batch for PR6 updates
        var batch = EvidenceGrid.EvidenceGridDeltaBatch(maxCapacity: EvidenceConstants.batchMaxCapacity)
        
        // Step 4: PR6 post-processing (collect to batch)
        // DimensionalComputer → EvidenceGrid.update (add to batch)
        if let worldPos = worldPosition, let dimScores = dimensionalScores {
            // Create spatial key from world position
            let quantizer = SpatialQuantizer(cellSize: grid.quantizer.cellSize)
            let mortonCode = quantizer.mortonCode(from: worldPos)
            let key = SpatialKey(mortonCode: mortonCode, level: .L3)  // Default level
            
            // Create grid cell
            let quantizedPos = quantizer.quantize(worldPos)
            let cell = GridCell(
                patchId: observation.patchId,
                quantizedPosition: quantizedPos,
                dimScores: dimScores,
                dsMass: DSMassFusion.fromDeltaMultiplier(verdict.deltaMultiplier),
                level: .L3,
                directionalMask: 0,  // Will be computed from view direction
                lastUpdatedMillis: MonotonicClock.nowMs()
            )
            
            batch.add(.insert(key: key, cell: cell))
        }
        
        // MultiLedger.update* (add to batch)
        ledger.updateCore(
            observation: observation,
            gateQuality: gateQuality,
            softQuality: softQuality,
            verdict: verdict,
            frameId: observation.frameId,
            timestamp: observation.timestamp
        )
        
        // Step 5: Apply batch (single await)
        grid.apply(batch)
        
        // Step 6: CoverageEstimator.update (async)
        let coverageResult = await estimator.update(grid: grid)
        
        // Step 7: PIZGridAnalyzer.update (async)
        let pizRegions = await analyzer.update(grid: grid)
        
        // Step 8: PIZOcclusionFilter.update
        let filteredRegions = filter.filter(regions: pizRegions)

        lastCoverageScore = coverageResult.coveragePercentage
        lastPersistentPizRegionCount = filteredRegions.count
        let totalAreaRatio = pizRegions.reduce(0.0) { $0 + max(0.0, $1.areaRatio) }
        let filteredAreaRatio = filteredRegions.reduce(0.0) { $0 + max(0.0, $1.areaRatio) }
        if totalAreaRatio > 0 {
            let excluded = max(0.0, totalAreaRatio - filteredAreaRatio) / totalAreaRatio
            lastOcclusionExcludedAreaRatio = max(0.0, min(1.0, excluded))
        } else {
            lastOcclusionExcludedAreaRatio = 0.0
        }

        
        // Step 9: EvidenceStateMachine.evaluate (6-gate info-theoretic S5 certification)
        let snapshotForStateMachine = EvidenceState(
            patches: [:],
            gateDisplay: gateDisplay,
            softDisplay: softDisplay,
            lastTotalDisplay: aggregator.totalEvidence,
            exportedAtMs: Int64(observation.timestamp * 1000.0),
            dimensionalSnapshots: nil,
            coveragePercentage: coverageResult.coveragePercentage,
            stateMachineState: machine.getCurrentState(),
            pizRegionCount: filteredRegions.count
        )
        _ = machine.evaluate(
            coverage: coverageResult,
            pizRegions: filteredRegions,
            evidenceSnapshot: snapshotForStateMachine,
            dimensionalScores: dimensionalScores
        )
        
        // State is stored in stateMachine, can be retrieved via snapshot()
    }
    
    /// Export state as JSON Data
    /// - Parameter timestampMs: Optional fixed timestamp for determinism (defaults to current time)
    public func exportStateJSON(timestampMs: Int64? = nil) throws -> Data {
        let state = EvidenceState(
            patches: splitLedger.exportPatches(),
            gateDisplay: gateDisplay,
            softDisplay: softDisplay,
            lastTotalDisplay: aggregator.totalEvidence,
            exportedAtMs: timestampMs ?? Int64(Date().timeIntervalSince1970 * 1000)
        )
        return try TrueDeterministicJSONEncoder.encodeEvidenceState(state)
    }
    
    /// Load state from JSON Data
    public func loadStateJSON(_ data: Data) throws {
        let state = try JSONDecoder().decode(EvidenceState.self, from: data)
        
        // Validate schema version
        guard EvidenceState.isCompatible(version: state.schemaVersion) else {
            throw EvidenceError.incompatibleSchemaVersion(
                expected: EvidenceState.currentSchemaVersion,
                found: state.schemaVersion
            )
        }
        
        // Apply state
        // Note: SplitLedger patches are loaded implicitly through processObservation calls
        // For now, we only restore display state
        gateDisplay = state.gateDisplay
        softDisplay = state.softDisplay
        
        // Reset aggregator (will be recalibrated on next update)
        aggregator = BucketedAmortizedAggregator()
    }
    
    /// Reset for new session
    public func reset() {
        splitLedger = SplitLedger()
        aggregator = BucketedAmortizedAggregator()
        patchDisplay = PatchDisplayMap()
        gateDisplay = 0.0
        softDisplay = 0.0
        gateDeltaTracker.reset()
        softDeltaTracker.reset()
        gateComputer.reset()
        
        // Reset PR6 components
        evidenceGrid?.reset()
        multiLedger = MultiLedger()
        coverageEstimator?.reset()
        pizGridAnalyzer = PIZGridAnalyzer()
        pizOcclusionFilter?.reset()
        stateMachine?.reset()

        auditObservationCount = 0
        auditTriTetBoundCount = 0
        auditTriTetMerkleBoundCount = 0
        auditReplaySampleCount = 0
        auditReplayStableCount = 0
        lastCoverageScore = 0.0
        lastPersistentPizRegionCount = 0
        lastOcclusionExcludedAreaRatio = 0.0
        lastCaptureMotionScore = 0.0
        lastCaptureOverexposureRatio = 0.0
        lastCaptureUnderexposureRatio = 0.0
        lastCaptureHasLargeBlownRegion = false
        EvidenceInvariantMonitor.shared.reset()
    }
    
    // MARK: - PR3 Gate Processing
    
    /// Process frame with automatic gate quality computation (PR3)
    ///
    /// This is a convenience method that computes gateQuality automatically
    /// from frame metrics and camera/patch positions.
    ///
    /// NOTE: This does NOT modify the existing processObservation() method.
    /// It is a new API for PR3 integration.
    ///
    /// - Parameters:
    ///   - observation: Evidence observation
    ///   - cameraPosition: Camera position in world space (EvidenceVector3)
    ///   - patchPosition: Patch center position in world space (EvidenceVector3)
    ///   - reprojRmsPx: Reprojection RMS error (pixels)
    ///   - edgeRmsPx: Edge reprojection RMS error (pixels)
    ///   - sharpness: Sharpness score (0-100)
    ///   - overexposureRatio: Overexposed pixel ratio (0-1)
    ///   - underexposureRatio: Underexposed pixel ratio (0-1)
    ///   - motionScore: Motion severity score (0-1)
    ///   - hasLargeBlownRegion: True when frame has a large blown highlight area
    ///   - frameIndex: Frame index (for deterministic eviction)
    ///   - softQuality: Soft quality score (defaults to 0.0 when unavailable)
    ///   - verdict: Observation verdict
    public func processFrameWithGate(
        observation: EvidenceObservation,
        cameraPosition: EvidenceVector3,
        patchPosition: EvidenceVector3,
        reprojRmsPx: Double,
        edgeRmsPx: Double,
        sharpness: Double,
        overexposureRatio: Double,
        underexposureRatio: Double,
        motionScore: Double = 0.0,
        hasLargeBlownRegion: Bool = false,
        frameIndex: Int,
        softQuality: Double = 0.0,
        verdict: ObservationVerdict
    ) {
        lastCaptureMotionScore = max(0.0, min(1.0, motionScore))
        lastCaptureOverexposureRatio = max(0.0, min(1.0, overexposureRatio))
        lastCaptureUnderexposureRatio = max(0.0, min(1.0, underexposureRatio))
        lastCaptureHasLargeBlownRegion = hasLargeBlownRegion

        // Compute direction vector (from camera to patch)
        let direction = (patchPosition - cameraPosition).normalized()
        
        // Compute gate quality using GateQualityComputer
        let gateQuality = gateComputer.computeGateQuality(
            patchId: observation.patchId,
            direction: direction,
            reprojRmsPx: reprojRmsPx,
            edgeRmsPx: edgeRmsPx,
            sharpness: sharpness,
            overexposureRatio: overexposureRatio,
            underexposureRatio: underexposureRatio,
            frameIndex: frameIndex
        )
        
        // Process with computed gate quality
        processObservation(
            observation,
            gateQuality: gateQuality,
            softQuality: softQuality,
            verdict: verdict
        )
    }

    /// Record runtime replay outcome for stable-rate sampling.
    public func recordReplayValidation(stable: Bool) {
        auditReplaySampleCount += 1
        if stable {
            auditReplayStableCount += 1
        }
    }

    /// Snapshot capture-side signals for PureVision runtime audit input.
    public func runtimeAuditCaptureSignals() -> GeometryMLCaptureSignals {
        GeometryMLCaptureSignals(
            motionScore: lastCaptureMotionScore,
            overexposureRatio: lastCaptureOverexposureRatio,
            underexposureRatio: lastCaptureUnderexposureRatio,
            hasLargeBlownRegion: lastCaptureHasLargeBlownRegion
        )
    }

    /// Snapshot evidence-side signals for PureVision runtime audit input.
    public func runtimeAuditEvidenceSignals() -> GeometryMLEvidenceSignals {
        let invariantSnapshot = EvidenceInvariantMonitor.shared.snapshot()
        let replayStableRate = auditReplaySampleCount > 0
            ? Double(auditReplayStableCount) / Double(auditReplaySampleCount)
            : 1.0
        let triTetBindingCoverage = auditObservationCount > 0
            ? Double(auditTriTetBoundCount) / Double(auditObservationCount)
            : 1.0
        let merkleCoverage = auditObservationCount > 0
            ? Double(auditTriTetMerkleBoundCount) / Double(auditObservationCount)
            : 1.0
        let provenanceGapCount = max(0, auditObservationCount - auditTriTetBoundCount)
        let coverageScore = max(lastCoverageScore, gateDisplay)

        return GeometryMLEvidenceSignals(
            coverageScore: max(0.0, min(1.0, coverageScore)),
            softEvidenceScore: max(0.0, min(1.0, softDisplay)),
            persistentPizRegionCount: lastPersistentPizRegionCount,
            invariantViolationCount: invariantSnapshot.totalViolationCount,
            replayStableRate: max(0.0, min(1.0, replayStableRate)),
            triTetBindingCoverage: max(0.0, min(1.0, triTetBindingCoverage)),
            merkleProofCoverage: max(0.0, min(1.0, merkleCoverage)),
            occlusionExcludedAreaRatio: max(0.0, min(1.0, lastOcclusionExcludedAreaRatio)),
            provenanceGapCount: provenanceGapCount
        )
    }
}

/// Immutable snapshot for cross-thread reading
public struct EvidenceSnapshot: Codable, Sendable {
    public let gateDisplay: Double
    public let softDisplay: Double
    public let totalEvidence: Double
    public let gateDelta: Double
    public let softDelta: Double
    
    public init(
        gateDisplay: Double,
        softDisplay: Double,
        totalEvidence: Double,
        gateDelta: Double = 0.0,
        softDelta: Double = 0.0
    ) {
        self.gateDisplay = gateDisplay
        self.softDisplay = softDisplay
        self.totalEvidence = totalEvidence
        self.gateDelta = gateDelta
        self.softDelta = softDelta
    }
}

// PatchDisplayMap is now implemented in PatchDisplayMap.swift
