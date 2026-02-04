//
// PolicyViolationHandler.swift
// PR5Capture
//
// PR5 v1.8.1 - PART O: 风险注册和治理
// 策略违规处理，告警和阻断
//

import Foundation

/// Policy violation handler
///
/// Handles policy violations with alerting and blocking.
/// Implements violation response mechanisms.
public actor PolicyViolationHandler {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - Violation Actions
    
    public enum ViolationAction: String, Sendable {
        case alert
        case block
        case log
        case escalate
    }
    
    // MARK: - State
    
    /// Violation history
    private var violations: [PolicyViolation] = []
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Violation Handling
    
    /// Handle violation
    public func handleViolation(
        ruleId: String,
        operation: String,
        severity: RiskRegisterImplementation.RiskSeverity
    ) -> HandlingResult {
        let action: ViolationAction
        
        switch severity {
        case .p0:
            action = .block  // Critical: block
        case .p1:
            action = .escalate  // High: escalate
        case .p2:
            action = .alert  // Medium: alert
        case .p3:
            action = .log  // Low: log only
        }
        
        let violation = PolicyViolation(
            id: UUID(),
            ruleId: ruleId,
            operation: operation,
            severity: severity,
            action: action,
            timestamp: Date()
        )
        
        violations.append(violation)
        
        // Keep only recent violations (last 1000)
        if violations.count > 1000 {
            violations.removeFirst()
        }
        
        return HandlingResult(
            violationId: violation.id,
            action: action,
            blocked: action == .block
        )
    }
    
    // MARK: - Data Types
    
    /// Policy violation
    public struct PolicyViolation: Sendable {
        public let id: UUID
        public let ruleId: String
        public let operation: String
        public let severity: RiskRegisterImplementation.RiskSeverity
        public let action: ViolationAction
        public let timestamp: Date
    }
    
    /// Handling result
    public struct HandlingResult: Sendable {
        public let violationId: UUID
        public let action: ViolationAction
        public let blocked: Bool
    }
}
