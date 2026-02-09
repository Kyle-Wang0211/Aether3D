// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// PoseChainPreserverTests.swift
// PR5CaptureTests
//
// Tests for PoseChainPreserver
//

import XCTest
@testable import PR5Capture

@MainActor
final class PoseChainPreserverTests: XCTestCase {
    
    var preserver: PoseChainPreserver!
    var config: ExtremeProfile!
    
    override func setUp() async throws {
        config = ExtremeProfile(profile: .standard)
        preserver = PoseChainPreserver(config: config)
    }
    
    override func tearDown() async throws {
        preserver = nil
        config = nil
    }
    
    func testAddPose() async {
        let pose = PoseChainPreserver.Pose(
            position: SIMD3<Double>(1.0, 2.0, 3.0),
            orientation: SIMD4<Double>(0.0, 0.0, 0.0, 1.0)
        )
        
        let features = (0..<20).map { i in
            PoseChainPreserver.Feature(
                id: UInt64(i),
                position: SIMD2<Double>(Double(i), Double(i)),
                descriptor: Data()
            )
        }
        
        await preserver.addPose(frameId: 1, pose: pose, features: features, imuData: nil)
        
        let chain = await preserver.getPoseChain()
        XCTAssertEqual(chain.count, 1)
    }
    
    func testCreateTrackingSummary() async {
        let pose = PoseChainPreserver.Pose(
            position: SIMD3<Double>(1.0, 2.0, 3.0),
            orientation: SIMD4<Double>(0.0, 0.0, 0.0, 1.0)
        )
        
        let features = (0..<20).map { i in
            PoseChainPreserver.Feature(
                id: UInt64(i),
                position: SIMD2<Double>(Double(i), Double(i)),
                descriptor: Data()
            )
        }
        
        await preserver.addPose(frameId: 1, pose: pose, features: features, imuData: nil)
        
        let summary = await preserver.createTrackingSummary(frameId: 1, minFeatures: 10)
        XCTAssertNotNil(summary)
        XCTAssertEqual(summary?.features.count, 10)  // Should preserve min features
    }
}
