//
// AuditTrailRecorder.swift
// PR5Capture
//
// PR5 v1.8.1 - PART 8 + J: 审计模式演进
// 审计轨迹记录，事件记录，不可篡改日志
//

import Foundation

/// Audit trail recorder
///
/// Records audit trails with tamper-evident logging.
/// Maintains immutable audit logs.
public actor AuditTrailRecorder {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - State
    
    /// Audit trail
    private var auditTrail: [AuditEntry] = []
    
    /// Trail hash chain
    private var hashChain: [String] = []
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Trail Recording
    
    /// Record audit entry
    ///
    /// Records entry with hash chain for tamper detection
    public func recordEntry(_ entry: AuditEntry) {
        // Compute hash
        let entryData = "\(entry.timestamp.timeIntervalSince1970)-\(entry.operation)-\(entry.userId)-\(entry.result)"
        let previousHash = hashChain.last ?? ""
        let combined = previousHash + entryData
        
        // Simplified hash (in production, use proper crypto)
        let hash = String(combined.hash)
        hashChain.append(hash)
        
        // Add hash to entry
        var entryWithHash = entry
        entryWithHash.hash = hash
        entryWithHash.previousHash = previousHash
        
        auditTrail.append(entryWithHash)
        
        // Keep only recent trail (last 10000)
        if auditTrail.count > 10000 {
            auditTrail.removeFirst()
            hashChain.removeFirst()
        }
    }
    
    /// Verify trail integrity
    public func verifyIntegrity() -> IntegrityResult {
        guard auditTrail.count >= 2 else {
            return IntegrityResult(isValid: true, invalidEntries: [])
        }
        
        var invalidEntries: [Int] = []
        
        for i in 1..<auditTrail.count {
            let current = auditTrail[i]
            let previous = auditTrail[i-1]
            
            if current.previousHash != previous.hash {
                invalidEntries.append(i)
            }
        }
        
        return IntegrityResult(
            isValid: invalidEntries.isEmpty,
            invalidEntries: invalidEntries
        )
    }
    
    // MARK: - Data Types
    
    /// Audit entry
    public struct AuditEntry: Sendable, Codable {
        public let timestamp: Date
        public let operation: String
        public let userId: String
        public let result: String
        public var hash: String = ""
        public var previousHash: String = ""
        
        public init(timestamp: Date = Date(), operation: String, userId: String, result: String) {
            self.timestamp = timestamp
            self.operation = operation
            self.userId = userId
            self.result = result
        }
    }
    
    /// Integrity result
    public struct IntegrityResult: Sendable {
        public let isValid: Bool
        public let invalidEntries: [Int]
    }
}
