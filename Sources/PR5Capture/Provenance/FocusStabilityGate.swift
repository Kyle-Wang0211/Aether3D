//
// FocusStabilityGate.swift
// PR5Capture
//
// PR5 v1.8.1 - PART A: Raw 溯源和 ISP 真实性
// AF 狩猎检测，焦点稳定性门控
//

import Foundation

/// Focus stability gate
///
/// Detects autofocus (AF) hunting and gates frames based on focus stability.
/// Prevents quality degradation from unstable focus.
public actor FocusStabilityGate {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - State
    
    /// Focus value history
    private var focusHistory: [(timestamp: Date, value: Double)] = []
    
    /// Current focus state
    private var isStable: Bool = false
    
    /// Last stable focus value
    private var lastStableFocus: Double?
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Focus Stability Evaluation
    
    /// Evaluate focus stability
    ///
    /// Detects AF hunting and determines if focus is stable enough for capture
    public func evaluateStability(_ focusValue: Double) -> FocusStabilityResult {
        let now = Date()
        focusHistory.append((timestamp: now, value: focusValue))
        
        // Keep only recent history (last 10 seconds)
        let cutoff = now.addingTimeInterval(-10.0)
        focusHistory.removeAll { $0.timestamp < cutoff }
        
        // Check for AF hunting (rapid oscillations)
        let isHunting = detectAFHunting()
        
        // Check stability
        let threshold = PR5CaptureConstants.getValue(
            PR5CaptureConstants.Provenance.focusStabilityThreshold,
            profile: config.profile
        )
        
        let stability = computeStability()
        let isStableNow = !isHunting && stability >= (1.0 - threshold)
        
        if isStableNow {
            lastStableFocus = focusValue
        }
        
        isStable = isStableNow
        
        return FocusStabilityResult(
            focusValue: focusValue,
            isStable: isStableNow,
            isHunting: isHunting,
            stability: stability,
            threshold: threshold,
            lastStableFocus: lastStableFocus
        )
    }
    
    /// Detect AF hunting (rapid oscillations)
    private func detectAFHunting() -> Bool {
        guard focusHistory.count >= 3 else { return false }
        
        // Check for rapid direction changes
        var directionChanges = 0
        for i in 2..<focusHistory.count {
            let prev = focusHistory[i-2].value
            let curr = focusHistory[i-1].value
            let next = focusHistory[i].value
            
            let dir1 = curr > prev
            let dir2 = next > curr
            
            if dir1 != dir2 {
                directionChanges += 1
            }
        }
        
        // Too many direction changes indicates hunting
        return directionChanges >= 3
    }
    
    /// Compute focus stability (0.0 = unstable, 1.0 = stable)
    private func computeStability() -> Double {
        guard focusHistory.count >= 2 else { return 0.0 }
        
        // Compute variance of recent focus values
        let values = focusHistory.map { $0.value }
        let mean = values.reduce(0.0, +) / Double(values.count)
        let variance = values.map { pow($0 - mean, 2) }.reduce(0.0, +) / Double(values.count)
        
        // Lower variance = higher stability
        let stability = 1.0 / (1.0 + variance * 10.0)
        
        return min(1.0, max(0.0, stability))
    }
    
    // MARK: - State Queries
    
    /// Get current stability state
    public func getCurrentStability() -> Bool {
        return isStable
    }
    
    /// Get last stable focus value
    public func getLastStableFocus() -> Double? {
        return lastStableFocus
    }
    
    // MARK: - Result Types
    
    /// Focus stability result
    public struct FocusStabilityResult: Sendable {
        public let focusValue: Double
        public let isStable: Bool
        public let isHunting: Bool
        public let stability: Double
        public let threshold: Double
        public let lastStableFocus: Double?
    }
}
