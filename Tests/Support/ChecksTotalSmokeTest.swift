//
// ChecksTotalSmokeTest.swift
// Aether3D
//
// PR1 v2.4 Addendum - Checks Total Verification
//
// Final test that verifies total check count >= 1000
//

import XCTest
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
    func testChecksTotal_MeetsMinimum() {
        let totalChecks = CheckCounter.get()
        
        // Print for CI visibility
        print("CHECKS_TOTAL=\(totalChecks)")
        
        // Assert minimum requirement
        XCTAssertGreaterThanOrEqual(totalChecks, 1000, "Verification suite must have >= 1000 checks. Current: \(totalChecks)")
        
        // Also print breakdown if available
        print("Verification suite check count: \(totalChecks)")
    }
}

/// XCTestObserver to print check count at suite end
final class CheckCountObserver: NSObject, XCTestObservation {
    static let shared = CheckCountObserver()
    
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

