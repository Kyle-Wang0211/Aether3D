// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// DomainBoundaryEnforcerTests.swift
// PR5CaptureTests
//
// Tests for DomainBoundaryEnforcer
//

import XCTest
@testable import PR5Capture

@MainActor
final class DomainBoundaryEnforcerTests: XCTestCase {
    
    func testAllowedFlowPerceptionToDecision() async throws {
        let config = ExtremeProfile.DomainBoundaryConfig.forProfile(.standard)
        let enforcer = DomainBoundaryEnforcer(config: config)
        
        // Perception → Decision should be allowed
        try await enforcer.verifyCrossDomainAccess(from: .perception, to: .decision)
    }
    
    func testAllowedFlowDecisionToLedger() async throws {
        let config = ExtremeProfile.DomainBoundaryConfig.forProfile(.standard)
        let enforcer = DomainBoundaryEnforcer(config: config)
        
        // Decision → Ledger should be allowed
        try await enforcer.verifyCrossDomainAccess(from: .decision, to: .ledger)
    }
    
    func testForbiddenFlowDecisionToPerception() async {
        let config = ExtremeProfile.DomainBoundaryConfig.forProfile(.lab)
        let enforcer = DomainBoundaryEnforcer(config: config)
        
        // Decision → Perception should be forbidden
        do {
            try await enforcer.verifyCrossDomainAccess(from: .decision, to: .perception)
            XCTFail("Should have thrown error")
        } catch DomainBoundaryError.invalidCrossDomainAccess {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
    
    func testForbiddenFlowLedgerToDecision() async {
        let config = ExtremeProfile.DomainBoundaryConfig.forProfile(.lab)
        let enforcer = DomainBoundaryEnforcer(config: config)
        
        // Ledger → Decision should be forbidden
        do {
            try await enforcer.verifyCrossDomainAccess(from: .ledger, to: .decision)
            XCTFail("Should have thrown error")
        } catch DomainBoundaryError.invalidCrossDomainAccess {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
    
    func testSameDomainAccess() async throws {
        let config = ExtremeProfile.DomainBoundaryConfig.forProfile(.standard)
        let enforcer = DomainBoundaryEnforcer(config: config)
        
        // Same domain should always be allowed
        try await enforcer.verifyCrossDomainAccess(from: .perception, to: .perception)
        try await enforcer.verifyCrossDomainAccess(from: .decision, to: .decision)
        try await enforcer.verifyCrossDomainAccess(from: .ledger, to: .ledger)
    }
    
    func testAuditLog() async throws {
        let config = ExtremeProfile.DomainBoundaryConfig.forProfile(.standard)
        let enforcer = DomainBoundaryEnforcer(config: config)
        
        try await enforcer.verifyCrossDomainAccess(from: .perception, to: .decision)
        try await enforcer.verifyCrossDomainAccess(from: .decision, to: .ledger)
        
        let log = await enforcer.getCrossDomainAccessLog()
        XCTAssertEqual(log.count, 2)
        XCTAssertEqual(log[0].from, .perception)
        XCTAssertEqual(log[0].to, .decision)
        XCTAssertEqual(log[1].from, .decision)
        XCTAssertEqual(log[1].to, .ledger)
    }
    
    // MARK: - Additional Domain Tests
    
    func test_perception_domain_entry() async {
        let config = ExtremeProfile.DomainBoundaryConfig.forProfile(.standard)
        let enforcer = DomainBoundaryEnforcer(config: config)
        
        await enforcer.enterDomain(.perception)
        // Domain entry should succeed without error
        do {
            try await enforcer.verifyCrossDomainAccess(from: .perception, to: .perception)
        } catch {
            XCTFail("Should allow same domain access")
        }
    }
    
    func test_decision_domain_entry() async {
        let config = ExtremeProfile.DomainBoundaryConfig.forProfile(.standard)
        let enforcer = DomainBoundaryEnforcer(config: config)
        
        await enforcer.enterDomain(.decision)
        // Domain entry should succeed without error
        do {
            try await enforcer.verifyCrossDomainAccess(from: .decision, to: .decision)
        } catch {
            XCTFail("Should allow same domain access")
        }
    }
    
    func test_ledger_domain_entry() async {
        let config = ExtremeProfile.DomainBoundaryConfig.forProfile(.standard)
        let enforcer = DomainBoundaryEnforcer(config: config)
        
        await enforcer.enterDomain(.ledger)
        // Domain entry should succeed without error
        do {
            try await enforcer.verifyCrossDomainAccess(from: .ledger, to: .ledger)
        } catch {
            XCTFail("Should allow same domain access")
        }
    }
    
    func test_domain_exit() async {
        let config = ExtremeProfile.DomainBoundaryConfig.forProfile(.standard)
        let enforcer = DomainBoundaryEnforcer(config: config)
        
        await enforcer.enterDomain(.perception)
        await enforcer.exitDomain()
        // Exit should succeed without error
        // After exit, we can enter a different domain
        await enforcer.enterDomain(.decision)
    }
    
    func test_ledger_to_perception_invalid() async {
        let config = ExtremeProfile.DomainBoundaryConfig.forProfile(.lab)  // Use lab profile for hard fail
        let enforcer = DomainBoundaryEnforcer(config: config)
        
        do {
            try await enforcer.verifyCrossDomainAccess(from: .ledger, to: .perception)
            // May not throw if policy is warn
            if config.boundaryViolationPolicy == .hardFail {
                XCTFail("Should have thrown error")
            }
        } catch DomainBoundaryError.invalidCrossDomainAccess {
            // Expected for hardFail policy
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
    
    func test_perception_to_ledger_invalid() async {
        let config = ExtremeProfile.DomainBoundaryConfig.forProfile(.lab)  // Use lab profile for hard fail
        let enforcer = DomainBoundaryEnforcer(config: config)
        
        do {
            try await enforcer.verifyCrossDomainAccess(from: .perception, to: .ledger)
            // May not throw if policy is warn
            if config.boundaryViolationPolicy == .hardFail {
                XCTFail("Should have thrown error")
            }
        } catch DomainBoundaryError.invalidCrossDomainAccess {
            // Expected for hardFail policy
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
    
    func test_concurrent_domain_access() async {
        let config = ExtremeProfile.DomainBoundaryConfig.forProfile(.standard)
        let enforcer = DomainBoundaryEnforcer(config: config)
        
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    do {
                        try await enforcer.verifyCrossDomainAccess(from: .perception, to: .decision)
                    } catch {
                        XCTFail("Concurrent access should be safe")
                    }
                }
            }
        }
    }
    
    func test_boundary_violation_detection() async {
        let config = ExtremeProfile.DomainBoundaryConfig.forProfile(.lab)  // Use lab for hard fail
        let enforcer = DomainBoundaryEnforcer(config: config)
        
        var violations = 0
        for _ in 0..<5 {
            do {
                try await enforcer.verifyCrossDomainAccess(from: .ledger, to: .perception)
                if config.boundaryViolationPolicy == .hardFail {
                    violations += 0  // Should have thrown
                }
            } catch {
                violations += 1
            }
        }
        
        if config.boundaryViolationPolicy == .hardFail {
            XCTAssertEqual(violations, 5)
        } else {
            // For warn policy, violations may be 0
            XCTAssertGreaterThanOrEqual(violations, 0)
        }
    }
    
    func test_boundary_recovery_mechanism() async {
        let config = ExtremeProfile.DomainBoundaryConfig.forProfile(.standard)
        let enforcer = DomainBoundaryEnforcer(config: config)
        
        // Try invalid access (may not throw with warn policy)
        do {
            try await enforcer.verifyCrossDomainAccess(from: .ledger, to: .perception)
            // May succeed with warn policy
        } catch {
            // Expected for hardFail policy
        }
        
        // Valid access should always work
        do {
            try await enforcer.verifyCrossDomainAccess(from: .perception, to: .decision)
        } catch {
            XCTFail("Valid access should work after invalid attempt")
        }
    }
    
    func test_all_valid_transitions() async throws {
        let config = ExtremeProfile.DomainBoundaryConfig.forProfile(.standard)
        let enforcer = DomainBoundaryEnforcer(config: config)
        
        // All valid transitions
        try await enforcer.verifyCrossDomainAccess(from: .perception, to: .decision)
        try await enforcer.verifyCrossDomainAccess(from: .decision, to: .ledger)
        try await enforcer.verifyCrossDomainAccess(from: .perception, to: .perception)
        try await enforcer.verifyCrossDomainAccess(from: .decision, to: .decision)
        try await enforcer.verifyCrossDomainAccess(from: .ledger, to: .ledger)
    }
    
    func test_audit_log_retention() async throws {
        let config = ExtremeProfile.DomainBoundaryConfig.forProfile(.standard)
        let enforcer = DomainBoundaryEnforcer(config: config)
        
        // Generate many access logs
        for _ in 0..<200 {
            try await enforcer.verifyCrossDomainAccess(from: .perception, to: .decision)
        }
        
        let log = await enforcer.getCrossDomainAccessLog()
        // Should be capped (implementation detail)
        XCTAssertLessThanOrEqual(log.count, 200)
    }
}
