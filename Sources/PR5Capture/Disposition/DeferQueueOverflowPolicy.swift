//
// DeferQueueOverflowPolicy.swift
// PR5Capture
//
// PR5 v1.8.1 - PART D: 账本完整性增强
// 延迟队列溢出策略
//

import Foundation

/// Defer queue overflow policy
///
/// Handles defer queue overflow with configurable policies.
/// Prevents system degradation from queue saturation.
public actor DeferQueueOverflowPolicy {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - Overflow Policy Types
    
    public enum OverflowPolicy: String, Codable, Sendable, CaseIterable {
        case reject      // Reject new decisions
        case dropOldest // Drop oldest pending decisions
        case degrade    // Degrade quality to process faster
        case emergency  // Emergency processing mode
    }
    
    // MARK: - State
    
    /// Current overflow policy
    private var currentPolicy: OverflowPolicy = .reject
    
    /// Overflow events
    private var overflowEvents: [OverflowEvent] = []
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Overflow Handling
    
    /// Handle queue overflow
    ///
    /// Applies overflow policy when queue is full
    public func handleOverflow(
        currentDepth: Int,
        maxDepth: Int,
        pendingDecisions: [UUID]
    ) -> OverflowHandlingResult {
        let event = OverflowEvent(
            timestamp: Date(),
            currentDepth: currentDepth,
            maxDepth: maxDepth,
            policy: currentPolicy
        )
        
        overflowEvents.append(event)
        
        // Keep only recent events (last 100)
        if overflowEvents.count > 100 {
            overflowEvents.removeFirst()
        }
        
        // Apply policy
        switch currentPolicy {
        case .reject:
            return .rejectNewDecisions(reason: "Queue full: \(currentDepth)/\(maxDepth)")
            
        case .dropOldest:
            let droppedCount = min(10, pendingDecisions.count / 2)
            return .dropDecisions(count: droppedCount, reason: "Dropping oldest \(droppedCount) decisions")
            
        case .degrade:
            return .degradeQuality(factor: 0.8, reason: "Degrading quality to process faster")
            
        case .emergency:
            return .emergencyMode(reason: "Emergency processing mode activated")
        }
    }
    
    /// Set overflow policy
    public func setPolicy(_ policy: OverflowPolicy) {
        currentPolicy = policy
    }
    
    /// Get current policy
    public func getCurrentPolicy() -> OverflowPolicy {
        return currentPolicy
    }
    
    /// Get overflow events
    public func getOverflowEvents() -> [OverflowEvent] {
        return overflowEvents
    }
    
    // MARK: - Data Types
    
    /// Overflow event
    public struct OverflowEvent: Sendable {
        public let timestamp: Date
        public let currentDepth: Int
        public let maxDepth: Int
        public let policy: OverflowPolicy
    }
    
    /// Overflow handling result
    public enum OverflowHandlingResult: Sendable {
        case rejectNewDecisions(reason: String)
        case dropDecisions(count: Int, reason: String)
        case degradeQuality(factor: Double, reason: String)
        case emergencyMode(reason: String)
    }
}
