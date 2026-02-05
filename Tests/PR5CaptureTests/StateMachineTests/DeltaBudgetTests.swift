//
// DeltaBudgetTests.swift
// PR5CaptureTests
//
// Tests for DeltaBudget
//

import XCTest
@testable import PR5Capture

@MainActor
final class DeltaBudgetTests: XCTestCase {
    
    var budget: DeltaBudget!
    var config: ExtremeProfile!
    
    override func setUp() async throws {
        config = ExtremeProfile(profile: .standard)
        budget = DeltaBudget(config: config)
    }
    
    override func tearDown() async throws {
        budget = nil
        config = nil
    }
    
    func testDeltaApplication() async {
        let result = await budget.canApplyDelta(0.3, reason: "Test")
        
        switch result {
        case .allowed(let delta, let remaining):
            XCTAssertEqual(delta, 0.3, accuracy: 0.001)
            XCTAssertEqual(remaining, 0.7, accuracy: 0.001)
        case .exceeded:
            XCTFail("Should be allowed")
        }
    }
    
    func testBudgetExceeded() async {
        // Use most of budget
        _ = await budget.canApplyDelta(0.9, reason: "Test")
        
        // Try to exceed remaining
        let result = await budget.canApplyDelta(0.2, reason: "Test")
        
        switch result {
        case .allowed:
            XCTFail("Should be exceeded")
        case .exceeded(let requested, let available, _):
            XCTAssertGreaterThan(requested, available)
        }
    }
    
    func testBudgetReset() async {
        // Use some budget
        _ = await budget.canApplyDelta(0.5, reason: "Test")
        
        // Wait for reset interval
        try? await Task.sleep(nanoseconds: 1_100_000_000)  // 1.1 seconds
        
        // Budget should be reset
        let currentBudget = await budget.getCurrentBudget()
        XCTAssertEqual(currentBudget, 1.0, accuracy: 0.001)
    }
}
