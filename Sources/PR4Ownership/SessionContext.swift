//
// SessionContext.swift
// PR4Ownership
//
// PR4 V10 - Pillar 2: Session-scoped state with explicit update policies (Hard-13)
//

import Foundation
import PR4Math
import PR4PathTrace
import PR4Protocols

/// Session context - owns state that persists across frames
///
/// V10 RULE: SessionContext is the ONLY place for cross-frame state.
/// V10 ISOLATION: No dependency on Quality, Gate, or other downstream modules.
/// Uses type-erased Any to break circular dependencies.
public final class SessionContext {

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Identity
    // ═══════════════════════════════════════════════════════════════════════

    public let sessionId: UUID
    public let startTime: Date

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Cross-Frame State (Type-Erased)
    // ═══════════════════════════════════════════════════════════════════════

    /// Gate state machine per source (type-erased)
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
    public var madEstimators: [SourceID: OnlineMADEstimatorLocal] = [:]

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
    ///
    /// V10 ISOLATION: Uses type-erased update to avoid dependency on Quality/Gate modules.
    /// The caller (typically PR4Fusion) is responsible for extracting values from
    /// QualityResult and GateDecision before calling this method.
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

        // Update gate states (type-erased)
        for (sourceId, decisionAny) in result.gateDecisions {
            // Extract newState using protocol-based approach
            if let newState = extractNewState(from: decisionAny) {
                gateStates[sourceId] = newState
            }
        }

        // Update EMA histories (type-erased)
        for (sourceId, qualityAny) in result.qualities {
            // Extract quality value using protocol-based approach
            if let qualityValue = extractQualityValue(from: qualityAny) {
                if emaHistories[sourceId] == nil {
                    emaHistories[sourceId] = EMAHistory()
                }
                emaHistories[sourceId]?.append(qualityValue)
            }
        }

        // Update MAD estimators (type-erased)
        for (sourceId, qualityAny) in result.qualities {
            if let qualityValue = extractQualityValue(from: qualityAny) {
                if madEstimators[sourceId] == nil {
                    madEstimators[sourceId] = OnlineMADEstimatorLocal()
                }
                madEstimators[sourceId]?.addSample(qualityValue)
            }
        }

        // Update counters
        frameCount += 1
        lastFrameId = result.frameId
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Type-Erased Value Extraction
    // ═══════════════════════════════════════════════════════════════════════

    /// Extract quality value from type-erased quality result
    private func extractQualityValue(from any: Any) -> Double? {
        // Try protocol-based extraction first
        if let hasValue = any as? HasDoubleValue {
            return hasValue.doubleValue
        }
        // Fallback: try to extract "value" property via reflection
        let mirror = Mirror(reflecting: any)
        for child in mirror.children {
            if child.label == "value", let value = child.value as? Double {
                return value
            }
        }
        return nil
    }

    /// Extract new state from type-erased gate decision
    private func extractNewState(from any: Any) -> Any? {
        // Try protocol-based extraction first
        if let hasNewState = any as? HasNewState {
            return hasNewState.newStateAny
        }
        // Fallback: try to extract "newState" property via reflection
        let mirror = Mirror(reflecting: any)
        for child in mirror.children {
            if child.label == "newState" {
                return child.value
            }
        }
        return nil
    }
}

// ═══════════════════════════════════════════════════════════════════════
// MARK: - Supporting Types (Protocols defined in PR4Protocols)
// ═══════════════════════════════════════════════════════════════════════

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

    public init() {}

    public mutating func append(_ value: Double) {
        values.append(value)
        if values.count > 100 {
            values.removeFirst()
        }
    }
}

/// Local OnlineMADEstimator (no dependency on PR4Gate)
/// PR4Gate.OnlineMADEstimator can extend this or use its own implementation
public final class OnlineMADEstimatorLocal {
    private var samples: [Double] = []

    public init() {}

    public func addSample(_ value: Double) {
        samples.append(value)
        if samples.count > 1000 {
            samples.removeFirst()
        }
    }

    public func getMAD() -> Double {
        guard samples.count >= 3 else { return 0 }
        let sorted = samples.sorted()
        let median = sorted[sorted.count / 2]
        let deviations = samples.map { abs($0 - median) }.sorted()
        return deviations[deviations.count / 2]
    }
}
