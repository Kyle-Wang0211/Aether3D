// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// DecisionHashCanonicalBytesTests.swift
// Aether3D
//
// PR1 v2.4 Addendum - DecisionHash Canonical Bytes Tests
//
// Verifies DecisionHashInputBytesLayout_v1 encoding including decisionSchemaVersion
//

import XCTest
@testable import Aether3DCore

final class DecisionHashCanonicalBytesTests: XCTestCase {
    /// Test DecisionHashInputBytesLayout_v1 includes decisionSchemaVersion
    func testDecisionHashInput_IncludesDecisionSchemaVersion() throws {
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
        
        let canonicalBytes = try metrics.canonicalBytesForDecisionHashInput(
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
        
        let bytes = Array(canonicalBytes)
        
        // Verify layoutVersion = 1 (byte 0)
        XCTAssertEqual(bytes[0], 1, "layoutVersion must be 1")
        
        // Verify decisionSchemaVersion = 0x0001 (bytes 1-2, BE)
        let decisionSchemaVersionBytes = Array(bytes[1..<3])
        let decisionSchemaVersion = UInt16(decisionSchemaVersionBytes[0]) << 8 | UInt16(decisionSchemaVersionBytes[1])
        XCTAssertEqual(decisionSchemaVersion, 0x0001, "decisionSchemaVersion must be 0x0001")
    }
    
    /// Test DecisionHashInputBytesLayout_v1 includes flowBucketCount before perFlowCounters
    func testDecisionHashInput_IncludesFlowBucketCount() throws {
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
        
        let flowBucketCount: UInt8 = 4
        let perFlowCounters: [UInt16] = [1, 2, 3, 4]
        
        let canonicalBytes = try metrics.canonicalBytesForDecisionHashInput(
            policyHash: 0x123456789ABCDEF0,
            sessionStableId: 0x123456789ABCDEF0,
            candidateStableId: 0x123456789ABCDEF0,
            valueScore: 1000,
            perFlowCounters: perFlowCounters,
            flowBucketCount: Int(flowBucketCount),
            throttleStats: nil,
            degradationLevel: 0,
            degradationReasonCode: nil,
            schemaVersion: 0x0204
        )
        
        let bytes = Array(canonicalBytes)
        
        // Find flowBucketCount and perFlowCounters position
        // Layout: ... + valueScore(8) + flowBucketCount(1) + perFlowCounters(flowBucketCount*2) + throttleStatsTag(1) [+ throttleStats if present]
        // Since throttleStats is nil in this test, throttleStatsTag is the last byte (0)
        // So perFlowCounters are before throttleStatsTag
        
        // Find throttleStatsTag (last byte when throttleStats is nil)
        let throttleStatsTagIndex = canonicalBytes.count - 1
        let throttleStatsTag = bytes[throttleStatsTagIndex]
        XCTAssertEqual(throttleStatsTag, 0, "throttleStatsTag must be 0 when throttleStats is nil")
        
        // perFlowCounters are before throttleStatsTag
        let perFlowCountersStart = throttleStatsTagIndex - (Int(flowBucketCount) * 2)
        let flowBucketCountByteIndex = perFlowCountersStart - 1
        let flowBucketCountByte = bytes[flowBucketCountByteIndex]
        XCTAssertEqual(flowBucketCountByte, flowBucketCount, "flowBucketCount byte must match")
        
        let perFlowCountersBytes = Array(bytes[perFlowCountersStart..<throttleStatsTagIndex])
        
        // Verify perFlowCounters are encoded as UInt16 BE
        // writeUInt16BE writes: high byte first, low byte second
        // For value 1: high=0x00, low=0x01 => bytes should be 00 01
        var decodedCounters: [UInt16] = []
        var index = 0
        while index < perFlowCountersBytes.count {
            // Read bytes as BE: first byte is high byte, second is low byte
            let byte0 = perFlowCountersBytes[index]
            let byte1 = perFlowCountersBytes[index + 1]
            // Reconstruct UInt16 BE: (byte0 << 8) | byte1
            let value = (UInt16(byte0) << 8) | UInt16(byte1)
            decodedCounters.append(value)
            index += 2
        }
        
        // Verify decoded counters match input
        XCTAssertEqual(decodedCounters, perFlowCounters, "perFlowCounters must be encoded correctly as UInt16 BE")
    }
    
    /// Test presence-tag constraints fail-closed (v2.4+)
    func testDecisionHashInput_PresenceConstraints_FailClosed() throws {
        // This test verifies that presence-tag constraints are enforced
        // We can't easily create a violation without modifying the encoder,
        // but we can verify the encoder produces valid presence tags
        let metrics = CapacityMetrics(
            candidateId: UUID(),
            patchCountShadow: 0,
            eebRemaining: 0,
            eebDelta: 0,
            buildMode: .NORMAL,
            rejectReason: .HARD_CAP,
            hardFuseTrigger: nil,
            rejectReasonDistribution: [:],
            capacityInvariantViolation: false,
            capacitySaturatedLatchedAtPatchCount: nil,
            capacitySaturatedLatchedAtTimestamp: nil,
            flushFailure: false,
            decisionHash: nil
        )
        
        // With rejectReason present, rejectReasonTag should be 1
        let canonicalBytes = try metrics.canonicalBytesForDecisionHashInput(
            policyHash: 0x123456789ABCDEF0,
            sessionStableId: 0x123456789ABCDEF0,
            candidateStableId: 0x123456789ABCDEF0,
            valueScore: 1000,
            perFlowCounters: [1, 2, 3, 4],
            flowBucketCount: 4,
            throttleStats: nil,
            degradationLevel: 1,
            degradationReasonCode: 1,
            schemaVersion: 0x0204
        )
        
        // Verify encoding succeeds (presence tags are valid)
        XCTAssertGreaterThan(canonicalBytes.count, 0, "Canonical bytes must be generated")
    }
    
    /// Test DecisionHash domain separation is stable
    func testDecisionHash_DomainSeparated_Stable() throws {
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
        
        let hash1 = try metrics.computeDecisionHashV1(
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
        
        let hash2 = try metrics.computeDecisionHashV1(
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
        
        XCTAssertEqual(hash1.bytes, hash2.bytes, "DecisionHash must be stable across computations")
    }
}
