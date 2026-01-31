//
// GateGainFunctionsTests.swift
// Aether3D
//
// PR3 - Gate Gain Functions Tests
//

import XCTest
@testable import Aether3DCore

final class GateGainFunctionsTests: XCTestCase {

    func testViewGateGainBelowThresholds() {
        let gain = GateGainFunctions.viewGateGain(
            thetaSpanDeg: 10,  // Below 26
            phiSpanDeg: 5,     // Below 15
            l2PlusCount: 5,    // Below 13
            l3Count: 2         // Below 5
        )

        // Should be low but not zero (minimum floor)
        XCTAssertGreaterThanOrEqual(gain, HardGatesV13.minViewGain)
        XCTAssertLessThan(gain, 0.30)
    }

    func testViewGateGainAtThresholds() {
        let gain = GateGainFunctions.viewGateGain(
            thetaSpanDeg: 26,
            phiSpanDeg: 15,
            l2PlusCount: 13,
            l3Count: 5
        )

        // At threshold, sigmoid is around 0.5 for each component
        // Combined view gain = average of 4 sigmoids, each ≈ 0.5
        // But with minViewGain floor and geometric mean effects
        XCTAssertGreaterThanOrEqual(gain, HardGatesV13.minViewGain)
        XCTAssertLessThan(gain, 0.80)
    }

    func testViewGateGainAboveThresholds() {
        let gain = GateGainFunctions.viewGateGain(
            thetaSpanDeg: 50,
            phiSpanDeg: 30,
            l2PlusCount: 25,
            l3Count: 10
        )

        // Should be high
        XCTAssertGreaterThan(gain, 0.70)
    }

    func testGeomGateGainLowError() {
        let gain = GateGainFunctions.geomGateGain(
            reprojRmsPx: 0.20,  // Well below 0.48
            edgeRmsPx: 0.10     // Well below 0.23
        )

        XCTAssertGreaterThan(gain, 0.80)
    }

    func testGeomGateGainHighError() {
        let gain = GateGainFunctions.geomGateGain(
            reprojRmsPx: 0.80,  // Above 0.48
            edgeRmsPx: 0.40     // Above 0.23
        )

        XCTAssertLessThan(gain, 0.30)
    }

    func testBasicGateGainGoodQuality() {
        let gain = GateGainFunctions.basicGateGain(
            sharpness: 95,
            overexposureRatio: 0.10,
            underexposureRatio: 0.15
        )

        XCTAssertGreaterThanOrEqual(gain, HardGatesV13.minBasicGain)
        XCTAssertGreaterThan(gain, 0.70)
    }

    func testBasicGateGainBadExposure() {
        let gain = GateGainFunctions.basicGateGain(
            sharpness: 95,
            overexposureRatio: 0.50,  // Bad
            underexposureRatio: 0.15
        )

        XCTAssertGreaterThanOrEqual(gain, HardGatesV13.minBasicGain)
        XCTAssertLessThan(gain, 0.50)
    }

    func testGateQualityWeightsValid() {
        XCTAssertTrue(GateGainFunctions.GateWeights.validate())
    }

    func testGateQualityAllGood() {
        let quality = GateGainFunctions.gateQuality(
            viewGain: 0.9,
            geomGain: 0.9,
            basicGain: 0.9
        )

        XCTAssertGreaterThan(quality, 0.85)
        XCTAssertLessThanOrEqual(quality, 1.0)
    }

    func testGateQualityClamped() {
        // Test output is clamped to [0, 1]
        let quality = GateGainFunctions.gateQuality(
            viewGain: 2.0,  // Invalid input
            geomGain: 2.0,
            basicGain: 2.0
        )

        XCTAssertLessThanOrEqual(quality, 1.0)
    }
}
