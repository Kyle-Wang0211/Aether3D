//
// RelocalizationStateManager.swift
// PR5Capture
//
// PR5 v1.8.1 - PART C: 状态机增强
// 重定位状态管理，跟踪置信度阈值，重定位超时处理
//

import Foundation

/// Relocalization state manager
///
/// Manages relocalization state with tracking confidence thresholds.
/// Handles relocalization timeout.
public actor RelocalizationStateManager {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - Relocalization State
    
    public enum RelocalizationState: String, Codable, Sendable, CaseIterable {
        case tracking      // Normal tracking
        case relocalizing  // Attempting relocalization
        case lost          // Tracking lost
    }
    
    private var currentState: RelocalizationState = .tracking
    
    /// Tracking confidence history
    private var confidenceHistory: [(timestamp: Date, confidence: Double)] = []
    
    /// Relocalization start time
    private var relocalizationStartTime: Date?
    
    /// Relocalization timeout
    private let relocalizationTimeout: TimeInterval = 5.0  // 5 seconds
    
    /// Confidence threshold for relocalization trigger
    private let confidenceThreshold: Double = 0.5
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - State Management
    
    /// Update tracking confidence
    ///
    /// Updates state based on confidence and triggers relocalization if needed
    public func updateConfidence(_ confidence: Double) -> StateUpdateResult {
        let now = Date()
        confidenceHistory.append((timestamp: now, confidence: confidence))
        
        // Keep only recent history (last 100)
        if confidenceHistory.count > 100 {
            confidenceHistory.removeFirst()
        }
        
        // Check timeout if relocalizing
        if currentState == .relocalizing, let startTime = relocalizationStartTime {
            let elapsed = now.timeIntervalSince(startTime)
            if elapsed >= relocalizationTimeout {
                // Timeout - mark as lost
                currentState = .lost
                relocalizationStartTime = nil
                return .stateChanged(to: .lost, reason: "Relocalization timeout")
            }
        }
        
        // State transition logic
        switch currentState {
        case .tracking:
            if confidence < confidenceThreshold {
                // Start relocalization
                currentState = .relocalizing
                relocalizationStartTime = now
                return .stateChanged(to: .relocalizing, reason: "Confidence \(confidence) below threshold \(confidenceThreshold)")
            } else {
                return .maintained(state: .tracking, confidence: confidence)
            }
            
        case .relocalizing:
            if confidence >= confidenceThreshold {
                // Relocalization successful
                currentState = .tracking
                relocalizationStartTime = nil
                return .stateChanged(to: .tracking, reason: "Relocalization successful, confidence \(confidence)")
            } else {
                return .maintained(state: .relocalizing, confidence: confidence)
            }
            
        case .lost:
            if confidence >= confidenceThreshold {
                // Recovery from lost state
                currentState = .tracking
                return .stateChanged(to: .tracking, reason: "Recovery from lost state")
            } else {
                return .maintained(state: .lost, confidence: confidence)
            }
        }
    }
    
    /// Force relocalization
    public func forceRelocalization() {
        currentState = .relocalizing
        relocalizationStartTime = Date()
    }
    
    /// Reset to tracking state
    public func resetToTracking() {
        currentState = .tracking
        relocalizationStartTime = nil
    }
    
    // MARK: - Queries
    
    /// Get current state
    public func getCurrentState() -> RelocalizationState {
        return currentState
    }
    
    /// Get average confidence
    public func getAverageConfidence() -> Double? {
        guard !confidenceHistory.isEmpty else { return nil }
        let sum = confidenceHistory.reduce(0.0) { $0 + $1.confidence }
        return sum / Double(confidenceHistory.count)
    }
    
    /// Get time in relocalization
    public func getRelocalizationElapsedTime() -> TimeInterval? {
        guard let startTime = relocalizationStartTime else { return nil }
        return Date().timeIntervalSince(startTime)
    }
    
    // MARK: - Result Types
    
    /// State update result
    public enum StateUpdateResult: Sendable {
        case stateChanged(to: RelocalizationState, reason: String)
        case maintained(state: RelocalizationState, confidence: Double)
    }
}
