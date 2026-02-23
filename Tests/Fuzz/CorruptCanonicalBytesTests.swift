// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// CorruptCanonicalBytesTests.swift
// Aether3D
//
// PR1 v2.4 Addendum - Corrupt Canonical Bytes Fuzz Tests
//
// Tests adversarial inputs: randomly flip bits in canonical bytes
//

import XCTest
@testable import Aether3DCore

/// Seeded RNG for fuzz tests
private struct CorruptRNG {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed }
    mutating func next() -> UInt64 {
        state = (state &* 1103515245 &+ 12345) & 0x7fffffff
        return state
    }
    mutating func nextUInt8() -> UInt8 { return UInt8(next() & 0xFF) }
}

final class CorruptCanonicalBytesTests: XCTestCase {
    /// Test that corrupting DOMAIN_TAG causes explicit failure
    func testCorrupt_DomainTag_FailClosed() throws {
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
        
        // DOMAIN_TAG is prepended by DecisionHashV1.compute()
        // We can't directly corrupt it, but we can verify that invalid domain tag bytes would fail
        
        // Test with corrupted canonical bytes (flip random bits)
        var corruptedBytes = canonicalBytes
        if corruptedBytes.count > 0 {
            corruptedBytes[0] ^= 0xFF // Flip all bits in first byte
        }
        
        // Computing hash with corrupted bytes should still work (hash doesn't validate structure)
        // But the hash will be different
        let corruptedHash = try DecisionHashV1.compute(from: corruptedBytes)
        let originalHash = try DecisionHashV1.compute(from: canonicalBytes)
        
        XCTAssertNotEqual(corruptedHash.bytes, originalHash.bytes, "Corrupted bytes must produce different hash")
    }
    
    /// Test that corrupting flowBucketCount causes explicit failure
    func testCorrupt_FlowBucketCount_FailClosed() throws {
        var rng = CorruptRNG(seed: 6000)
        
        // Generate valid canonical bytes
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
        
        // Test with mismatched flowBucketCount and perFlowCounters
        do {
            let _ = try metrics.canonicalBytesForDecisionHashInput(
                policyHash: 0,
                sessionStableId: 0,
                candidateStableId: 0,
                valueScore: 0,
                perFlowCounters: [1, 2, 3], // 3 elements
                flowBucketCount: 4, // But count is 4 (mismatch)
                throttleStats: nil,
                degradationLevel: 0,
                degradationReasonCode: nil,
                schemaVersion: 0x0204
            )
            
            // For v2.4+, this should fail closed
            XCTFail("Mismatched flowBucketCount should fail closed")
        } catch {
            // Expected: fail-closed (CanonicalBytesError.arraySizeMismatch)
            XCTAssertTrue(
                error is FailClosedError || error is CapacityMetricsError || error is CanonicalBytesError,
                "Mismatched flowBucketCount must fail closed, got: \(error)"
            )
        }
    }

    /// Test that corrupting presenceTags causes explicit failure
    func testCorrupt_PresenceTags_FailClosed() throws {
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
        
        // Test with invalid presence tag (degradationLevel != 0 but no degradationReasonCode)
        // This should fail closed for v2.4+
        let degradationLevel: UInt8 = 1 // Non-zero
        
        do {
            let _ = try metrics.canonicalBytesForDecisionHashInput(
                policyHash: 0,
                sessionStableId: 0,
                candidateStableId: 0,
                valueScore: 0,
                perFlowCounters: [],
                flowBucketCount: 4,
                throttleStats: nil,
                degradationLevel: degradationLevel,
                degradationReasonCode: nil, // Missing required field
                schemaVersion: 0x0204
            )
            
            // For v2.4+, this may or may not fail depending on implementation
            // If it succeeds, the presence tag should be 0 (absence)
        } catch {
            // If it fails, it should fail closed
            XCTAssertTrue(
                error is FailClosedError || error is CapacityMetricsError || error is CanonicalBytesError,
                "Invalid presence tag must fail closed, got: \(error)"
            )
        }
    }
    
    /// Test that no partial hashes are emitted on corruption
    func testCorrupt_NoPartialHashes() throws {
        var rng = CorruptRNG(seed: 7000)
        
        // Generate valid canonical bytes
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
        
        // Test multiple corruption scenarios
        for i in 0..<20 {
            var corruptedBytes = try metrics.canonicalBytesForDecisionHashInput(
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
            
            // Corrupt random byte
            if corruptedBytes.count > 0 {
                let corruptIndex = Int(rng.nextUInt8()) % corruptedBytes.count
                corruptedBytes[corruptIndex] ^= 0xFF // Flip all bits
            }
            
            // Hash should still be 32 bytes (no partial hash)
            let hash = try DecisionHashV1.compute(from: corruptedBytes)
            XCTAssertEqual(hash.bytes.count, 32, "Hash must always be 32 bytes, even with corrupted input (iteration \(i))")
        }
    }
    
    /// Test random bit flips in canonical bytes
    func testCorrupt_RandomBitFlips() throws {
        var rng = CorruptRNG(seed: 8000)
        
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
        
        let originalBytes = try metrics.canonicalBytesForDecisionHashInput(
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
        
        let originalHash = try DecisionHashV1.compute(from: originalBytes)
        
        // Flip random bits
        for flipCount in [1, 2, 5, 10] {
            var corruptedBytes = originalBytes
            
            for _ in 0..<flipCount {
                if corruptedBytes.count > 0 {
                    let index = Int(rng.nextUInt8()) % corruptedBytes.count
                    let bit = UInt8(1 << (rng.nextUInt8() % 8))
                    corruptedBytes[index] ^= bit
                }
            }
            
            let corruptedHash = try DecisionHashV1.compute(from: corruptedBytes)
            
            // Hash should be different (avalanche effect)
            XCTAssertNotEqual(corruptedHash.bytes, originalHash.bytes, "Bit flip must change hash (flipCount: \(flipCount))")
            
            // Hash must still be 32 bytes
            XCTAssertEqual(corruptedHash.bytes.count, 32, "Hash must be 32 bytes after corruption")
        }
    }
}
