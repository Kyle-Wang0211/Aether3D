//
// ReplayAttackPreventer.swift
// PR5Capture
//
// PR5 v1.8.1 - PART M: 测试和反作弊
// 重放攻击防止，时间戳+nonce验证
//

import Foundation

/// Replay attack preventer
///
/// Prevents replay attacks using timestamp and nonce validation.
/// Ensures requests are fresh and unique.
public actor ReplayAttackPreventer {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - State
    
    /// Used nonces
    private var usedNonces: Set<String> = []
    
    /// Timestamp window (5 minutes)
    private let timestampWindow: TimeInterval = 300
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Prevention
    
    /// Validate request to prevent replay
    public func validateRequest(nonce: String, timestamp: Date) -> ValidationResult {
        let now = Date()
        let age = now.timeIntervalSince(timestamp)
        
        // Check timestamp freshness
        if age > timestampWindow {
            return ValidationResult(
                isValid: false,
                reason: "Timestamp too old: \(age)s"
            )
        }
        
        // Check nonce uniqueness
        if usedNonces.contains(nonce) {
            return ValidationResult(
                isValid: false,
                reason: "Nonce already used"
            )
        }
        
        // Record nonce
        usedNonces.insert(nonce)
        
        // Clean old nonces (keep only recent)
        if usedNonces.count > 10000 {
            usedNonces.removeAll()
        }
        
        return ValidationResult(
            isValid: true,
            reason: "Valid request"
        )
    }
    
    // MARK: - Result Types
    
    /// Validation result
    public struct ValidationResult: Sendable {
        public let isValid: Bool
        public let reason: String
    }
}
