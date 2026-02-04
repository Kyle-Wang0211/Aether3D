//
// CrossPlatformNormalizerTests.swift
// PR5CaptureTests
//
// Tests for CrossPlatformNormalizer
//

import XCTest
@testable import PR5Capture

@MainActor
final class CrossPlatformNormalizerTests: XCTestCase {
    
    var normalizer: CrossPlatformNormalizer!
    var config: ExtremeProfile!
    
    override func setUp() {
        super.setUp()
        config = ExtremeProfile(profile: .standard)
        normalizer = CrossPlatformNormalizer(config: config)
    }
    
    override func tearDown() {
        normalizer = nil
        config = nil
        super.tearDown()
    }
    
    func testNormalize() async {
        let value = 0.123456789012345
        let normalized = await normalizer.normalize(value)
        XCTAssertNotEqual(value, normalized)  // Should be rounded
    }
    
    func testAreEqual() async {
        let a = 0.123456789012345
        let b = 0.123456789012346
        let equal = await normalizer.areEqual(a, b)
        XCTAssertTrue(equal)  // Should be equal after normalization
    }
}
