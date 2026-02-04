//
// MinimumProgressGuaranteeTests.swift
// PR5CaptureTests
//
// Tests for MinimumProgressGuarantee
//

import XCTest
@testable import PR5Capture

@MainActor
final class MinimumProgressGuaranteeTests: XCTestCase {
    
    var guarantee: MinimumProgressGuarantee!
    var config: ExtremeProfile!
    
    override func setUp() {
        super.setUp()
        config = ExtremeProfile(profile: .standard)
        guarantee = MinimumProgressGuarantee(config: config)
    }
    
    override func tearDown() {
        guarantee = nil
        config = nil
        super.tearDown()
    }
    
    func testStagnationDetection() async {
        // Record low progress (stagnation)
        let threshold = PR5CaptureConstants.getValue(
            PR5CaptureConstants.Disposition.minimumProgressThreshold,
            profile: .standard
        )
        
        for i in 0..<5 {
            _ = await guarantee.recordProgress(frameId: UInt64(i), progress: threshold * 0.5)
        }
        
        let multiplier = await guarantee.getIncrementMultiplier()
        XCTAssertGreaterThan(multiplier, 1.0)  // Should increase multiplier
    }
    
    func testProgressRecovery() async {
        // Record stagnation
        let threshold = PR5CaptureConstants.getValue(
            PR5CaptureConstants.Disposition.minimumProgressThreshold,
            profile: .standard
        )
        
        for i in 0..<5 {
            _ = await guarantee.recordProgress(frameId: UInt64(i), progress: threshold * 0.5)
        }
        
        // Record good progress
        for i in 5..<10 {
            _ = await guarantee.recordProgress(frameId: UInt64(i), progress: threshold * 1.5)
        }
        
        // Multiplier should decrease
        let multiplier = await guarantee.getIncrementMultiplier()
        XCTAssertGreaterThanOrEqual(multiplier, 1.0)
    }
}
