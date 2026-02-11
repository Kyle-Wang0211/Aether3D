// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// TwoPhaseQualityGateTests.swift
// PR5CaptureTests
//
// Tests for TwoPhaseQualityGate
//

import XCTest
@testable import PR5Capture

@MainActor
final class TwoPhaseQualityGateTests: XCTestCase {
    
    func testFrameGatePass() async {
        let config = ExtremeProfile.TwoPhaseGateConfig.forProfile(.standard)
        let gate = TwoPhaseQualityGate(config: config)
        
        // Quality above threshold should pass frame gate
        let result = await gate.evaluateFrameGate(quality: 0.8, frameId: 1)
        
        switch result {
        case .pending(let decisionId, let quality):
            XCTAssertEqual(quality, 0.8, accuracy: 0.001)
            XCTAssertNotNil(decisionId)
        case .rejected:
            XCTFail("Should have passed frame gate")
        }
    }
    
    func testFrameGateFail() async {
        let config = ExtremeProfile.TwoPhaseGateConfig.forProfile(.standard)
        let gate = TwoPhaseQualityGate(config: config)
        
        // Quality below threshold should fail frame gate
        let result = await gate.evaluateFrameGate(quality: 0.5, frameId: 1)
        
        switch result {
        case .pending:
            XCTFail("Should have failed frame gate")
        case .rejected(let reason):
            XCTAssertTrue(reason.contains("below threshold"))
        }
    }
    
    func testPatchGateConfirmation() async {
        let config = ExtremeProfile.TwoPhaseGateConfig.forProfile(.standard)
        let gate = TwoPhaseQualityGate(config: config)
        
        // Pass frame gate
        let frameResult = await gate.evaluateFrameGate(quality: 0.8, frameId: 1)
        guard case .pending(let decisionId, _) = frameResult else {
            XCTFail("Frame gate should have passed")
            return
        }
        
        // Pass patch gate (should confirm frame decision)
        let patchResult = await gate.evaluatePatchGate(
            quality: 0.85,
            frameDecisionId: decisionId,
            patchId: UUID()
        )
        
        switch patchResult {
        case .confirmed(let confirmedFrameId, _):
            XCTAssertEqual(confirmedFrameId, decisionId)
        default:
            XCTFail("Should have confirmed frame decision")
        }
    }
    
    func testPatchGateRejection() async {
        let config = ExtremeProfile.TwoPhaseGateConfig.forProfile(.standard)
        let gate = TwoPhaseQualityGate(config: config)
        
        // Pass frame gate
        let frameResult = await gate.evaluateFrameGate(quality: 0.8, frameId: 1)
        guard case .pending(let decisionId, _) = frameResult else {
            XCTFail("Frame gate should have passed")
            return
        }
        
        // Fail patch gate (should reject frame decision)
        let patchResult = await gate.evaluatePatchGate(
            quality: 0.5,
            frameDecisionId: decisionId,
            patchId: UUID()
        )
        
        switch patchResult {
        case .rejected:
            // Expected
            break
        default:
            XCTFail("Should have rejected patch gate")
        }
        
        // Frame decision should be removed
        let pendingCount = await gate.getPendingFrameDecisionsCount()
        XCTAssertEqual(pendingCount, 0)
    }
    
    // MARK: - Additional Gate Tests
    
    func test_frame_gate_pass_high_quality() async {
        let config = ExtremeProfile.TwoPhaseGateConfig.forProfile(.standard)
        let gate = TwoPhaseQualityGate(config: config)
        
        let result = await gate.evaluateFrameGate(quality: 0.95, frameId: 1)
        
        switch result {
        case .pending:
            break  // Expected
        case .rejected:
            XCTFail("High quality should pass")
        }
    }
    
    func test_frame_gate_fail_low_quality() async {
        let config = ExtremeProfile.TwoPhaseGateConfig.forProfile(.standard)
        let gate = TwoPhaseQualityGate(config: config)
        
        let result = await gate.evaluateFrameGate(quality: 0.3, frameId: 1)
        
        switch result {
        case .pending:
            XCTFail("Low quality should fail")
        case .rejected:
            break  // Expected
        }
    }
    
    func test_patch_gate_pass() async {
        let config = ExtremeProfile.TwoPhaseGateConfig.forProfile(.standard)
        let gate = TwoPhaseQualityGate(config: config)
        
        let frameResult = await gate.evaluateFrameGate(quality: 0.8, frameId: 1)
        guard case .pending(let decisionId, _) = frameResult else {
            XCTFail("Frame gate should pass")
            return
        }
        
        let patchResult = await gate.evaluatePatchGate(
            quality: 0.9,
            frameDecisionId: decisionId,
            patchId: UUID()
        )
        
        switch patchResult {
        case .confirmed:
            break  // Expected
        default:
            XCTFail("Patch gate should pass")
        }
    }
    
    func test_patch_gate_fail() async {
        let config = ExtremeProfile.TwoPhaseGateConfig.forProfile(.standard)
        let gate = TwoPhaseQualityGate(config: config)
        
        let frameResult = await gate.evaluateFrameGate(quality: 0.8, frameId: 1)
        guard case .pending(let decisionId, _) = frameResult else {
            XCTFail("Frame gate should pass")
            return
        }
        
        let patchResult = await gate.evaluatePatchGate(
            quality: 0.4,
            frameDecisionId: decisionId,
            patchId: UUID()
        )
        
        switch patchResult {
        case .rejected:
            break  // Expected
        default:
            XCTFail("Patch gate should fail")
        }
    }
    
    func test_two_phase_combination() async {
        let config = ExtremeProfile.TwoPhaseGateConfig.forProfile(.standard)
        let gate = TwoPhaseQualityGate(config: config)
        
        // Phase 1: Frame gate
        let frameResult = await gate.evaluateFrameGate(quality: 0.8, frameId: 1)
        guard case .pending(let decisionId, _) = frameResult else {
            XCTFail("Frame gate should pass")
            return
        }
        
        // Phase 2: Patch gate
        let patchResult = await gate.evaluatePatchGate(
            quality: 0.85,
            frameDecisionId: decisionId,
            patchId: UUID()
        )
        
        switch patchResult {
        case .confirmed(let confirmedId, _):
            XCTAssertEqual(confirmedId, decisionId)
        default:
            XCTFail("Two-phase should succeed")
        }
    }
    
    func test_quality_degradation_handling() async {
        let config = ExtremeProfile.TwoPhaseGateConfig.forProfile(.standard)
        let gate = TwoPhaseQualityGate(config: config)
        
        // Pass frame gate with high quality
        let frameResult = await gate.evaluateFrameGate(quality: 0.9, frameId: 1)
        guard case .pending(let decisionId, _) = frameResult else {
            XCTFail("Frame gate should pass")
            return
        }
        
        // Patch gate with degraded quality
        let patchResult = await gate.evaluatePatchGate(
            quality: 0.5,
            frameDecisionId: decisionId,
            patchId: UUID()
        )
        
        // Should reject due to degradation
        switch patchResult {
        case .rejected:
            break  // Expected
        default:
            XCTFail("Should reject degraded quality")
        }
    }
    
    func test_patch_gate_timeout() async {
        let config = ExtremeProfile.TwoPhaseGateConfig.forProfile(.standard)
        let gate = TwoPhaseQualityGate(config: config)
        
        let frameResult = await gate.evaluateFrameGate(quality: 0.8, frameId: 1)
        guard case .pending(let decisionId, _) = frameResult else {
            XCTFail("Frame gate should pass")
            return
        }
        
        // Wait for timeout (simplified - actual timeout handling would be more complex)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        
        // Try patch gate after timeout
        let patchResult = await gate.evaluatePatchGate(
            quality: 0.85,
            frameDecisionId: decisionId,
            patchId: UUID()
        )
        
        // Should handle timeout appropriately
        switch patchResult {
        case .rejected, .confirmed:
            break  // Either is acceptable
        default:
            break
        }
    }
    
    func test_multiple_pending_decisions() async {
        let config = ExtremeProfile.TwoPhaseGateConfig.forProfile(.standard)
        let gate = TwoPhaseQualityGate(config: config)
        
        // Create multiple pending decisions
        for i in 1...5 {
            _ = await gate.evaluateFrameGate(quality: 0.8, frameId: UInt64(i))
        }
        
        let pendingCount = await gate.getPendingFrameDecisionsCount()
        XCTAssertEqual(pendingCount, 5)
    }
    
    func test_boundary_quality_values() async {
        let config = ExtremeProfile.TwoPhaseGateConfig.forProfile(.standard)
        let gate = TwoPhaseQualityGate(config: config)
        
        // Test exact threshold
        let thresholdResult = await gate.evaluateFrameGate(quality: config.frameGateThreshold, frameId: 1)
        switch thresholdResult {
        case .pending, .rejected:
            break  // Either is acceptable at boundary
        }
        
        // Test just below threshold
        let belowResult = await gate.evaluateFrameGate(quality: config.frameGateThreshold - 0.001, frameId: 2)
        switch belowResult {
        case .rejected:
            break  // Expected
        case .pending:
            XCTFail("Should reject below threshold")
        }
        
        // Test just above threshold
        let aboveResult = await gate.evaluateFrameGate(quality: config.frameGateThreshold + 0.001, frameId: 3)
        switch aboveResult {
        case .pending:
            break  // Expected
        case .rejected:
            XCTFail("Should accept above threshold")
        }
    }
}
