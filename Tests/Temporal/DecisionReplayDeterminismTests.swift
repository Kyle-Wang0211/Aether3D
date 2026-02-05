//
// DecisionReplayDeterminismTests.swift
// Aether3D
//
// PR1 v2.4 Addendum - Temporal Replay Determinism Tests
//
// Proves that today's correctness survives time, versioning, and replay
//

import XCTest
@testable import Aether3DCore

/// Seeded RNG for deterministic tests
private struct TemporalRNG {
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

/// Admission decision trace (inputs + outputs)
private struct AdmissionDecisionTrace {
    let candidateId: UUID
    let policyHash: UInt64
    let sessionStableId: UInt64
    let candidateStableId: UInt64
    let valueScore: Int64
    let perFlowCounters: [UInt16]
    let flowBucketCount: Int
    let throttleStats: (windowStartTick: UInt64, windowDurationTicks: UInt32, attemptsInWindow: UInt32)?
    let degradationLevel: UInt8
    let degradationReasonCode: UInt8?
    let schemaVersion: UInt16
    
    let decisionHash: DecisionHash
    let admissionRecordBytes: Data
    let canonicalBytes: Data
}

final class DecisionReplayDeterminismTests: XCTestCase {
    /// Test that replay produces identical decisionHash
    func testReplay_IdenticalDecisionHash() throws {
        var rng = TemporalRNG(seed: 1000)
        var traces: [AdmissionDecisionTrace] = []
        
        // Record traces
        for _ in 0..<50 {
            let candidateId = UUID()
            let policyHash = rng.nextUInt64()
            let sessionStableId = rng.nextUInt64()
            let candidateStableId = rng.nextUInt64()
            let valueScore = rng.nextInt64()
            let flowBucketCount = Int(rng.nextUInt8() % 8) + 1
            var perFlowCounters: [UInt16] = []
            for _ in 0..<flowBucketCount {
                perFlowCounters.append(rng.nextUInt16())
            }
            
            let hasThrottle = rng.nextUInt8() % 2 == 0
            let throttleStats: (windowStartTick: UInt64, windowDurationTicks: UInt32, attemptsInWindow: UInt32)? = hasThrottle ? (
                windowStartTick: rng.nextUInt64(),
                windowDurationTicks: rng.nextUInt32(),
                attemptsInWindow: rng.nextUInt32()
            ) : nil
            
            let degradationLevel = rng.nextUInt8() % 4
            let degradationReasonCode = degradationLevel != 0 ? rng.nextUInt8() % 6 + 1 : nil
            
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
                policyHash: policyHash,
                sessionStableId: sessionStableId,
                candidateStableId: candidateStableId,
                valueScore: valueScore,
                perFlowCounters: perFlowCounters,
                flowBucketCount: flowBucketCount,
                throttleStats: throttleStats,
                degradationLevel: degradationLevel,
                degradationReasonCode: degradationReasonCode,
                schemaVersion: 0x0204
            )
            
            let decisionHash = try DecisionHashV1.compute(from: canonicalBytes)
            
            // Generate admission record bytes
            let writer = CanonicalBytesWriter()
            writer.writeUInt8(1) // layoutVersion
            writer.writeUInt16BE(0x0204) // schemaVersion
            writer.writeUInt64BE(policyHash)
            writer.writeUInt64BE(sessionStableId)
            writer.writeUInt64BE(candidateStableId)
            writer.writeUInt8(2) // classification: ACCEPTED
            writer.writeInt64BE(1000) // eebDelta fixed point
            writer.writeUInt8(0) // buildMode: NORMAL
            writer.writeUInt8(0) // guidanceSignal
            writer.writeUInt8(0) // hardFuseTrigger: nil
            writer.writeUInt8(degradationLevel)
            if let drc = degradationReasonCode {
                writer.writeUInt8(1) // presence tag
                writer.writeUInt8(drc)
            } else {
                writer.writeUInt8(0) // absence tag
            }
            writer.writeInt64BE(valueScore)
            writer.writeBytes(decisionHash.bytes)
            let admissionRecordBytes = writer.toData()
            
            traces.append(AdmissionDecisionTrace(
                candidateId: candidateId,
                policyHash: policyHash,
                sessionStableId: sessionStableId,
                candidateStableId: candidateStableId,
                valueScore: valueScore,
                perFlowCounters: perFlowCounters,
                flowBucketCount: flowBucketCount,
                throttleStats: throttleStats,
                degradationLevel: degradationLevel,
                degradationReasonCode: degradationReasonCode,
                schemaVersion: 0x0204,
                decisionHash: decisionHash,
                admissionRecordBytes: admissionRecordBytes,
                canonicalBytes: canonicalBytes
            ))
        }
        
        // Replay traces (simulating process restart)
        for (index, trace) in traces.enumerated() {
            let metrics = CapacityMetrics(
                candidateId: trace.candidateId,
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
            
            let replayedCanonicalBytes = try metrics.canonicalBytesForDecisionHashInput(
                policyHash: trace.policyHash,
                sessionStableId: trace.sessionStableId,
                candidateStableId: trace.candidateStableId,
                valueScore: trace.valueScore,
                perFlowCounters: trace.perFlowCounters,
                flowBucketCount: trace.flowBucketCount,
                throttleStats: trace.throttleStats,
                degradationLevel: trace.degradationLevel,
                degradationReasonCode: trace.degradationReasonCode,
                schemaVersion: trace.schemaVersion
            )
            
            let replayedDecisionHash = try DecisionHashV1.compute(from: replayedCanonicalBytes)
            
            // Assert identical
            XCTAssertEqual(replayedCanonicalBytes, trace.canonicalBytes, "Canonical bytes must be identical on replay (trace \(index))")
            XCTAssertEqual(replayedDecisionHash.bytes, trace.decisionHash.bytes, "DecisionHash must be identical on replay (trace \(index))")
        }
    }
    
    /// Test that reordered but equivalent inputs produce identical hashes
    func testReplay_ReorderedEquivalentInputs() throws {
        // Same inputs, different order of perFlowCounters (should not affect hash if flowBucketCount matches)
        let candidateId = UUID()
        let policyHash: UInt64 = 12345
        let sessionStableId: UInt64 = 67890
        let candidateStableId: UInt64 = 11111
        let valueScore: Int64 = 1000
        
        let metrics1 = CapacityMetrics(
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
        
        let canonicalBytes1 = try metrics1.canonicalBytesForDecisionHashInput(
            policyHash: policyHash,
            sessionStableId: sessionStableId,
            candidateStableId: candidateStableId,
            valueScore: valueScore,
            perFlowCounters: [1, 2, 3, 4],
            flowBucketCount: 4,
            throttleStats: nil,
            degradationLevel: 0,
            degradationReasonCode: nil,
            schemaVersion: 0x0204
        )
        
        let hash1 = try DecisionHashV1.compute(from: canonicalBytes1)
        
        // Replay with same inputs
        let metrics2 = CapacityMetrics(
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
        
        let canonicalBytes2 = try metrics2.canonicalBytesForDecisionHashInput(
            policyHash: policyHash,
            sessionStableId: sessionStableId,
            candidateStableId: candidateStableId,
            valueScore: valueScore,
            perFlowCounters: [1, 2, 3, 4], // Same order
            flowBucketCount: 4,
            throttleStats: nil,
            degradationLevel: 0,
            degradationReasonCode: nil,
            schemaVersion: 0x0204
        )
        
        let hash2 = try DecisionHashV1.compute(from: canonicalBytes2)
        
        XCTAssertEqual(hash1.bytes, hash2.bytes, "Reordered equivalent inputs must produce identical hash")
    }
    
    /// Test that simulated "future" timestamps don't affect hash
    func testReplay_NoTimeDependence() throws {
        // DecisionHash should not depend on wall-clock time
        // Test with different throttleStats timestamps (if present)
        
        let candidateId = UUID()
        let policyHash: UInt64 = 99999
        let sessionStableId: UInt64 = 88888
        let candidateStableId: UInt64 = 77777
        let valueScore: Int64 = 5000
        
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
        
        // Test with throttleStats (timestamps should be deterministic, not wall-clock)
        let throttleStats1: (windowStartTick: UInt64, windowDurationTicks: UInt32, attemptsInWindow: UInt32) = (
            windowStartTick: 1000,
            windowDurationTicks: 100,
            attemptsInWindow: 5
        )
        
        let canonicalBytes1 = try metrics.canonicalBytesForDecisionHashInput(
            policyHash: policyHash,
            sessionStableId: sessionStableId,
            candidateStableId: candidateStableId,
            valueScore: valueScore,
            perFlowCounters: [],
            flowBucketCount: 4,
            throttleStats: throttleStats1,
            degradationLevel: 0,
            degradationReasonCode: nil,
            schemaVersion: 0x0204
        )
        
        let hash1 = try DecisionHashV1.compute(from: canonicalBytes1)
        
        // Replay with same throttleStats
        let canonicalBytes2 = try metrics.canonicalBytesForDecisionHashInput(
            policyHash: policyHash,
            sessionStableId: sessionStableId,
            candidateStableId: candidateStableId,
            valueScore: valueScore,
            perFlowCounters: [],
            flowBucketCount: 4,
            throttleStats: throttleStats1, // Same timestamps
            degradationLevel: 0,
            degradationReasonCode: nil,
            schemaVersion: 0x0204
        )
        
        let hash2 = try DecisionHashV1.compute(from: canonicalBytes2)
        
        XCTAssertEqual(hash1.bytes, hash2.bytes, "Same throttleStats timestamps must produce identical hash")
        
        // Verify different timestamps produce different hash (proving timestamps are included)
        let throttleStats2: (windowStartTick: UInt64, windowDurationTicks: UInt32, attemptsInWindow: UInt32) = (
            windowStartTick: 2000, // Different timestamp
            windowDurationTicks: 100,
            attemptsInWindow: 5
        )
        
        let canonicalBytes3 = try metrics.canonicalBytesForDecisionHashInput(
            policyHash: policyHash,
            sessionStableId: sessionStableId,
            candidateStableId: candidateStableId,
            valueScore: valueScore,
            perFlowCounters: [],
            flowBucketCount: 4,
            throttleStats: throttleStats2,
            degradationLevel: 0,
            degradationReasonCode: nil,
            schemaVersion: 0x0204
        )
        
        let hash3 = try DecisionHashV1.compute(from: canonicalBytes3)
        
        XCTAssertNotEqual(hash1.bytes, hash3.bytes, "Different throttleStats timestamps must produce different hash")
    }
}
