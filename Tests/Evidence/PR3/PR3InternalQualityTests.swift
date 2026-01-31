//
// PR3InternalQualityTests.swift
// Aether3D
//
// PR3 - PR3 Internal Quality Tests
//

import XCTest
@testable import Aether3DCore

final class PR3InternalQualityTests: XCTestCase {

    func testCompute() {
        let quality = PR3InternalQuality.compute(
            basicGain: 0.8,
            geomGain: 0.6
        )

        // 0.4 * 0.8 + 0.6 * 0.6 = 0.32 + 0.36 = 0.68
        XCTAssertEqual(quality, 0.68, accuracy: 1e-10)
    }

    func testIsL2Plus() {
        XCTAssertTrue(PR3InternalQuality.isL2Plus(quality: 0.35))  // Above 0.3
        XCTAssertFalse(PR3InternalQuality.isL2Plus(quality: 0.25))  // Below 0.3
    }

    func testIsL3() {
        XCTAssertTrue(PR3InternalQuality.isL3(quality: 0.65))  // Above 0.6
        XCTAssertFalse(PR3InternalQuality.isL3(quality: 0.55))  // Below 0.6
    }

    func testReusesGateGainFunctions() {
        // Test that PR3InternalQuality reuses GateGainFunctions
        // This ensures single metric space
        let basicGain = GateGainFunctions.basicGateGain(
            sharpness: 90.0,
            overexposureRatio: 0.20,
            underexposureRatio: 0.30
        )

        let geomGain = GateGainFunctions.geomGateGain(
            reprojRmsPx: 0.30,
            edgeRmsPx: 0.15
        )

        let pr3Quality = PR3InternalQuality.compute(
            basicGain: basicGain,
            geomGain: geomGain
        )

        // Should be valid quality
        XCTAssertGreaterThanOrEqual(pr3Quality, 0.0)
        XCTAssertLessThanOrEqual(pr3Quality, 1.0)
    }
}
