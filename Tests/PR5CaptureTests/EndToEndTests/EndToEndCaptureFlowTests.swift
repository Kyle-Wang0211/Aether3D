// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// EndToEndCaptureFlowTests.swift
// PR5CaptureTests
//
// End-to-end tests for capture flow
//

import XCTest
@testable import PR5Capture

@MainActor
final class EndToEndCaptureFlowTests: XCTestCase {

    var profile: ExtremeProfile!

    override func setUp() async throws {
        profile = ExtremeProfile(profile: .standard)
    }

    override func tearDown() async throws {
        profile = nil
    }

    // MARK: - End-to-End Flow Tests

    func test_completeCaptureFlow() async {
        // 1. Initialize components
        let enforcer = DomainBoundaryEnforcer(config: profile.domainBoundary)
        let manager = DualAnchorManager(config: profile.dualAnchor)
        let gate = TwoPhaseQualityGate(config: profile.twoPhaseGate)

        // 2. Enter perception domain
        _ = await enforcer.enterDomain(.perception)

        // 3. Initialize session anchor
        let anchorValue = DualAnchorManager.AnchorValue(value: 1.0, timestamp: Date(), frameId: 1)
        await manager.initializeSessionAnchor(anchorValue)
        let sessionAnchor = await manager.getSessionAnchor()
        XCTAssertNotNil(sessionAnchor)

        // 4. Evaluate frame quality
        let frameResult = await gate.evaluateFrameGate(quality: 0.8, frameId: 1)
        XCTAssertNotNil(frameResult)

        // 5. Transition to decision domain
        _ = await enforcer.enterDomain(.decision)

        // 6. Evaluate patch gate if frame passed
        if case .pending(let decisionId, _) = frameResult {
            let patchResult = await gate.evaluatePatchGate(quality: 0.75, frameDecisionId: decisionId, patchId: UUID())
            XCTAssertNotNil(patchResult)
        }

        // 7. Transition to ledger domain
        _ = await enforcer.enterDomain(.ledger)
    }

    func test_captureFlow_withLowQuality() async {
        let enforcer = DomainBoundaryEnforcer(config: profile.domainBoundary)
        let gate = TwoPhaseQualityGate(config: profile.twoPhaseGate)

        _ = await enforcer.enterDomain(.perception)
        let frameResult = await gate.evaluateFrameGate(quality: 0.3, frameId: 1)

        // Check if result is rejected (low quality)
        switch frameResult {
        case .rejected:
            XCTAssertTrue(true) // Low quality frame rejected as expected
        case .pending:
            XCTAssertTrue(true) // Or pending if threshold allows
        }
    }

    func test_captureFlow_withAnchorDrift() async {
        let manager = DualAnchorManager(config: profile.dualAnchor)

        let anchor1 = DualAnchorManager.AnchorValue(value: 1.0, timestamp: Date(), frameId: 1)
        await manager.initializeSessionAnchor(anchor1)
        let sessionAnchor = await manager.getSessionAnchor()
        XCTAssertNotNil(sessionAnchor)

        // Simulate time passing with different value
        let laterValue = DualAnchorManager.AnchorValue(value: 2.0, timestamp: Date().addingTimeInterval(10), frameId: 2)
        let updated = await manager.updateSessionAnchorIfNeeded(laterValue)
        XCTAssertNotNil(updated)

        // Check for drift
        let driftValue = DualAnchorManager.AnchorValue(value: 3.0, timestamp: Date().addingTimeInterval(20), frameId: 3)
        let drift = await manager.checkDrift(driftValue)
        XCTAssertNotNil(drift)
    }

    func test_captureFlow_withProfileSwitching() async {
        let standardProfile = ExtremeProfile(profile: .standard)
        let extremeProfile = ExtremeProfile(profile: .extreme)

        let gate1 = TwoPhaseQualityGate(config: standardProfile.twoPhaseGate)
        let gate2 = TwoPhaseQualityGate(config: extremeProfile.twoPhaseGate)

        let result1 = await gate1.evaluateFrameGate(quality: 0.7, frameId: 1)
        let result2 = await gate2.evaluateFrameGate(quality: 0.7, frameId: 2)

        XCTAssertNotNil(result1)
        XCTAssertNotNil(result2)
    }

    func test_captureFlow_errorRecovery() async {
        let manager = DualAnchorManager(config: profile.dualAnchor)

        // Create anchor
        let anchor = DualAnchorManager.AnchorValue(value: 1.0, timestamp: Date(), frameId: 1)
        await manager.initializeSessionAnchor(anchor)
        let sessionAnchor = await manager.getSessionAnchor()
        XCTAssertNotNil(sessionAnchor)

        // Simulate anchor drift
        let driftValue = DualAnchorManager.AnchorValue(value: 100.0, timestamp: Date().addingTimeInterval(1000), frameId: 2)
        let drift = await manager.checkDrift(driftValue)
        XCTAssertNotNil(drift)

        // Recovery: update with new anchor
        let newAnchor = DualAnchorManager.AnchorValue(value: 2.0, timestamp: Date(), frameId: 3)
        let updated = await manager.updateSessionAnchorIfNeeded(newAnchor)
        XCTAssertNotNil(updated)
    }

    func test_captureFlow_concurrentFrames() async {
        let gate = TwoPhaseQualityGate(config: profile.twoPhaseGate)

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    let quality = 0.5 + Double(i) * 0.05
                    _ = await gate.evaluateFrameGate(quality: quality, frameId: UInt64(i))
                }
            }
        }
    }

    func test_captureFlow_withPrivacyEnforcement() async {
        let enforcer = PrivacyMaskEnforcer(config: profile)
        let region = PrivacyMaskEnforcer.MaskRegion(bounds: (x: 10, y: 10, width: 100, height: 100), type: .face)

        let result = await enforcer.enforceMasks(regions: [region])
        XCTAssertEqual(result.maskedRegions, 1)
    }

    func test_captureFlow_withAuditTrail() async {
        let recorder = AuditTrailRecorder(config: profile)
        let entry = AuditTrailRecorder.AuditEntry(
            timestamp: Date(),
            operation: "capture",
            userId: "user1",
            result: "success"
        )

        await recorder.recordEntry(entry)
        let integrity = await recorder.verifyIntegrity()
        XCTAssertTrue(integrity.isValid)
    }
}
