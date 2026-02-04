//
// DeferDecisionManager.swift
// PR5Capture
//
// PR5 v1.8.1 - PART 2 + D: 帧处理决策和账本完整性
// SLA 强制执行，超时处理，队列深度管理
//

import Foundation

/// Defer decision manager
///
/// Enforces SLA for deferred decisions with timeout handling.
/// Manages queue depth to prevent overflow.
public actor DeferDecisionManager {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - State
    
    /// Pending deferred decisions
    private var pendingDecisions: [PendingDecision] = []
    
    /// Decision history
    private var decisionHistory: [DecisionRecord] = []
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Decision Management
    
    /// Defer a decision
    ///
    /// Adds decision to pending queue with SLA timeout
    public func deferDecision(
        frameId: UInt64,
        reason: String,
        priority: DecisionPriority = .normal
    ) -> DeferResult {
        // Check queue depth
        let maxDepth = PR5CaptureConstants.getValue(
            PR5CaptureConstants.Disposition.deferQueueMaxDepth,
            profile: config.profile
        )
        
        if pendingDecisions.count >= maxDepth {
            return .queueFull(
                currentDepth: pendingDecisions.count,
                maxDepth: maxDepth
            )
        }
        
        // Get SLA timeout
        let slaTimeout = PR5CaptureConstants.getValue(
            PR5CaptureConstants.Disposition.deferDecisionSLATimeout,
            profile: config.profile
        )
        
        let deadline = Date().addingTimeInterval(slaTimeout)
        
        let decision = PendingDecision(
            frameId: frameId,
            reason: reason,
            priority: priority,
            deferredAt: Date(),
            deadline: deadline
        )
        
        pendingDecisions.append(decision)
        
        // Sort by priority and deadline
        pendingDecisions.sort { lhs, rhs in
            if lhs.priority != rhs.priority {
                return lhs.priority.rawValue > rhs.priority.rawValue
            }
            return lhs.deadline < rhs.deadline
        }
        
        return .deferred(decisionId: decision.id, deadline: deadline)
    }
    
    /// Resolve a deferred decision
    ///
    /// Removes decision from pending queue and records result
    public func resolveDecision(
        decisionId: UUID,
        result: DecisionResult
    ) -> Bool {
        guard let index = pendingDecisions.firstIndex(where: { $0.id == decisionId }) else {
            return false
        }
        
        let decision = pendingDecisions.remove(at: index)
        
        // Record in history
        let record = DecisionRecord(
            frameId: decision.frameId,
            decisionId: decisionId,
            deferredAt: decision.deferredAt,
            resolvedAt: Date(),
            result: result,
            reason: decision.reason
        )
        decisionHistory.append(record)
        
        // Keep only recent history (last 1000)
        if decisionHistory.count > 1000 {
            decisionHistory.removeFirst()
        }
        
        return true
    }
    
    // MARK: - Timeout Handling
    
    /// Check for timed-out decisions
    ///
    /// Should be called periodically to handle SLA violations
    public func checkTimeouts() -> [TimedOutDecision] {
        let now = Date()
        var timedOut: [TimedOutDecision] = []
        
        var indicesToRemove: [Int] = []
        for (index, decision) in pendingDecisions.enumerated() {
            if now >= decision.deadline {
                timedOut.append(TimedOutDecision(
                    decisionId: decision.id,
                    frameId: decision.frameId,
                    deferredAt: decision.deferredAt,
                    deadline: decision.deadline,
                    exceededBy: now.timeIntervalSince(decision.deadline)
                ))
                indicesToRemove.append(index)
            }
        }
        
        // Remove timed-out decisions (in reverse order)
        for index in indicesToRemove.reversed() {
            pendingDecisions.remove(at: index)
        }
        
        return timedOut
    }
    
    // MARK: - Queries
    
    /// Get pending decisions count
    public func getPendingCount() -> Int {
        return pendingDecisions.count
    }
    
    /// Get queue depth
    public func getQueueDepth() -> (current: Int, max: Int) {
        let maxDepth = PR5CaptureConstants.getValue(
            PR5CaptureConstants.Disposition.deferQueueMaxDepth,
            profile: config.profile
        )
        return (current: pendingDecisions.count, max: maxDepth)
    }
    
    // MARK: - Data Types
    
    /// Decision priority
    public enum DecisionPriority: Int, Codable, Sendable, Comparable {
        case low = 1
        case normal = 2
        case high = 3
        case urgent = 4
        
        public static func < (lhs: DecisionPriority, rhs: DecisionPriority) -> Bool {
            return lhs.rawValue < rhs.rawValue
        }
    }
    
    /// Decision result
    public enum DecisionResult: String, Codable, Sendable, CaseIterable {
        case accept
        case reject
        case `defer`  // Further deferral
    }
    
    /// Pending decision
    public struct PendingDecision: Sendable {
        public let id: UUID
        public let frameId: UInt64
        public let reason: String
        public let priority: DecisionPriority
        public let deferredAt: Date
        public let deadline: Date
        
        public init(
            id: UUID = UUID(),
            frameId: UInt64,
            reason: String,
            priority: DecisionPriority,
            deferredAt: Date,
            deadline: Date
        ) {
            self.id = id
            self.frameId = frameId
            self.reason = reason
            self.priority = priority
            self.deferredAt = deferredAt
            self.deadline = deadline
        }
    }
    
    /// Decision record
    public struct DecisionRecord: Sendable {
        public let frameId: UInt64
        public let decisionId: UUID
        public let deferredAt: Date
        public let resolvedAt: Date
        public let result: DecisionResult
        public let reason: String
    }
    
    /// Timed-out decision
    public struct TimedOutDecision: Sendable {
        public let decisionId: UUID
        public let frameId: UInt64
        public let deferredAt: Date
        public let deadline: Date
        public let exceededBy: TimeInterval
    }
    
    /// Defer result
    public enum DeferResult: Sendable {
        case deferred(decisionId: UUID, deadline: Date)
        case queueFull(currentDepth: Int, maxDepth: Int)
    }
}
