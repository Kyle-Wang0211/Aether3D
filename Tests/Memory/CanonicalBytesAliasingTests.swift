//
// CanonicalBytesAliasingTests.swift
// Aether3D
//
// PR1 v2.4 Addendum - Canonical Bytes Aliasing Tests
//
// Ensures canonical bytes are copied, not aliased
//

import XCTest
@testable import Aether3DCore

final class CanonicalBytesAliasingTests: XCTestCase {
    /// Test that mutating source arrays post-hash does not affect stored bytes
    func testCanonicalBytes_NoAliasing_PerFlowCounters() throws {
        let candidateId = UUID()
        
        // Create mutable perFlowCounters array
        var perFlowCounters: [UInt16] = [1, 2, 3, 4]
        
        let metrics = CapacityMetrics(
            candidateId: candidateId,
            patchCountShadow: 0,
            eebRemaining: 0.0,
            eebDelta: 0.0,
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
        
        // Generate canonical bytes
        let canonicalBytes1 = try metrics.canonicalBytesForDecisionHashInput(
            policyHash: 0,
            sessionStableId: 0,
            candidateStableId: 0,
            valueScore: 0,
            perFlowCounters: perFlowCounters,
            flowBucketCount: 4,
            throttleStats: nil,
            degradationLevel: 0,
            degradationReasonCode: nil,
            schemaVersion: 0x0204
        )
        
        // Mutate source array
        perFlowCounters[0] = 999
        perFlowCounters[1] = 888
        perFlowCounters[2] = 777
        perFlowCounters[3] = 666
        
        // Generate canonical bytes again with mutated array
        let canonicalBytes2 = try metrics.canonicalBytesForDecisionHashInput(
            policyHash: 0,
            sessionStableId: 0,
            candidateStableId: 0,
            valueScore: 0,
            perFlowCounters: perFlowCounters, // Mutated array
            flowBucketCount: 4,
            throttleStats: nil,
            degradationLevel: 0,
            degradationReasonCode: nil,
            schemaVersion: 0x0204
        )
        
        // First canonical bytes should not be affected by mutation
        // (They were generated before mutation, so they should remain unchanged)
        // But we need to verify that canonicalBytes1 is a copy, not a reference
        
        // Generate canonical bytes again with original values
        let canonicalBytes3 = try metrics.canonicalBytesForDecisionHashInput(
            policyHash: 0,
            sessionStableId: 0,
            candidateStableId: 0,
            valueScore: 0,
            perFlowCounters: [1, 2, 3, 4], // Original values
            flowBucketCount: 4,
            throttleStats: nil,
            degradationLevel: 0,
            degradationReasonCode: nil,
            schemaVersion: 0x0204
        )
        
        // canonicalBytes1 and canonicalBytes3 should be identical (same inputs)
        XCTAssertEqual(canonicalBytes1, canonicalBytes3, "Canonical bytes must be identical for same inputs")
        
        // canonicalBytes2 should differ (different perFlowCounters)
        XCTAssertNotEqual(canonicalBytes1, canonicalBytes2, "Canonical bytes must differ for different perFlowCounters")
    }
    
    /// Test that canonical bytes are independent copies
    func testCanonicalBytes_IndependentCopies() throws {
        let candidateId = UUID()
        let metrics = CapacityMetrics(
            candidateId: candidateId,
            patchCountShadow: 0,
            eebRemaining: 0.0,
            eebDelta: 0.0,
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
        
        let canonicalBytes1 = try metrics.canonicalBytesForDecisionHashInput(
            policyHash: 12345,
            sessionStableId: 67890,
            candidateStableId: 11111,
            valueScore: 1000,
            perFlowCounters: [1, 2, 3, 4],
            flowBucketCount: 4,
            throttleStats: nil,
            degradationLevel: 0,
            degradationReasonCode: nil,
            schemaVersion: 0x0204
        )
        
        // Create a mutable copy
        var mutableBytes = canonicalBytes1
        
        // Mutate the copy
        if mutableBytes.count > 10 {
            mutableBytes[10] = 0xFF
        }
        
        // Original should be unchanged
        XCTAssertNotEqual(canonicalBytes1, mutableBytes, "Mutating copy should not affect original")
        
        // Verify original is still valid
        let hash1 = try DecisionHashV1.compute(from: canonicalBytes1)
        XCTAssertEqual(hash1.bytes.count, 32, "Original canonical bytes must still produce valid hash")
    }
    
    /// Test that DecisionHash bytes are independent copies
    func testDecisionHash_IndependentBytes() throws {
        let candidateId = UUID()
        let metrics = CapacityMetrics(
            candidateId: candidateId,
            patchCountShadow: 0,
            eebRemaining: 0.0,
            eebDelta: 0.0,
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
        
        let canonicalBytes = try metrics.canonicalBytesForDecisionHashInput(
            policyHash: 0,
            sessionStableId: 0,
            candidateStableId: 0,
            valueScore: 0,
            perFlowCounters: [],
            flowBucketCount: 4,
            throttleStats: nil,
            degradationLevel: 0,
            degradationReasonCode: nil,
            schemaVersion: 0x0204
        )
        
        let decisionHash1 = try DecisionHashV1.compute(from: canonicalBytes)
        
        // Get bytes array
        var hashBytes1 = decisionHash1.bytes
        
        // Mutate the array
        hashBytes1[0] = 0xFF
        
        // Original DecisionHash should be unchanged
        XCTAssertNotEqual(decisionHash1.bytes, hashBytes1, "Mutating bytes array should not affect DecisionHash")
        XCTAssertEqual(decisionHash1.bytes.count, 32, "DecisionHash bytes must remain 32 bytes")
    }
}
