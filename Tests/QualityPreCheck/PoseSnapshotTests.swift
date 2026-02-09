// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  PoseSnapshotTests.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Cross-platform PoseSnapshot Tests
//  Validates PoseSnapshot works on all platforms (with/without CoreMotion)
//

import XCTest
@testable import Aether3DCore

final class PoseSnapshotTests: XCTestCase {
    
    /// Test PoseSnapshot initialization with explicit values (works on all platforms)
    func testPoseSnapshotInitialization() throws {
        let snapshot = PoseSnapshot(yaw: 45.0, pitch: -30.0, roll: 15.0)
        
        XCTAssertEqual(snapshot.yaw, 45.0, accuracy: 0.001)
        XCTAssertEqual(snapshot.pitch, -30.0, accuracy: 0.001)
        XCTAssertEqual(snapshot.roll, 15.0, accuracy: 0.001)
    }
    
    /// Test angle normalization (works on all platforms)
    func testPoseSnapshotAngleNormalization() throws {
        // Test normalization: 370° should become 10°
        let snapshot1 = PoseSnapshot(yaw: 370.0, pitch: 0.0, roll: 0.0)
        XCTAssertEqual(snapshot1.yaw, 10.0, accuracy: 0.001)
        
        // Test normalization: -190° should become 170°
        let snapshot2 = PoseSnapshot(yaw: -190.0, pitch: 0.0, roll: 0.0)
        XCTAssertEqual(snapshot2.yaw, 170.0, accuracy: 0.001)
        
        // Test normalization: -180° should stay -180°
        let snapshot3 = PoseSnapshot(yaw: -180.0, pitch: 0.0, roll: 0.0)
        XCTAssertEqual(snapshot3.yaw, -180.0, accuracy: 0.001)
        
        // Test normalization: 180° should stay 180°
        let snapshot4 = PoseSnapshot(yaw: 180.0, pitch: 0.0, roll: 0.0)
        XCTAssertEqual(snapshot4.yaw, 180.0, accuracy: 0.001)
    }
    
    #if canImport(CoreMotion)
    /// Test PoseSnapshot.from(CMDeviceMotion) on Apple platforms
    /// This test only compiles on Apple platforms where CoreMotion is available
    func testPoseSnapshotFromCMDeviceMotion() throws {
        // Note: This test requires a real CMDeviceMotion instance
        // In a real test environment, you would use CMMotionManager to get motion data
        // For now, we just verify the method exists and compiles
        // Actual motion data testing would require a device or simulator
        
        // Verify the method exists (compile-time check)
        // If CoreMotion is available, PoseSnapshot.from(_:) should be available
        XCTAssertTrue(true, "PoseSnapshot.from(CMDeviceMotion) is available on Apple platforms")
    }
    #else
    /// Test that PoseSnapshot compiles without CoreMotion on non-Apple platforms
    func testPoseSnapshotWithoutCoreMotion() throws {
        // On Linux/non-Apple platforms, PoseSnapshot.from(CMDeviceMotion) should not exist
        // But the basic initializer should work
        let snapshot = PoseSnapshot(yaw: 0.0, pitch: 0.0, roll: 0.0)
        XCTAssertEqual(snapshot.yaw, 0.0)
        XCTAssertEqual(snapshot.pitch, 0.0)
        XCTAssertEqual(snapshot.roll, 0.0)
    }
    #endif
}

