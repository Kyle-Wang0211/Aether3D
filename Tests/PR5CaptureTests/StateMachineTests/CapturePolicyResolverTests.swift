//
// CapturePolicyResolverTests.swift
// PR5CaptureTests
//
// Tests for CapturePolicyResolver
//

import XCTest
@testable import PR5Capture

@MainActor
final class CapturePolicyResolverTests: XCTestCase {
    
    var resolver: CapturePolicyResolver!
    var config: ExtremeProfile!
    
    override func setUp() {
        super.setUp()
        config = ExtremeProfile(profile: .standard)
        resolver = CapturePolicyResolver(config: config)
    }
    
    override func tearDown() {
        resolver = nil
        config = nil
        super.tearDown()
    }
    
    func testPolicyRegistration() async {
        let policy = CapturePolicyResolver.CapturePolicy(
            qualityThreshold: 0.8,
            frameRate: 30,
            resolution: .high
        )
        
        await resolver.registerPolicy(policy, from: .user)
        
        let resolved = await resolver.resolvePolicy()
        XCTAssertEqual(resolved.qualityThreshold, 0.8, accuracy: 0.001)
    }
    
    func testConflictArbitration() async {
        // Register conflicting policies
        let policy1 = CapturePolicyResolver.CapturePolicy(
            qualityThreshold: 0.7,
            frameRate: 30,
            resolution: .standard
        )
        let policy2 = CapturePolicyResolver.CapturePolicy(
            qualityThreshold: 0.9,
            frameRate: 60,
            resolution: .high
        )
        
        await resolver.registerPolicy(policy1, from: .user)
        await resolver.registerPolicy(policy2, from: .system)
        
        let resolved = await resolver.resolvePolicy()
        
        // Should use most restrictive (highest quality threshold, lowest frame rate)
        XCTAssertEqual(resolved.qualityThreshold, 0.9, accuracy: 0.001)
        XCTAssertEqual(resolved.frameRate, 30)  // Lower frame rate is more restrictive
    }
    
    func testISPCompensation() async {
        let policy = CapturePolicyResolver.CapturePolicy(
            qualityThreshold: 0.8,
            frameRate: 30,
            resolution: .standard
        )
        
        await resolver.registerPolicy(policy, from: .user)
        await resolver.updateISPCompensation(1.2)  // 20% compensation
        
        let resolved = await resolver.resolvePolicy()
        XCTAssertEqual(resolved.qualityThreshold, 0.8 * 1.2, accuracy: 0.001)
        XCTAssertEqual(resolved.ispCompensation, 1.2, accuracy: 0.001)
    }
}
