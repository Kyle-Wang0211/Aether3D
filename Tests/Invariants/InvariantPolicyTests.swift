// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

import XCTest
@testable import Aether3DCore

final class InvariantPolicyTests: XCTestCase {
    func testInvariantViolationPolicyStructure() {
        let policy = InvariantViolationPolicy(
            invariantName: "test_invariant",
            severity: .fatal,
            responseAction: .halt
        )
        
        XCTAssertEqual(policy.invariantName, "test_invariant")
        XCTAssertEqual(policy.severity, .fatal)
        XCTAssertEqual(policy.responseAction, .halt)
    }
    
    func testInvariantPoliciesNotEmpty() {
        XCTAssertFalse(INVARIANT_POLICIES.isEmpty, "INVARIANT_POLICIES must not be empty")
    }
    
    func testInvariantPoliciesFieldValidity() {
        for policy in INVARIANT_POLICIES {
            XCTAssertFalse(policy.invariantName.isEmpty, "invariantName must not be empty")
            
            switch policy.severity {
            case .fatal, .hardFail, .softFail:
                break
            }
            
            switch policy.responseAction {
            case .halt, .safeMode, .logContinue:
                break
            }
        }
    }
    
    func testGoldenPolicyHashNotEmpty() {
        XCTAssertFalse(GOLDEN_POLICY_HASH.isEmpty, "GOLDEN_POLICY_HASH must not be empty")
    }
    
    func testGoldenPolicyHashNotPlaceholder() {
        XCTAssertNotEqual(GOLDEN_POLICY_HASH, "PLACEHOLDER")
        XCTAssertNotEqual(GOLDEN_POLICY_HASH, "TODO")
        XCTAssertNotEqual(GOLDEN_POLICY_HASH, "TBD")
        XCTAssertNotEqual(GOLDEN_POLICY_HASH.lowercased(), "placeholder")
    }
}

