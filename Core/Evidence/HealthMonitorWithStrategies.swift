//
// HealthMonitorWithStrategies.swift
// Aether3D
//
// PR2 Patch V4 - Health Monitor with Red-Line Strategies
// Automatic recovery actions for unhealthy states
//

import Foundation

/// Health monitor with red-line strategies
@EvidenceActor
public final class HealthMonitorWithStrategies {
    
    // MARK: - Red Line Thresholds
    
    public struct RedLineThresholds {
        /// Maximum stalled ratio before intervention
        public static let maxStalledRatio: Double = 0.3
        
        /// Maximum average age before intervention
        public static let maxAverageAgeSec: Double = 120.0
        
        /// Minimum delta before intervention
        public static let minAverageDelta: Double = 0.0001
        
        /// Minimum health score
        public static let minHealthScore: Double = 0.5
        
        /// Critical health score (freeze display)
        public static let criticalHealthScore: Double = 0.40
        
        /// Emergency health score (rollback)
        public static let emergencyHealthScore: Double = 0.25
    }
    
    // MARK: - Recovery Strategies
    
    public enum RecoveryStrategy: String, Sendable {
        /// No action needed
        case none
        
        /// Suggest user move to different angle
        case suggestViewChange
        
        /// Boost weights for stalled patches
        case boostStalledPatches
        
        /// Reset decay timers
        case resetDecayTimers
        
        /// Full recalibration
        case recalibrate
        
        /// Freeze display increase (still update diagnostics)
        case freezeDisplay
        
        /// Rollback to last safe point
        case rollback
        
        /// Alert for investigation
        case alert
    }
    
    // MARK: - Health Check Result
    
    public struct HealthCheckResult: Sendable {
        public let metrics: EvidenceHealthMetrics
        public let isHealthy: Bool
        public let strategies: [RecoveryStrategy]
        public let alerts: [String]
    }
    
    private let engine: IsolatedEvidenceEngine
    private let safePointManager: SafePointManager
    
    public init(engine: IsolatedEvidenceEngine, safePointManager: SafePointManager) {
        self.engine = engine
        self.safePointManager = safePointManager
    }
    
    /// Compute health and recommend strategies
    public func checkHealth(currentTime: TimeInterval) async -> HealthCheckResult {
        let metrics = await computeMetrics(currentTime: currentTime)
        var strategies: [RecoveryStrategy] = []
        var alerts: [String] = []
        
        // Check health score thresholds
        if metrics.healthScore < RedLineThresholds.emergencyHealthScore {
            strategies.append(.rollback)
            alerts.append("Emergency: Health score \(String(format: "%.2f", metrics.healthScore)) < \(RedLineThresholds.emergencyHealthScore)")
        } else if metrics.healthScore < RedLineThresholds.criticalHealthScore {
            strategies.append(.freezeDisplay)
            alerts.append("Critical: Health score \(String(format: "%.2f", metrics.healthScore)) < \(RedLineThresholds.criticalHealthScore)")
        }
        
        // Check stalled ratio
        if metrics.stalledRatio > RedLineThresholds.maxStalledRatio {
            strategies.append(.suggestViewChange)
            if metrics.stalledRatio > 0.5 {
                strategies.append(.boostStalledPatches)
            }
            alerts.append("High stalled ratio: \(String(format: "%.1f%%", metrics.stalledRatio * 100))")
        }
        
        // Check average age
        if metrics.averageAge > RedLineThresholds.maxAverageAgeSec {
            strategies.append(.resetDecayTimers)
            alerts.append("High average age: \(String(format: "%.0fs", metrics.averageAge))")
        }
        
        // Check delta
        if metrics.averageDelta < RedLineThresholds.minAverageDelta && metrics.lockedRatio < 0.8 {
            strategies.append(.recalibrate)
            alerts.append("Progress stalled: delta = \(String(format: "%.6f", metrics.averageDelta))")
        }
        
        // Check overall health
        let isHealthy = metrics.healthScore >= RedLineThresholds.minHealthScore
        
        if !isHealthy && strategies.isEmpty {
            strategies.append(.alert)
            alerts.append("Low health score: \(String(format: "%.2f", metrics.healthScore))")
        }
        
        return HealthCheckResult(
            metrics: metrics,
            isHealthy: isHealthy,
            strategies: strategies.isEmpty ? [.none] : strategies,
            alerts: alerts
        )
    }
    
    /// Execute recovery strategy
    public func executeStrategy(_ strategy: RecoveryStrategy) async {
        switch strategy {
        case .none:
            break
            
        case .suggestViewChange:
            // Emit UI notification
            NotificationCenter.default.post(
                name: .evidenceSuggestViewChange,
                object: nil
            )
            
        case .boostStalledPatches:
            // Temporarily increase weights for stalled patches
            // await engine.boostStalledPatches(multiplier: 1.5, duration: 10.0)
            EvidenceLogger.info("Boosting stalled patches")
            
        case .resetDecayTimers:
            // Reset decay timers to give stale patches another chance
            // await engine.resetDecayTimers()
            EvidenceLogger.info("Resetting decay timers")
            
        case .recalibrate:
            // Full recalibration
            // await engine.recalibrate()
            EvidenceLogger.info("Recalibrating aggregator")
            
        case .freezeDisplay:
            // Freeze display increase (still update diagnostics)
            EvidenceLogger.warn("Freezing display increase due to critical health")
            
        case .rollback:
            // Rollback to last safe point
            if let safeState = await safePointManager.rollback() {
                try? await engine.loadStateJSON(safeState)
                EvidenceLogger.warn("Rolled back to safe point")
            }
            
        case .alert:
            // Log for investigation
            EvidenceLogger.error("Evidence system unhealthy, manual investigation required")
        }
    }
    
    private func computeMetrics(currentTime: TimeInterval) async -> EvidenceHealthMetrics {
        let snapshot = await engine.snapshot()
        
        // Stub implementation - will be fully implemented when SplitLedger is complete
        return EvidenceHealthMetrics(
            colorDistribution: [:],
            averageAge: 0,
            lockedRatio: 0,
            averageDelta: snapshot.gateDelta + snapshot.softDelta,
            stalledRatio: 0
        )
    }
}

/// Evidence health metrics
public struct EvidenceHealthMetrics: Sendable {
    /// Color state distribution
    public let colorDistribution: [ColorState: Double]
    
    /// Average patch evidence age (seconds)
    public let averageAge: Double
    
    /// Locked patch ratio
    public let lockedRatio: Double
    
    /// Average delta (growth rate)
    public let averageDelta: Double
    
    /// Stalled patches (no progress in 30s)
    public let stalledRatio: Double
    
    /// Health score [0, 1]
    public var healthScore: Double {
        let stalledPenalty = stalledRatio * 0.4
        let agePenalty = min(0.2, averageAge / 300.0)
        let lowDeltaPenalty = averageDelta < 0.001 ? 0.2 : 0.0
        return max(0, 1.0 - stalledPenalty - agePenalty - lowDeltaPenalty)
    }
    
    /// Is system healthy?
    public var isHealthy: Bool { healthScore > 0.6 }
}

/// Color state for evidence visualization
public enum ColorState: String, Codable, Sendable {
    case black
    case darkGray
    case lightGray
    case white
    case original
    
    /// Unknown value for forward compatibility
    case unknown
    
    /// **Rule ID:** PR6_GRID_STATE_009
    /// PR6 Extension: Check if state is S5 (original)
    public var isS5: Bool {
        return self == .original
    }
    
    // MARK: - Codable with Forward Compatibility
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        
        if let state = ColorState(rawValue: rawValue) {
            self = state
        } else {
            // Unknown value: default to darkGray (safe middle ground)
            self = .unknown
            EvidenceLogger.warn("Unknown ColorState value decoded: \(rawValue), defaulting to .unknown")
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        // Encode unknown as "unknown" for debugging
        var container = encoder.singleValueContainer()
        if self == .unknown {
            try container.encode("unknown")
        } else {
            try container.encode(self.rawValue)
        }
    }
}

/// Stub for SafePointManager
public final class SafePointManager {
    public func rollback() async -> Data? {
        // Stub: will be implemented
        return nil
    }
}

/// Notification name
extension Notification.Name {
    static let evidenceSuggestViewChange = Notification.Name("EvidenceSuggestViewChange")
}
