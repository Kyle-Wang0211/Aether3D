// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// DecisionHashOutputFormattingTests.swift
// Aether3D
//
// PR1 v2.4 Addendum - DecisionHash Output Formatting Tests
//
// Verifies stable formatting for decisionHashHexLower (64 lowercase hex chars, no prefix)
//

import XCTest
@testable import Aether3DCore

final class DecisionHashOutputFormattingTests: XCTestCase {
    /// Test decisionHashHexLower format: exactly 64 lowercase hex chars, no prefix
    func testDecisionHashHexLower_Format() throws {
        let metrics = CapacityMetrics(
            candidateId: UUID(),
            patchCountShadow: 0,
            eebRemaining: 0,
            eebDelta: 0,
            buildMode: .NORMAL,
            rejectReason: nil,
            hardFuseTrigger: nil,
            rejectReasonDistribution: [:],
            capacityInvariantViolation: false,
            capacitySaturatedLatchedAtPatchCount: nil,
            capacitySaturatedLatchedAtTimestamp: nil,
            flushFailure: false,
            decisionHash: nil
        )
        
        let decisionHash = try metrics.computeDecisionHashV1(
            policyHash: 0x123456789ABCDEF0,
            sessionStableId: 0x123456789ABCDEF0,
            candidateStableId: 0x123456789ABCDEF0,
            valueScore: 1000,
            perFlowCounters: [1, 2, 3, 4],
            flowBucketCount: 4,
            throttleStats: nil,
            degradationLevel: 0,
            degradationReasonCode: nil,
            schemaVersion: 0x0204
        )
        
        let decision = AdmissionDecision(
            candidateId: UUID(),
            classification: .ACCEPTED,
            reason: nil,
            eebDelta: 0,
            buildMode: .NORMAL,
            guidanceSignal: .NONE,
            hardFuseTrigger: nil
        )
        
        // Verify decisionHashHexLower format
        let hexLower = decision.decisionHashHexLower
        
        XCTAssertEqual(hexLower.count, 64, "decisionHashHexLower must be exactly 64 characters")
        XCTAssertFalse(hexLower.hasPrefix("0x"), "decisionHashHexLower must not have '0x' prefix")
        XCTAssertEqual(hexLower.lowercased(), hexLower, "decisionHashHexLower must be lowercase")
        
        // Verify all characters are hex digits
        let hexCharacterSet = CharacterSet(charactersIn: "0123456789abcdef")
        XCTAssertTrue(hexLower.unicodeScalars.allSatisfy { hexCharacterSet.contains($0) }, "decisionHashHexLower must contain only hex digits")
    }
    
    /// Test decisionHashBytes: exactly 32 bytes
    func testDecisionHashBytes_Format() throws {
        let decision = AdmissionDecision(
            candidateId: UUID(),
            classification: .ACCEPTED,
            reason: nil,
            eebDelta: 0,
            buildMode: .NORMAL,
            guidanceSignal: .NONE,
            hardFuseTrigger: nil
        )
        
        let bytes = decision.decisionHashBytes
        XCTAssertEqual(bytes.count, 32, "decisionHashBytes must be exactly 32 bytes")
    }
    
    /// Test formatting stability: same input produces same hex string
    func testDecisionHashHexLower_Stability() throws {
        let metrics1 = CapacityMetrics(
            candidateId: UUID(),
            patchCountShadow: 0,
            eebRemaining: 0,
            eebDelta: 0,
            buildMode: .NORMAL,
            rejectReason: nil,
            hardFuseTrigger: nil,
            rejectReasonDistribution: [:],
            capacityInvariantViolation: false,
            capacitySaturatedLatchedAtPatchCount: nil,
            capacitySaturatedLatchedAtTimestamp: nil,
            flushFailure: false,
            decisionHash: nil
        )
        
        let hash1 = try metrics1.computeDecisionHashV1(
            policyHash: 0x123456789ABCDEF0,
            sessionStableId: 0x123456789ABCDEF0,
            candidateStableId: 0x123456789ABCDEF0,
            valueScore: 1000,
            perFlowCounters: [1, 2, 3, 4],
            flowBucketCount: 4,
            throttleStats: nil,
            degradationLevel: 0,
            degradationReasonCode: nil,
            schemaVersion: 0x0204
        )
        
        let metrics2 = CapacityMetrics(
            candidateId: UUID(),
            patchCountShadow: 0,
            eebRemaining: 0,
            eebDelta: 0,
            buildMode: .NORMAL,
            rejectReason: nil,
            hardFuseTrigger: nil,
            rejectReasonDistribution: [:],
            capacityInvariantViolation: false,
            capacitySaturatedLatchedAtPatchCount: nil,
            capacitySaturatedLatchedAtTimestamp: nil,
            flushFailure: false,
            decisionHash: nil
        )
        
        let hash2 = try metrics2.computeDecisionHashV1(
            policyHash: 0x123456789ABCDEF0,
            sessionStableId: 0x123456789ABCDEF0,
            candidateStableId: 0x123456789ABCDEF0,
            valueScore: 1000,
            perFlowCounters: [1, 2, 3, 4],
            flowBucketCount: 4,
            throttleStats: nil,
            degradationLevel: 0,
            degradationReasonCode: nil,
            schemaVersion: 0x0204
        )
        
        XCTAssertEqual(hash1.hexString, hash2.hexString, "Same input must produce same hex string")
    }
}
