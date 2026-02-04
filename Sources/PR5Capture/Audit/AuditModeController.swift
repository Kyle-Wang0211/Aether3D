//
// AuditModeController.swift
// PR5Capture
//
// PR5 v1.8.1 - PART 8 + J: 审计模式演进
// 审计模式控制，模式切换，审计级别管理
//

import Foundation

/// Audit mode controller
///
/// Controls audit modes and manages audit levels.
/// Handles mode switching and level management.
public actor AuditModeController {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - Audit Levels
    
    public enum AuditLevel: String, Sendable, Comparable {
        case none
        case minimal
        case standard
        case detailed
        case comprehensive
        
        public static func < (lhs: AuditLevel, rhs: AuditLevel) -> Bool {
            let order: [AuditLevel] = [.none, .minimal, .standard, .detailed, .comprehensive]
            guard let lhsIndex = order.firstIndex(of: lhs),
                  let rhsIndex = order.firstIndex(of: rhs) else {
                return false
            }
            return lhsIndex < rhsIndex
        }
    }
    
    // MARK: - State
    
    /// Current audit level
    private var currentLevel: AuditLevel = .standard
    
    /// Mode history
    private var modeHistory: [(timestamp: Date, level: AuditLevel)] = []
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Mode Control
    
    /// Set audit level
    public func setLevel(_ level: AuditLevel) {
        currentLevel = level
        
        // Record mode change
        modeHistory.append((timestamp: Date(), level: level))
        
        // Keep only recent history (last 100)
        if modeHistory.count > 100 {
            modeHistory.removeFirst()
        }
    }
    
    /// Get current level
    public func getCurrentLevel() -> AuditLevel {
        return currentLevel
    }
    
    /// Check if audit should be performed
    public func shouldAudit(operation: String) -> Bool {
        switch currentLevel {
        case .none:
            return false
        case .minimal:
            return operation.contains("critical")
        case .standard:
            return true
        case .detailed, .comprehensive:
            return true
        }
    }
}
