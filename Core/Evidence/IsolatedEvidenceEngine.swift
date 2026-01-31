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
    
    // MARK: - PR3 Gate Quality Computer
    
    /// Gate quality computer (PR3)
    /// Computes gateQuality from view coverage, geometry, and basic quality metrics
    private let gateComputer: GateQualityComputer
    
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
    ///   - frameIndex: Frame index (for deterministic eviction)
    ///   - softQuality: Soft quality (from PR4, 0.0 placeholder for now)
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
        frameIndex: Int,
        softQuality: Double = 0.0,  // Placeholder until PR4
        verdict: ObservationVerdict
    ) {
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
