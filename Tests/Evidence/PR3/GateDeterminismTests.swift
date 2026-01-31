//
// GateDeterminismTests.swift
// Aether3D
//
// PR3 - Gate Determinism Tests
//

import XCTest
@testable import Aether3DCore

final class GateDeterminismTests: XCTestCase {

    func testGateQualityDeterministic100Runs() {
        var results: Set<Int64> = []

        for _ in 0..<100 {
            let quality = GateGainFunctions.gateQuality(
                viewGain: 0.8,
                geomGain: 0.7,
                basicGain: 0.9
            )

            let quantized = QuantizerQ01.quantize(quality)
            results.insert(quantized)
        }

        // All runs should produce exactly the same quantized result
        XCTAssertEqual(results.count, 1, "Gate quality must be deterministic")
    }

    func testDifferentInsertionOrderSameOutput() {
        // Test that different insertion orders produce same output
        let directions1 = [
            EvidenceVector3(x: 0.0, y: 0.0, z: 1.0).normalized(),
            EvidenceVector3(x: 1.0, y: 0.0, z: 0.0).normalized(),
            EvidenceVector3(x: 0.0, y: 0.0, z: -1.0).normalized()
        ]

        let directions2 = [
            EvidenceVector3(x: 1.0, y: 0.0, z: 0.0).normalized(),
            EvidenceVector3(x: 0.0, y: 0.0, z: -1.0).normalized(),
            EvidenceVector3(x: 0.0, y: 0.0, z: 1.0).normalized()
        ]

        var tracker1 = GateCoverageTracker()
        var tracker2 = GateCoverageTracker()

        for (i, dir) in directions1.enumerated() {
            tracker1.recordObservation(
                patchId: "patch1",
                direction: dir,
                pr3Quality: 0.5,
                frameIndex: i
            )
        }

        for (i, dir) in directions2.enumerated() {
            tracker2.recordObservation(
                patchId: "patch1",
                direction: dir,
                pr3Quality: 0.5,
                frameIndex: i
            )
        }

        let inputs1 = tracker1.viewGainInputs(for: "patch1")
        let inputs2 = tracker2.viewGainInputs(for: "patch1")

        // Should produce same spans (bitset is order-independent)
        XCTAssertEqual(inputs1.thetaSpanDeg, inputs2.thetaSpanDeg, accuracy: 1.0)
        XCTAssertEqual(inputs1.phiSpanDeg, inputs2.phiSpanDeg, accuracy: 1.0)
    }

    func testZeroTrigDeterminism() {
        // Test zero-trig bucketing is deterministic
        var phiBuckets: Set<Int> = []
        var thetaBuckets: Set<Int> = []

        for _ in 0..<100 {
            let phiBucket = ZeroTrigPhiBucketing.phiBucket(dy: 0.5)
            let thetaBucket = ZeroTrigThetaBucketing.thetaBucket(dx: 0.5, dz: 0.866)

            phiBuckets.insert(phiBucket)
            thetaBuckets.insert(thetaBucket)
        }

        // Should always produce same bucket
        XCTAssertEqual(phiBuckets.count, 1)
        XCTAssertEqual(thetaBuckets.count, 1)
    }
}
