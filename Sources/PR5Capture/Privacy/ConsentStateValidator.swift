//
// ConsentStateValidator.swift
// PR5Capture
//
// PR5 v1.8.1 - PART 7 + I: 隐私加固和双轨
// 同意状态验证，同意管理，合规检查
//

import Foundation

/// Consent state validator
///
/// Validates consent state and manages consent.
/// Ensures compliance with consent requirements.
public actor ConsentStateValidator {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - Consent States
    
    public enum ConsentState: String, Sendable {
        case granted
        case denied
        case pending
        case expired
    }
    
    // MARK: - State
    
    /// Consent records
    private var consentRecords: [ConsentRecord] = []
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Consent Validation
    
    /// Validate consent state
    ///
    /// Checks if consent is valid for operation
    public func validateConsent(operation: String) -> ValidationResult {
        // Get most recent consent for operation
        let relevantConsents = consentRecords.filter { $0.operation == operation }
        guard let latestConsent = relevantConsents.max(by: { $0.timestamp < $1.timestamp }) else {
            return ValidationResult(isValid: false, reason: "No consent found")
        }
        
        // Check if expired
        let expirationTime: TimeInterval = 86400 * 30  // 30 days
        if Date().timeIntervalSince(latestConsent.timestamp) > expirationTime {
            return ValidationResult(isValid: false, reason: "Consent expired")
        }
        
        // Check state
        let isValid = latestConsent.state == .granted
        
        return ValidationResult(
            isValid: isValid,
            reason: isValid ? "Consent valid" : "Consent denied"
        )
    }
    
    /// Record consent
    public func recordConsent(operation: String, state: ConsentState) {
        let record = ConsentRecord(
            operation: operation,
            state: state,
            timestamp: Date()
        )
        consentRecords.append(record)
        
        // Keep only recent records (last 1000)
        if consentRecords.count > 1000 {
            consentRecords.removeFirst()
        }
    }
    
    // MARK: - Data Types
    
    /// Consent record
    public struct ConsentRecord: Sendable {
        public let operation: String
        public let state: ConsentState
        public let timestamp: Date
    }
    
    /// Validation result
    public struct ValidationResult: Sendable {
        public let isValid: Bool
        public let reason: String
    }
}
