//
// RelocalizationStateManagerTests.swift
// PR5CaptureTests
//
// Tests for RelocalizationStateManager
//

import XCTest
@testable import PR5Capture

@MainActor
final class RelocalizationStateManagerTests: XCTestCase {
    
    var manager: RelocalizationStateManager!
    var config: ExtremeProfile!
    
    override func setUp() async throws {
        config = ExtremeProfile(profile: .standard)
        manager = RelocalizationStateManager(config: config)
    }
    
    override func tearDown() async throws {
        manager = nil
        config = nil
    }
    
    func testTrackingToRelocalizing() async {
        // Start with high confidence (tracking)
        _ = await manager.updateConfidence(0.8)
        
        // Drop confidence below threshold
        let result = await manager.updateConfidence(0.4)
        
        guard case .stateChanged(let to, _) = result else {
            XCTFail("Should transition to relocalizing")
            return
        }
        XCTAssertEqual(to, .relocalizing)
    }
    
    func testRelocalizationSuccess() async {
        // Enter relocalizing state
        _ = await manager.updateConfidence(0.4)
        
        // Recover confidence
        let result = await manager.updateConfidence(0.8)
        
        guard case .stateChanged(let to, _) = result else {
            XCTFail("Should transition back to tracking")
            return
        }
        XCTAssertEqual(to, .tracking)
    }
    
    func testForceRelocalization() async {
        await manager.forceRelocalization()
        
        let state = await manager.getCurrentState()
        XCTAssertEqual(state, .relocalizing)
    }
}
