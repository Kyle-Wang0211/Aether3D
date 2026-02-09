// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// DualAnchorManagerTests.swift
// PR5CaptureTests
//
// Tests for DualAnchorManager
//

import XCTest
@testable import PR5Capture

@MainActor
final class DualAnchorManagerTests: XCTestCase {
    
    func testSessionAnchorInitialization() async {
        let config = ExtremeProfile.DualAnchorConfig.forProfile(.standard)
        let manager = DualAnchorManager(config: config)
        
        let anchor = DualAnchorManager.AnchorValue(value: 0.5)
        await manager.initializeSessionAnchor(anchor)
        
        let retrieved = await manager.getSessionAnchor()
        XCTAssertNotNil(retrieved)
        if let value = retrieved {
            XCTAssertEqual(value.value, 0.5, accuracy: 0.001)
        }
    }
    
    func testSegmentAnchorUpdate() async {
        let config = ExtremeProfile.DualAnchorConfig.forProfile(.standard)
        let manager = DualAnchorManager(config: config)
        
        let anchor = DualAnchorManager.AnchorValue(value: 0.7)
        await manager.updateSegmentAnchor(anchor)
        
        let retrieved = await manager.getSegmentAnchor()
        XCTAssertNotNil(retrieved)
        if let value = retrieved {
            XCTAssertEqual(value.value, 0.7, accuracy: 0.001)
        }
    }
    
    func testDriftDetection() async {
        let config = ExtremeProfile.DualAnchorConfig.forProfile(.standard)
        let manager = DualAnchorManager(config: config)
        
        // Initialize anchors
        let sessionAnchor = DualAnchorManager.AnchorValue(value: 0.5)
        await manager.initializeSessionAnchor(sessionAnchor)
        
        let segmentAnchor = DualAnchorManager.AnchorValue(value: 0.6)
        await manager.updateSegmentAnchor(segmentAnchor)
        
        // Check drift with value close to anchors (no drift)
        let closeValue = DualAnchorManager.AnchorValue(value: 0.55)
        let result1 = await manager.checkDrift(closeValue)
        XCTAssertFalse(result1.hasDrift)
        
        // Check drift with value far from anchors (has drift)
        let farValue = DualAnchorManager.AnchorValue(value: 0.9)
        let result2 = await manager.checkDrift(farValue)
        XCTAssertTrue(result2.hasDrift)
    }
    
    func testSessionAnchorUpdateInterval() async {
        let config = ExtremeProfile.DualAnchorConfig.forProfile(.standard)
        let manager = DualAnchorManager(config: config)
        
        // Initialize anchor
        let anchor1 = DualAnchorManager.AnchorValue(value: 0.5)
        await manager.initializeSessionAnchor(anchor1)
        
        // Try to update immediately (should not update)
        let anchor2 = DualAnchorManager.AnchorValue(value: 0.6)
        let updated1 = await manager.updateSessionAnchorIfNeeded(anchor2)
        XCTAssertFalse(updated1)
        
        // Wait for update interval
        try? await Task.sleep(nanoseconds: UInt64((config.sessionAnchorUpdateInterval + 0.1) * 1_000_000_000))
        
        // Now should update
        let updated2 = await manager.updateSessionAnchorIfNeeded(anchor2)
        XCTAssertTrue(updated2)
        
        let retrieved = await manager.getSessionAnchor()
        XCTAssertNotNil(retrieved)
        if let value = retrieved {
            XCTAssertEqual(value.value, 0.6, accuracy: 0.001)
        }
    }
    
    // MARK: - Additional Anchor Tests
    
    func test_session_anchor_creation() async {
        let config = ExtremeProfile.DualAnchorConfig.forProfile(.standard)
        let manager = DualAnchorManager(config: config)
        
        let anchor = DualAnchorManager.AnchorValue(value: 0.75)
        await manager.initializeSessionAnchor(anchor)
        
        let retrieved = await manager.getSessionAnchor()
        XCTAssertNotNil(retrieved)
        if let value = retrieved {
            XCTAssertEqual(value.value, 0.75, accuracy: 0.001)
        }
    }
    
    func test_session_anchor_validation() async {
        let config = ExtremeProfile.DualAnchorConfig.forProfile(.standard)
        let manager = DualAnchorManager(config: config)
        
        let anchor = DualAnchorManager.AnchorValue(value: 0.8)
        await manager.initializeSessionAnchor(anchor)
        
        // Validate anchor exists
        let retrieved = await manager.getSessionAnchor()
        XCTAssertNotNil(retrieved)
        if let value = retrieved {
            XCTAssertEqual(value.value, 0.8, accuracy: 0.001)
        }
    }
    
    func test_segment_anchor_creation() async {
        let config = ExtremeProfile.DualAnchorConfig.forProfile(.standard)
        let manager = DualAnchorManager(config: config)
        
        let anchor = DualAnchorManager.AnchorValue(value: 0.65)
        await manager.updateSegmentAnchor(anchor)
        
        let retrieved = await manager.getSegmentAnchor()
        XCTAssertNotNil(retrieved)
        if let value = retrieved {
            XCTAssertEqual(value.value, 0.65, accuracy: 0.001)
        }
    }
    
    func test_dual_anchor_synchronization() async {
        let config = ExtremeProfile.DualAnchorConfig.forProfile(.standard)
        let manager = DualAnchorManager(config: config)
        
        let sessionAnchor = DualAnchorManager.AnchorValue(value: 0.7)
        await manager.initializeSessionAnchor(sessionAnchor)
        
        let segmentAnchor = DualAnchorManager.AnchorValue(value: 0.72)
        await manager.updateSegmentAnchor(segmentAnchor)
        
        // Both anchors should be set
        let session = await manager.getSessionAnchor()
        let segment = await manager.getSegmentAnchor()
        
        XCTAssertNotNil(session)
        XCTAssertNotNil(segment)
        if let sessionValue = session {
            XCTAssertEqual(sessionValue.value, 0.7, accuracy: 0.001)
        }
        if let segmentValue = segment {
            XCTAssertEqual(segmentValue.value, 0.72, accuracy: 0.001)
        }
    }
    
    func test_anchor_loss_recovery() async {
        let config = ExtremeProfile.DualAnchorConfig.forProfile(.standard)
        let manager = DualAnchorManager(config: config)
        
        // Initialize anchor
        let anchor1 = DualAnchorManager.AnchorValue(value: 0.6)
        await manager.initializeSessionAnchor(anchor1)
        
        // Simulate anchor loss by checking drift with very different value
        let farValue = DualAnchorManager.AnchorValue(value: 0.99)
        let driftResult = await manager.checkDrift(farValue)
        XCTAssertTrue(driftResult.hasDrift)
        
        // Re-initialize anchor
        let anchor2 = DualAnchorManager.AnchorValue(value: 0.7)
        await manager.initializeSessionAnchor(anchor2)
        
        let recovered = await manager.getSessionAnchor()
        XCTAssertNotNil(recovered)
        if let recoveredValue = recovered {
            XCTAssertEqual(recoveredValue.value, 0.7, accuracy: 0.001)
        }
    }
    
    func test_extreme_timestamp_handling() async {
        let config = ExtremeProfile.DualAnchorConfig.forProfile(.standard)
        let manager = DualAnchorManager(config: config)
        
        // Test with extreme values
        let extremeLow = DualAnchorManager.AnchorValue(value: 0.0)
        let extremeHigh = DualAnchorManager.AnchorValue(value: 1.0)
        
        await manager.initializeSessionAnchor(extremeLow)
        let lowResult = await manager.checkDrift(extremeHigh)
        XCTAssertTrue(lowResult.hasDrift)
        
        await manager.initializeSessionAnchor(extremeHigh)
        let highResult = await manager.checkDrift(extremeLow)
        XCTAssertTrue(highResult.hasDrift)
    }
    
    func test_concurrent_anchor_operations() async {
        let config = ExtremeProfile.DualAnchorConfig.forProfile(.standard)
        let manager = DualAnchorManager(config: config)
        
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    let anchor = DualAnchorManager.AnchorValue(value: Double(i) / 10.0)
                    await manager.updateSegmentAnchor(anchor)
                }
            }
        }
        
        // Should have final anchor set
        let final = await manager.getSegmentAnchor()
        XCTAssertNotNil(final)
    }
    
    func test_anchor_drift_thresholds() async {
        let config = ExtremeProfile.DualAnchorConfig.forProfile(.standard)
        let manager = DualAnchorManager(config: config)
        
        let anchor = DualAnchorManager.AnchorValue(value: 0.5)
        await manager.initializeSessionAnchor(anchor)
        
        // Test values near threshold
        let nearValue = DualAnchorManager.AnchorValue(value: 0.51)
        let nearResult = await manager.checkDrift(nearValue)
        
        // Should not drift if within threshold
        XCTAssertFalse(nearResult.hasDrift)
    }
    
    func test_evidence_velocity_comparison() async {
        let config = ExtremeProfile.DualAnchorConfig.forProfile(.standard)
        let manager = DualAnchorManager(config: config)
        
        let anchor1 = DualAnchorManager.AnchorValue(value: 0.5)
        await manager.initializeSessionAnchor(anchor1)
        
        let anchor2 = DualAnchorManager.AnchorValue(value: 0.6)
        await manager.updateSegmentAnchor(anchor2)
        
        // Check drift should compare velocities
        let current = DualAnchorManager.AnchorValue(value: 0.7)
        let result = await manager.checkDrift(current)
        
        // Result should include velocity information
        XCTAssertNotNil(result.sessionDrift)
        XCTAssertNotNil(result.segmentDrift)
    }
    
    func test_anchor_update_interval_enforcement() async {
        let config = ExtremeProfile.DualAnchorConfig.forProfile(.standard)
        let manager = DualAnchorManager(config: config)
        
        let anchor1 = DualAnchorManager.AnchorValue(value: 0.5)
        await manager.initializeSessionAnchor(anchor1)
        
        // Try immediate update
        let anchor2 = DualAnchorManager.AnchorValue(value: 0.6)
        let updated1 = await manager.updateSessionAnchorIfNeeded(anchor2)
        XCTAssertFalse(updated1)
        
        // Wait for interval
        try? await Task.sleep(nanoseconds: UInt64((config.sessionAnchorUpdateInterval + 0.1) * 1_000_000_000))
        
        // Now should update
        let updated2 = await manager.updateSessionAnchorIfNeeded(anchor2)
        XCTAssertTrue(updated2)
    }
}
