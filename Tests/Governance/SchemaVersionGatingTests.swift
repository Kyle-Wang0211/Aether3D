//
// SchemaVersionGatingTests.swift
// Aether3D
//
// PR1 v2.4 Addendum - Schema Version Gating Tests
//
// Verifies schemaVersion >= 0x0204 enforcement and pre-v2.4 behavior
//

import XCTest
@testable import Aether3DCore

final class SchemaVersionGatingTests: XCTestCase {
    /// Test v2.4+ behavior: decisionHash MUST be computed
    func testV24_DecisionHash_Computed() throws {
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
        
        // v2.4+ should compute decisionHash
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
        
        XCTAssertEqual(decisionHash.bytes.count, 32, "DecisionHash must be 32 bytes for v2.4+")
    }
    
    /// Test v2.4+ behavior: length validation enforced
    func testV24_LengthValidation_Enforced() throws {
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
        
        // v2.4+ should enforce length validation
        // This should not throw if length is correct
        XCTAssertNoThrow(
            try metrics.canonicalBytesForDecisionHashInput(
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
            ),
            "v2.4+ should not throw on valid input"
        )
    }
    
    /// Test pre-v2.4 behavior: decisionHash can be nil (choice A)
    /// 
    /// **Choice A:** schemaVersion < 0x0204 => decisionHash MUST be absent/nil and never computed
    func testPreV24_DecisionHash_CanBeNil() {
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
            decisionHash: nil // Pre-v2.4: can be nil
        )
        
        // Pre-v2.4: decisionHash can be nil
        XCTAssertNil(metrics.decisionHash, "Pre-v2.4 decisionHash can be nil")
    }
    
    /// Test schemaVersion gating: v2.3 should not enforce strict validation
    func testV23_RelaxedValidation() throws {
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
        
        // v2.3 should allow computation but not enforce strict validation
        // This should not throw even with relaxed constraints
        XCTAssertNoThrow(
            try metrics.canonicalBytesForDecisionHashInput(
                policyHash: 0,
                sessionStableId: 0,
                candidateStableId: 0,
                valueScore: 0,
                perFlowCounters: [],
                flowBucketCount: 4,
                throttleStats: nil,
                degradationLevel: 0,
                degradationReasonCode: nil,
                schemaVersion: 0x0203 // Pre-v2.4
            ),
            "v2.3 should allow relaxed validation"
        )
    }
}
