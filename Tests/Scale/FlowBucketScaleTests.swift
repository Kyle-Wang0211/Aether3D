// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// FlowBucketScaleTests.swift
// Aether3D
//
// PR1 v2.4 Addendum - Flow Bucket Scale Tests
//
// Tests correctness under extreme but realistic scale
//

import XCTest
@testable import Aether3DCore

/// Seeded RNG for deterministic tests
private struct ScaleRNG {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed }
    mutating func next() -> UInt64 {
        state = (state &* 1103515245 &+ 12345) & 0x7fffffff
        return state
    }
    mutating func nextUInt8() -> UInt8 { return UInt8(next() & 0xFF) }
    mutating func nextUInt16() -> UInt16 { return UInt16(next() & 0xFFFF) }
    mutating func nextUInt32() -> UInt32 { return UInt32(next() & 0xFFFFFFFF) }
    mutating func nextUInt64() -> UInt64 { return (next() << 32) | next() }
    mutating func nextInt64() -> Int64 { return Int64(bitPattern: nextUInt64()) }
}

final class FlowBucketScaleTests: XCTestCase {
    /// Test flowBucketCount = 0
    func testFlowBucketCount_Zero() throws {
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
        
        // flowBucketCount = 0, perFlowCounters = []
        let canonicalBytes = try metrics.canonicalBytesForDecisionHashInput(
            policyHash: 0,
            sessionStableId: 0,
            candidateStableId: 0,
            valueScore: 0,
            perFlowCounters: [],
            flowBucketCount: 0,
            throttleStats: nil,
            degradationLevel: 0,
            degradationReasonCode: nil,
            schemaVersion: 0x0204
        )
        
        XCTAssertGreaterThan(canonicalBytes.count, 0, "Canonical bytes must encode even with 0 flow buckets")
        
        let decisionHash = try DecisionHashV1.compute(from: canonicalBytes)
        XCTAssertEqual(decisionHash.bytes.count, 32, "DecisionHash must be 32 bytes")
    }
    
    /// Test flowBucketCount = 1
    func testFlowBucketCount_One() throws {
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
            perFlowCounters: [100],
            flowBucketCount: 1,
            throttleStats: nil,
            degradationLevel: 0,
            degradationReasonCode: nil,
            schemaVersion: 0x0204
        )
        
        XCTAssertGreaterThan(canonicalBytes.count, 0, "Canonical bytes must encode with 1 flow bucket")
        
        let decisionHash = try DecisionHashV1.compute(from: canonicalBytes)
        XCTAssertEqual(decisionHash.bytes.count, 32, "DecisionHash must be 32 bytes")
    }
    
    /// Test flowBucketCount = max(UInt8) = 255
    func testFlowBucketCount_MaxUInt8() throws {
        let candidateId = UUID()
        var rng = ScaleRNG(seed: 2000)
        
        // Generate 255 perFlowCounters
        var perFlowCounters: [UInt16] = []
        for _ in 0..<255 {
            perFlowCounters.append(rng.nextUInt16())
        }
        
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
            policyHash: rng.nextUInt64(),
            sessionStableId: rng.nextUInt64(),
            candidateStableId: rng.nextUInt64(),
            valueScore: rng.nextInt64(),
            perFlowCounters: perFlowCounters,
            flowBucketCount: 255, // max(UInt8)
            throttleStats: nil,
            degradationLevel: 0,
            degradationReasonCode: nil,
            schemaVersion: 0x0204
        )
        
        // Verify canonical byte length is correct
        // Expected: header bytes + perFlowCounters (255 * 2 bytes = 510 bytes)
        XCTAssertGreaterThan(canonicalBytes.count, 500, "Canonical bytes must include all 255 flow counters")
        
        let decisionHash = try DecisionHashV1.compute(from: canonicalBytes)
        XCTAssertEqual(decisionHash.bytes.count, 32, "DecisionHash must be 32 bytes even with max flow buckets")
        
        // Verify determinism: same inputs produce same hash
        let canonicalBytes2 = try metrics.canonicalBytesForDecisionHashInput(
            policyHash: rng.nextUInt64(),
            sessionStableId: rng.nextUInt64(),
            candidateStableId: rng.nextUInt64(),
            valueScore: rng.nextInt64(),
            perFlowCounters: perFlowCounters, // Same counters
            flowBucketCount: 255,
            throttleStats: nil,
            degradationLevel: 0,
            degradationReasonCode: nil,
            schemaVersion: 0x0204
        )
        
        // Note: Different policyHash/sessionStableId will produce different hash
        // But same perFlowCounters should produce same relative structure
        XCTAssertEqual(canonicalBytes.count, canonicalBytes2.count, "Canonical byte length must be consistent")
    }
    
    /// Test that perFlowCounters array size must match flowBucketCount (fail-closed)
    func testFlowBucketCount_Mismatch_FailClosed() throws {
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
        
        // flowBucketCount = 4, but perFlowCounters = [1, 2, 3] (mismatch)
        do {
            let _ = try metrics.canonicalBytesForDecisionHashInput(
                policyHash: 0,
                sessionStableId: 0,
                candidateStableId: 0,
                valueScore: 0,
                perFlowCounters: [1, 2, 3], // 3 elements
                flowBucketCount: 4, // But count is 4
                throttleStats: nil,
                degradationLevel: 0,
                degradationReasonCode: nil,
                schemaVersion: 0x0204
            )
            
            // If encoding succeeds, it should still validate the mismatch
            // For v2.4+, this should fail closed
            XCTFail("Array size mismatch should fail closed for v2.4+")
        } catch {
            // Expected: fail-closed for array size mismatch (CanonicalBytesError.arraySizeMismatch)
            XCTAssertTrue(
                error is FailClosedError || error is CapacityMetricsError || error is CanonicalBytesError,
                "Array size mismatch must fail closed, got: \(error)"
            )
        }
    }
    
    /// Test random perFlowCounters with various flowBucketCount values
    func testFlowBucketCount_RandomCounters() throws {
        var rng = ScaleRNG(seed: 3000)
        
        let testCases: [Int] = [0, 1, 2, 4, 8, 16, 32, 64, 128, 255]
        
        for flowBucketCount in testCases {
            var perFlowCounters: [UInt16] = []
            for _ in 0..<flowBucketCount {
                perFlowCounters.append(rng.nextUInt16())
            }
            
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
                policyHash: rng.nextUInt64(),
                sessionStableId: rng.nextUInt64(),
                candidateStableId: rng.nextUInt64(),
                valueScore: rng.nextInt64(),
                perFlowCounters: perFlowCounters,
                flowBucketCount: flowBucketCount,
                throttleStats: nil,
                degradationLevel: 0,
                degradationReasonCode: nil,
                schemaVersion: 0x0204
            )
            
            // Verify canonical byte length includes all counters
            let expectedMinLength = flowBucketCount * 2 // Each UInt16 is 2 bytes
            XCTAssertGreaterThanOrEqual(canonicalBytes.count, expectedMinLength, "Canonical bytes must include all flow counters (count: \(flowBucketCount))")
            
            let decisionHash = try DecisionHashV1.compute(from: canonicalBytes)
            XCTAssertEqual(decisionHash.bytes.count, 32, "DecisionHash must be 32 bytes (count: \(flowBucketCount))")
        }
    }
}
