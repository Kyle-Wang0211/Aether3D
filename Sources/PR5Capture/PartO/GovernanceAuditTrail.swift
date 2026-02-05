//
// GovernanceAuditTrail.swift
// PR5Capture
//
// PR5 v1.8.1 - PART O: 风险注册和治理
// 治理审计轨迹，决策记录
//

import Foundation

/// Governance audit trail
///
/// Maintains governance audit trail with decision recording.
/// Provides complete audit log of governance decisions.
public actor GovernanceAuditTrail {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - State
    
    /// Audit trail
    private var trail: [AuditEntry] = []
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Trail Management
    
    /// Record audit entry
    public func recordEntry(
        decision: String,
        rationale: String,
        decisionMaker: String
    ) -> RecordingResult {
        let entry = AuditEntry(
            id: UUID(),
            timestamp: Date(),
            decision: decision,
            rationale: rationale,
            decisionMaker: decisionMaker
        )
        
        trail.append(entry)
        
        // Keep only recent trail (last 10000)
        if trail.count > 10000 {
            trail.removeFirst()
        }
        
        return RecordingResult(
            entryId: entry.id,
            timestamp: entry.timestamp,
            success: true
        )
    }
    
    /// Get audit trail
    public func getTrail(count: Int = 100) -> [AuditEntry] {
        return Array(trail.suffix(count))
    }
    
    // MARK: - Data Types
    
    /// Audit entry
    public struct AuditEntry: Sendable {
        public let id: UUID
        public let timestamp: Date
        public let decision: String
        public let rationale: String
        public let decisionMaker: String
    }
    
    /// Recording result
    public struct RecordingResult: Sendable {
        public let entryId: UUID
        public let timestamp: Date
        public let success: Bool
    }
}
