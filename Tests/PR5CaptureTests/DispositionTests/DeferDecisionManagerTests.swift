//
// DeferDecisionManagerTests.swift
// PR5CaptureTests
//
// Tests for DeferDecisionManager
//

import XCTest
@testable import PR5Capture

@MainActor
final class DeferDecisionManagerTests: XCTestCase {
    
    var manager: DeferDecisionManager!
    var config: ExtremeProfile!
    
    override func setUp() async throws {
        config = ExtremeProfile(profile: .standard)
        manager = DeferDecisionManager(config: config)
    }
    
    override func tearDown() async throws {
        manager = nil
        config = nil
    }
    
    func testDeferDecision() async {
        let result = await manager.deferDecision(
            frameId: 1,
            reason: "Test defer",
            priority: .normal
        )
        
        switch result {
        case .deferred(let decisionId, let deadline):
            XCTAssertNotNil(decisionId)
            XCTAssertGreaterThan(deadline, Date())
        case .queueFull:
            XCTFail("Should not be queue full")
        }
    }
    
    func testQueueFull() async {
        // Fill queue to max
        let maxDepth = PR5CaptureConstants.getValue(
            PR5CaptureConstants.Disposition.deferQueueMaxDepth,
            profile: .standard
        )
        
        for i in 0..<maxDepth {
            _ = await manager.deferDecision(frameId: UInt64(i), reason: "Fill queue")
        }
        
        // Try to add one more
        let result = await manager.deferDecision(frameId: UInt64(maxDepth), reason: "Should fail")
        
        switch result {
        case .queueFull:
            break  // Expected
        case .deferred:
            XCTFail("Should be queue full")
        }
    }
    
    func testResolveDecision() async {
        let deferResult = await manager.deferDecision(frameId: 1, reason: "Test")
        guard case .deferred(let decisionId, _) = deferResult else {
            XCTFail("Should have deferred")
            return
        }
        
        let resolved = await manager.resolveDecision(decisionId: decisionId, result: .accept)
        XCTAssertTrue(resolved)
        
        let pendingCount = await manager.getPendingCount()
        XCTAssertEqual(pendingCount, 0)
    }
}
