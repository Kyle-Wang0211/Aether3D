// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// DomainBoundaryEnforcer.swift
// PR5Capture
//
// PR5 v1.8.1 - 五大核心方法论之一：三域隔离（Three-Domain Isolation）
// Perception → Decision → Ledger 单向数据流，强制边界验证
//

import Foundation

/// Three-domain isolation: Perception → Decision → Ledger
///
/// **Core Principle**: Enforce unidirectional data flow with compile-time and runtime checks
///
/// **Domain Definitions**:
/// - **Perception Domain**: Raw sensor data, ISP processing, timestamping, liveness detection
/// - **Decision Domain**: State machine, quality metrics, frame disposition, dynamic scene detection
/// - **Ledger Domain**: Audit logs, privacy tracking, consent management, identity chains
///
/// **Enforcement Levels**:
/// - **Compile-time**: Swift Package target dependencies enforce direction
/// - **Runtime**: Boundary checks verify data flow correctness
public enum CaptureDomain: String, Codable, Sendable, CaseIterable {
    case perception
    case decision
    case ledger
}

/// Domain boundary violation error
public enum DomainBoundaryError: Error, Sendable {
    case invalidCrossDomainAccess(from: CaptureDomain, to: CaptureDomain)
    case reverseDataFlow(from: CaptureDomain, to: CaptureDomain)
    case missingBoundaryCheck(domain: CaptureDomain)
}

/// Domain boundary enforcer
///
/// Enforces three-domain isolation at runtime.
/// Compile-time enforcement is handled by Swift Package target dependencies.
public actor DomainBoundaryEnforcer {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile.DomainBoundaryConfig
    
    // MARK: - State
    
    /// Track current domain context for each operation
    private var currentDomain: CaptureDomain?
    
    /// Track cross-domain accesses for auditing
    private var crossDomainAccesses: [(from: CaptureDomain, to: CaptureDomain, timestamp: Date)] = []
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile.DomainBoundaryConfig) {
        self.config = config
    }
    
    // MARK: - Domain Context Management
    
    /// Enter a domain context
    /// 
    /// Call this at the start of domain-specific operations
    public func enterDomain(_ domain: CaptureDomain) {
        currentDomain = domain
    }
    
    /// Exit current domain context
    public func exitDomain() {
        currentDomain = nil
    }
    
    /// Verify cross-domain access is allowed
    ///
    /// **Allowed flows**:
    /// - Perception → Decision ✅
    /// - Decision → Ledger ✅
    ///
    /// **Forbidden flows**:
    /// - Decision → Perception ❌
    /// - Ledger → Decision ❌
    /// - Ledger → Perception ❌
    /// - Any reverse flow ❌
    public func verifyCrossDomainAccess(from sourceDomain: CaptureDomain, to targetDomain: CaptureDomain) throws {
        // Record access for auditing
        crossDomainAccesses.append((from: sourceDomain, to: targetDomain, timestamp: Date()))
        
        // Check if access is allowed
        let allowed = isAllowedFlow(from: sourceDomain, to: targetDomain)
        
        if !allowed {
            let error = DomainBoundaryError.invalidCrossDomainAccess(from: sourceDomain, to: targetDomain)
            
            switch config.boundaryViolationPolicy {
            case .warn:
                // Log warning but continue
                print("⚠️ Domain boundary violation: \(sourceDomain) → \(targetDomain)")
            case .hardFail:
                throw error
            }
        }
    }
    
    /// Check if data flow is allowed
    private func isAllowedFlow(from source: CaptureDomain, to target: CaptureDomain) -> Bool {
        switch (source, target) {
        case (.perception, .decision):
            return true  // ✅ Perception → Decision
        case (.decision, .ledger):
            return true  // ✅ Decision → Ledger
        case (.perception, .perception),
             (.decision, .decision),
             (.ledger, .ledger):
            return true  // ✅ Same domain
        default:
            return false // ❌ All other flows forbidden
        }
    }
    
    // MARK: - Boundary Verification
    
    /// Verify data structure belongs to correct domain
    ///
    /// Used to verify that data structures are used in their intended domain
    public func verifyDomainOwnership<T>(_ value: T, expectedDomain: CaptureDomain) throws {
        // Runtime check: verify current domain matches expected
        if let current = currentDomain, current != expectedDomain {
            let error = DomainBoundaryError.missingBoundaryCheck(domain: expectedDomain)
            
            switch config.boundaryViolationPolicy {
            case .warn:
                print("⚠️ Domain ownership violation: expected \(expectedDomain), current \(current)")
            case .hardFail:
                throw error
            }
        }
    }
    
    // MARK: - Audit & Reporting
    
    /// Get cross-domain access audit log
    public func getCrossDomainAccessLog() -> [(from: CaptureDomain, to: CaptureDomain, timestamp: Date)] {
        return crossDomainAccesses
    }
    
    /// Clear audit log (for testing)
    public func clearAuditLog() {
        crossDomainAccesses.removeAll()
    }
}

// MARK: - Runtime Check Helper

/// Runtime check helper for domain boundary verification
public func verifyDomainBoundary<T: DomainOwned>(_ value: T, enforcer: DomainBoundaryEnforcer) async throws {
    try await enforcer.verifyDomainOwnership(value, expectedDomain: value.domain)
}
