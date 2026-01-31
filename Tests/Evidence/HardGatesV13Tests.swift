//
// HardGatesV13Tests.swift
// Aether3D
//
// PR3 - HardGatesV13 Constants Tests
//

import XCTest
@testable import Aether3DCore

final class HardGatesV13Tests: XCTestCase {

    func testThresholdsInAcceptableRanges() {
        // Test all thresholds are within acceptable ranges
        XCTAssertTrue(HardGatesV13.AcceptableRanges.reprojThreshold.contains(HardGatesV13.reprojThreshold))
        XCTAssertTrue(HardGatesV13.AcceptableRanges.edgeThreshold.contains(HardGatesV13.edgeThreshold))
        XCTAssertTrue(HardGatesV13.AcceptableRanges.thetaThreshold.contains(HardGatesV13.thetaThreshold))
        XCTAssertTrue(HardGatesV13.AcceptableRanges.phiThreshold.contains(HardGatesV13.phiThreshold))
        XCTAssertTrue(HardGatesV13.AcceptableRanges.l2PlusThreshold.contains(HardGatesV13.l2PlusThreshold))
        XCTAssertTrue(HardGatesV13.AcceptableRanges.l3Threshold.contains(HardGatesV13.l3Threshold))
        XCTAssertTrue(HardGatesV13.AcceptableRanges.sharpnessThreshold.contains(HardGatesV13.sharpnessThreshold))
        XCTAssertTrue(HardGatesV13.AcceptableRanges.overexposureThreshold.contains(HardGatesV13.overexposureThreshold))
        XCTAssertTrue(HardGatesV13.AcceptableRanges.underexposureThreshold.contains(HardGatesV13.underexposureThreshold))
    }

    func testSlopesComputedFromTransitionWidth() {
        // Test slopes are computed correctly from transition width
        let reprojSlope = HardGatesV13.reprojTransitionWidth / 4.4
        XCTAssertEqual(HardGatesV13.reprojSlope, reprojSlope, accuracy: 1e-10)

        let edgeSlope = HardGatesV13.edgeTransitionWidth / 4.4
        XCTAssertEqual(HardGatesV13.edgeSlope, edgeSlope, accuracy: 1e-10)

        let thetaSlope = HardGatesV13.thetaTransitionWidth / 4.4
        XCTAssertEqual(HardGatesV13.thetaSlope, thetaSlope, accuracy: 1e-10)
    }

    func testGainFloors() {
        // Test gain floors are correct
        XCTAssertEqual(HardGatesV13.minViewGain, 0.05)
        XCTAssertEqual(HardGatesV13.minBasicGain, 0.10)
        XCTAssertEqual(HardGatesV13.minGeomGain, 0.0)
    }

    func testValidateAll() {
        // Test validateAll passes
        XCTAssertTrue(HardGatesV13.validateAll(debug: false))
    }

    func testValidateQValues() {
        // Test Q values match Double values
        XCTAssertTrue(HardGatesV13.validateQValues(debug: false))
    }

    func testFallbackGateQuality() {
        // Test fallback quality is computed (not fixed constant)
        let fallback = HardGatesV13.fallbackGateQuality
        XCTAssertGreaterThanOrEqual(fallback, 0.0)
        XCTAssertLessThanOrEqual(fallback, HardGatesV13.minViewGain)
    }

    func testBucketConfiguration() {
        // Test bucket configuration
        XCTAssertEqual(HardGatesV13.thetaBucketCount, 24)
        XCTAssertEqual(HardGatesV13.phiBucketCount, 12)
        XCTAssertEqual(HardGatesV13.thetaBucketSizeDeg, 15.0)
        XCTAssertEqual(HardGatesV13.phiBucketSizeDeg, 15.0)
    }
}
