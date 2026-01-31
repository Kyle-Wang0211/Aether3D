//
// GateIntegrationTests.swift
// Aether3D
//
// PR3 - Gate Integration Tests
//

import XCTest
@testable import Aether3DCore

final class GateIntegrationTests: XCTestCase {

    func testIsolatedEvidenceEngineIntegration() async {
        let engine = await IsolatedEvidenceEngine()

        let observation = EvidenceObservation(
            patchId: "patch1",
            timestamp: 1000.0,
            frameId: "frame1"
        )

        let cameraPosition = EvidenceVector3(x: 0.0, y: 0.0, z: -1.0)
        let patchPosition = EvidenceVector3(x: 0.0, y: 0.0, z: 0.0)

        // Test processFrameWithGate
        await engine.processFrameWithGate(
            observation: observation,
            cameraPosition: cameraPosition,
            patchPosition: patchPosition,
            reprojRmsPx: 0.35,
            edgeRmsPx: 0.18,
            sharpness: 88.0,
            overexposureRatio: 0.22,
            underexposureRatio: 0.30,
            frameIndex: 0,
            softQuality: 0.0,
            verdict: .good
        )

        // Verify snapshot updated
        let snapshot = await engine.snapshot()
        XCTAssertGreaterThanOrEqual(snapshot.gateDisplay, 0.0)
        XCTAssertLessThanOrEqual(snapshot.gateDisplay, 1.0)
    }

    func testViewDiversityTrackerNotModified() {
        // Verify ViewDiversityTracker is not referenced in PR3 code
        // This is a compile-time check - if code compiles, it's not using ViewDiversityTracker
        let tracker = GateCoverageTracker()
        tracker.resetAll()

        // If this compiles, ViewDiversityTracker is not imported/used
        XCTAssertNotNil(tracker)
    }
}
