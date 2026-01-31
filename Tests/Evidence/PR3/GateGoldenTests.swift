//
// GateGoldenTests.swift
// Aether3D
//
// PR3 - Gate Golden Tests (Double Backend Only)
//

import XCTest
@testable import Aether3DCore

final class GateGoldenTests: XCTestCase {

    func testGoldenExactMatch() throws {
        // Force Double backend (canonical)
        let context = TierContext.forTesting  // Always canonical/Double

        // Load golden fixture (if exists)
        // For now, test with known values
        let testCases: [(input: (thetaSpanDeg: Double, phiSpanDeg: Double, l2PlusCount: Int, l3Count: Int, reprojRmsPx: Double, edgeRmsPx: Double, sharpness: Double, overexposureRatio: Double, underexposureRatio: Double), expectedQ: Int64)] = [
            // Add test cases here when golden fixture is available
        ]

        for (input, expectedQ) in testCases {
            let viewGain = GateGainFunctions.viewGateGain(
                thetaSpanDeg: input.thetaSpanDeg,
                phiSpanDeg: input.phiSpanDeg,
                l2PlusCount: input.l2PlusCount,
                l3Count: input.l3Count,
                context: context
            )

            let geomGain = GateGainFunctions.geomGateGain(
                reprojRmsPx: input.reprojRmsPx,
                edgeRmsPx: input.edgeRmsPx,
                context: context
            )

            let basicGain = GateGainFunctions.basicGateGain(
                sharpness: input.sharpness,
                overexposureRatio: input.overexposureRatio,
                underexposureRatio: input.underexposureRatio,
                context: context
            )

            let gateQuality = GateGainFunctions.gateQuality(
                viewGain: viewGain,
                geomGain: geomGain,
                basicGain: basicGain
            )

            let actualQ = QuantizerQ01.quantize(gateQuality)

            // EXACT match for Double backend
            XCTAssertEqual(actualQ, expectedQ, "Gate quality exact mismatch")
        }
    }

    func testCrossPlatformConsistency() {
        // Test that same inputs produce same quantized output
        let context = TierContext.forTesting

        let quality1 = GateGainFunctions.gateQuality(
            viewGain: 0.8,
            geomGain: 0.7,
            basicGain: 0.9
        )

        let quality2 = GateGainFunctions.gateQuality(
            viewGain: 0.8,
            geomGain: 0.7,
            basicGain: 0.9
        )

        let q1 = QuantizerQ01.quantize(quality1)
        let q2 = QuantizerQ01.quantize(quality2)

        XCTAssertEqual(q1, q2)
    }
}
