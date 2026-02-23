// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// ChecksTotalSmokeTest.swift
// Aether3D
//
// PR1 v2.4 Addendum - Checks Total Verification
//
// Final test that verifies total check count >= 1000
//

import XCTest
import Foundation
@testable import Aether3DCore

final class ChecksTotalSmokeTest: XCTestCase {

    // MARK: - Setup

    override class func setUp() {
        super.setUp()
        XCTestObservationCenter.shared.addTestObserver(CheckCountObserver.shared)
    }

    /// Final test: Verify total check count >= 1000
    ///
    /// **P0 Contract:**
    /// - Must run after all other tests
    /// - Asserts CHECKS_TOTAL >= 1000
    /// - Prints check count for CI visibility
    func testChecksTotal_MeetsMinimum() throws {
        let totalChecks = CheckCounter.get()
        
        // Print for CI visibility
        print("CHECKS_TOTAL=\(totalChecks)")

        // This gate is meaningful only when running the full suite in one process.
        // Resume runs (skip-lists / filtered runs) do not carry full counter context.
        let env = ProcessInfo.processInfo.environment
        let shouldEnforce =
            env["AETHER_ENFORCE_CHECKS_TOTAL"] == "1" ||
            env["CI"] == "true" ||
            env["GITHUB_ACTIONS"] == "true"

        if shouldEnforce {
            // Assert minimum requirement in CI/full-suite enforcement mode.
            XCTAssertGreaterThanOrEqual(totalChecks, 1000, "Verification suite must have >= 1000 checks. Current: \(totalChecks)")
        } else {
            // Local partial runs stay executable without skip; still sanity-check counter health.
            XCTAssertGreaterThanOrEqual(totalChecks, 0, "CHECKS_TOTAL should never be negative")
            print("CHECKS_TOTAL gate in observation mode (set AETHER_ENFORCE_CHECKS_TOTAL=1 to enforce >= 1000).")
        }
        
        // Also print breakdown if available
        print("Verification suite check count: \(totalChecks)")
    }
}

/// XCTestObserver to print check count at suite end
final class CheckCountObserver: NSObject, XCTestObservation {
    nonisolated(unsafe) static let shared = CheckCountObserver()
    
    func testSuiteDidFinish(_ testSuite: XCTestSuite) {
        if testSuite.name.contains("All tests") || testSuite.name.contains("Aether3DPackageTests") {
            let totalChecks = CheckCounter.get()
            print("\n========================================")
            print("VERIFICATION SUITE SUMMARY")
            print("========================================")
            print("CHECKS_TOTAL=\(totalChecks)")
            print("========================================\n")
        }
    }
}

