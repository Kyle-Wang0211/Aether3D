//
// SessionContext.swift
// PR4Ownership
//
// PR4 V10 - Pillar 2: Session-scoped state with explicit update policies (Hard-13)
//

import Foundation
import PR4Math
import PR4PathTrace
import PR4Quality
import PR4Gate

/// Session context - owns state that persists across frames
///
/// V10 RULE: SessionContext is the ONLY place for cross-frame state.
public final class SessionContext {
    
    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Identity
    // ═══════════════════════════════════════════════════════════════════════
    
    public let sessionId: UUID
    public let startTime: Date
    
    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Cross-Frame State
    // ═══════════════════════════════════════════════════════════════════════
    
    /// Gate state machine per source
    /// UPDATE POLICY: Updated at end of each frame based on frame's gate decision
    public var gateStates: [SourceID: Any] = [:]
    
    /// EMA history per source
    /// UPDATE POLICY: Updated after each frame's quality is finalized
    public var emaHistories: [SourceID: EMAHistory] = [:]
    
    /// Calibration data per source
    /// UPDATE POLICY: Updated by calibration system (not per-frame)
    public var calibrationData: [SourceID: CalibrationData] = [:]
    
    /// MAD estimator state
    /// UPDATE POLICY: Updated when quality values are committed
    public var madEstimators: [SourceID: OnlineMADEstimator] = [:]
    
    /// Frame count for this session
    /// UPDATE POLICY: Incremented at start of each frame
    public private(set) var frameCount: UInt64 = 0
    
    /// Last processed frame ID
    /// UPDATE POLICY: Set at end of each frame
    public private(set) var lastFrameId: FrameID?
    
    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Lifecycle
    // ═══════════════════════════════════════════════════════════════════════
    
    public init() {
        self.sessionId = UUID()
        self.startTime = Date()
    }
    
    /// Create snapshot for frame processing
    public func createFrameSnapshot() -> SessionSnapshot {
        return SessionSnapshot(
            gateStates: gateStates,
            emaHistories: emaHistories,
            calibrationData: calibrationData,
            frameCount: frameCount
        )
    }
    
    /// Update session from completed frame
    public func update(from result: FrameResult) {
        precondition(
            result.sessionId == sessionId,
            "Frame \(result.frameId) from session \(result.sessionId) cannot update session \(sessionId)"
        )
        
        if let lastId = lastFrameId {
            precondition(
                result.frameId > lastId,
                "Frame \(result.frameId) is older than last processed \(lastId)"
            )
        }
        
        // Update gate states
        for (sourceId, decisionAny) in result.gateDecisions {
            if let decision = decisionAny as? GateDecision {
                gateStates[sourceId] = decision.newState as Any
            }
        }
        
        // Update EMA histories
        for (sourceId, qualityAny) in result.qualities {
            if let quality = qualityAny as? QualityResult {
                if emaHistories[sourceId] == nil {
                    emaHistories[sourceId] = EMAHistory()
                }
                emaHistories[sourceId]?.append(quality.value)
            }
        }
        
        // Update MAD estimators
        for (sourceId, qualityAny) in result.qualities {
            if let quality = qualityAny as? QualityResult {
                if madEstimators[sourceId] == nil {
                    madEstimators[sourceId] = OnlineMADEstimator()
                }
                madEstimators[sourceId]?.addSample(quality.value)
            }
        }
        
        // Update counters
        frameCount += 1
        lastFrameId = result.frameId
    }
}

/// Immutable snapshot of session state
public struct SessionSnapshot {
    public let gateStates: [SourceID: Any]
    public let emaHistories: [SourceID: EMAHistory]
    public let calibrationData: [SourceID: CalibrationData]
    public let frameCount: UInt64
}

/// EMA history
public struct EMAHistory {
    public var values: [Double] = []
    
    public mutating func append(_ value: Double) {
        values.append(value)
        if values.count > 100 {
            values.removeFirst()
        }
    }
}

/// Placeholder for OnlineMADEstimator (will be defined in PR4Gate module)
public final class OnlineMADEstimator {
    private var samples: [Double] = []
    
    public func addSample(_ value: Double) {
        samples.append(value)
        if samples.count > 1000 {
            samples.removeFirst()
        }
    }
    
    public func getMAD() -> Double {
        guard samples.count >= 3 else { return 0 }
        // Simplified - full implementation in PR4Gate
        return 0.1
    }
}
