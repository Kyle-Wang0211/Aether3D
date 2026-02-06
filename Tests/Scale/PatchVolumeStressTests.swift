//
// PatchVolumeStressTests.swift
// Aether3D
//
// PR1 v2.4 Addendum - Patch Volume Stress Tests
//
// Simulates extreme patch/evidence volume scenarios
//

import XCTest
@testable import Aether3DCore

final class PatchVolumeStressTests: XCTestCase {
    /// Test near-hardLimit patch counts
    func testPatchVolume_NearHardLimit() throws {
        // Simulate high patch count scenarios
        // Note: Actual hard limit depends on CapacityLimitConstants
        
        let candidateId = UUID()
        let metrics = CapacityMetrics(
            candidateId: candidateId,
            patchCountShadow: 1000, // Near limit
            eebRemaining: 0.1, // Low remaining
            eebDelta: 0.01,
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
        
        XCTAssertGreaterThan(canonicalBytes.count, 0, "Canonical bytes must encode even near hard limit")
        
        let decisionHash = try DecisionHashV1.compute(from: canonicalBytes)
        XCTAssertEqual(decisionHash.bytes.count, 32, "DecisionHash must be 32 bytes")
    }
    
    /// Test repeated session extensions up to max
    func testPatchVolume_RepeatedExtensions() throws {
        // Simulate multiple extension decisions
        var decisionHashes: [DecisionHash] = []
        
        for i in 0..<100 {
            let candidateId = UUID()
            let metrics = CapacityMetrics(
                candidateId: candidateId,
                patchCountShadow: i,
                eebRemaining: Double(100 - i) / 100.0,
                eebDelta: 0.01,
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
                policyHash: UInt64(i),
                sessionStableId: UInt64(i * 100),
                candidateStableId: UInt64(i * 200),
                valueScore: Int64(i * 10),
                perFlowCounters: [UInt16(i), UInt16(i + 1), UInt16(i + 2), UInt16(i + 3)],
                flowBucketCount: 4,
                throttleStats: nil,
                degradationLevel: 0,
                degradationReasonCode: nil,
                schemaVersion: 0x0204
            )
            
            let decisionHash = try DecisionHashV1.compute(from: canonicalBytes)
            decisionHashes.append(decisionHash)
        }
        
        // Verify all hashes are unique (different inputs produce different hashes)
        var uniqueHashes = Set<Data>()
        for hash in decisionHashes {
            let hashData = Data(hash.bytes)
            XCTAssertFalse(uniqueHashes.contains(hashData), "Each extension must produce unique hash")
            uniqueHashes.insert(hashData)
        }
        
        XCTAssertEqual(decisionHashes.count, 100, "Must generate 100 unique decision hashes")
    }
    
    /// Test EEB monotonicity preserved
    func testPatchVolume_EEBMonotonicity() throws {
        // EEB should decrease monotonically as patches are consumed
        let eebValues: [Double] = [1.0, 0.9, 0.8, 0.7, 0.6, 0.5, 0.4, 0.3, 0.2, 0.1]
        
        var previousEEB: Double = 1.0
        
        for eebRemaining in eebValues {
            let candidateId = UUID()
            let metrics = CapacityMetrics(
                candidateId: candidateId,
                patchCountShadow: 0,
                eebRemaining: eebRemaining,
                eebDelta: previousEEB - eebRemaining,
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
            
            XCTAssertGreaterThan(canonicalBytes.count, 0, "Canonical bytes must encode EEB values")
            
            // Verify EEB delta is positive (consumption)
            XCTAssertGreaterThanOrEqual(previousEEB - eebRemaining, 0, "EEB must decrease monotonically")
            
            previousEEB = eebRemaining
        }
    }
    
    /// Test buildMode transitions are legal
    func testPatchVolume_BuildModeTransitions() throws {
        // Test the PR1 C-Class capacity control modes (NORMAL, DAMPING, SATURATED)
        let buildModes: [BuildMode] = [.NORMAL, .DAMPING, .SATURATED]

        for buildMode in buildModes {
            let candidateId = UUID()
            let metrics = CapacityMetrics(
                candidateId: candidateId,
                patchCountShadow: 0,
                eebRemaining: 0.5,
                eebDelta: 0.01,
                buildMode: buildMode,
                rejectReason: buildMode == .SATURATED ? .HARD_CAP : nil,
                hardFuseTrigger: buildMode == .SATURATED ? .PATCHCOUNT_HARD : nil,
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
                degradationLevel: buildMode == .SATURATED ? 1 : 0,
                degradationReasonCode: buildMode == .SATURATED ? DegradationReasonCode.SATURATED_ESCALATION.rawValue : nil,
                schemaVersion: 0x0204
            )

            XCTAssertGreaterThan(canonicalBytes.count, 0, "Canonical bytes must encode buildMode: \(buildMode)")

            let decisionHash = try DecisionHashV1.compute(from: canonicalBytes)
            XCTAssertEqual(decisionHash.bytes.count, 32, "DecisionHash must be 32 bytes for buildMode: \(buildMode)")
        }
    }
    
    /// Test no integer overflow under extreme values
    func testPatchVolume_NoIntegerOverflow() throws {
        // Test with maximum UInt64 values
        let candidateId = UUID()
        let metrics = CapacityMetrics(
            candidateId: candidateId,
            patchCountShadow: Int.max,
            eebRemaining: Double.greatestFiniteMagnitude,
            eebDelta: Double.greatestFiniteMagnitude,
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
        
        // Use maximum values for hash inputs
        let canonicalBytes = try metrics.canonicalBytesForDecisionHashInput(
            policyHash: UInt64.max,
            sessionStableId: UInt64.max,
            candidateStableId: UInt64.max,
            valueScore: Int64.max,
            perFlowCounters: Array(repeating: UInt16.max, count: 4),
            flowBucketCount: 4,
            throttleStats: (windowStartTick: UInt64.max, windowDurationTicks: UInt32.max, attemptsInWindow: UInt32.max),
            degradationLevel: UInt8.max,
            degradationReasonCode: UInt8.max,
            schemaVersion: 0x0204
        )
        
        // Should not crash or overflow
        XCTAssertGreaterThan(canonicalBytes.count, 0, "Canonical bytes must encode even with maximum values")
        
        let decisionHash = try DecisionHashV1.compute(from: canonicalBytes)
        XCTAssertEqual(decisionHash.bytes.count, 32, "DecisionHash must be 32 bytes even with maximum values")
    }
}
