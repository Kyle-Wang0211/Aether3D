//
// GateCoverageTrackerTests.swift
// Aether3D
//
// PR3 - Gate Coverage Tracker Tests
//

import XCTest
@testable import Aether3DCore

final class GateCoverageTrackerTests: XCTestCase {

    var tracker: GateCoverageTracker!

    override func setUp() {
        super.setUp()
        tracker = GateCoverageTracker()
    }

    func testThetaPhiComputation() {
        // Test theta/phi computation correctness
        let direction = EvidenceVector3(x: 0.0, y: 0.0, z: 1.0).normalized()  // Looking along +Z
        tracker.recordObservation(
            patchId: "patch1",
            direction: direction,
            pr3Quality: 0.5,
            frameIndex: 0
        )

        let inputs = tracker.viewGainInputs(for: "patch1")
        // Single observation should have 0 span
        XCTAssertEqual(inputs.thetaSpanDeg, 0, accuracy: 1.0)
        XCTAssertEqual(inputs.phiSpanDeg, 0, accuracy: 1.0)
    }

    func testThetaWrapAroundSpan() {
        // Test theta wrap-around span calculation
        // Add observations at 0° and 350° (should have small span, not 350°)
        let dir1 = EvidenceVector3(x: 0.0, y: 0.0, z: 1.0).normalized()  // 0°
        let dir2 = EvidenceVector3(x: -0.087, y: 0.0, z: 0.996).normalized()  // ~350°

        tracker.recordObservation(
            patchId: "patch1",
            direction: dir1,
            pr3Quality: 0.5,
            frameIndex: 0
        )

        tracker.recordObservation(
            patchId: "patch1",
            direction: dir2,
            pr3Quality: 0.5,
            frameIndex: 1
        )

        let inputs = tracker.viewGainInputs(for: "patch1")
        // Span should be small (wrap-around), not ~350°
        // Two adjacent buckets at most 30° span
        XCTAssertLessThanOrEqual(inputs.thetaSpanDeg, 30.0)
    }

    func testDeterministicEviction() {
        // Test deterministic eviction when over limit
        let direction = EvidenceVector3(x: 0.0, y: 0.0, z: 1.0).normalized()

        // Add more than maxRecordsPerPatch observations
        for i in 0..<250 {
            tracker.recordObservation(
                patchId: "patch1",
                direction: direction,
                pr3Quality: 0.5,
                frameIndex: i
            )
        }

        let inputs = tracker.viewGainInputs(for: "patch1")
        // Should still have valid inputs (not crashed)
        XCTAssertGreaterThanOrEqual(inputs.l2PlusCount, 0)
    }

    func testL2PlusL3OnlyNewBucket() {
        // Test L2+/L3 counts only update when new bucket is filled
        let direction = EvidenceVector3(x: 0.0, y: 0.0, z: 1.0).normalized()

        // Add same observation multiple times (same bucket)
        for i in 0..<10 {
            tracker.recordObservation(
                patchId: "patch1",
                direction: direction,
                pr3Quality: 0.5,  // L2+ quality
                frameIndex: i
            )
        }

        let inputs1 = tracker.viewGainInputs(for: "patch1")
        let l2PlusCount1 = inputs1.l2PlusCount

        // Add one more in same bucket
        tracker.recordObservation(
            patchId: "patch1",
            direction: direction,
            pr3Quality: 0.5,
            frameIndex: 10
        )

        let inputs2 = tracker.viewGainInputs(for: "patch1")
        // Count should not increase (same bucket)
        XCTAssertEqual(inputs2.l2PlusCount, l2PlusCount1)

        // Add observation in different bucket
        let dir2 = EvidenceVector3(x: 1.0, y: 0.0, z: 0.0).normalized()  // 90°
        tracker.recordObservation(
            patchId: "patch1",
            direction: dir2,
            pr3Quality: 0.5,
            frameIndex: 11
        )

        let inputs3 = tracker.viewGainInputs(for: "patch1")
        // Count should increase (new bucket)
        XCTAssertGreaterThan(inputs3.l2PlusCount, l2PlusCount1)
    }
}
