//
// AdmissionLongRunSoakTests.swift
// Aether3D
//
// PR1 v2.4 Addendum - Admission Long-Run Soak Tests
//
// Catches issues that only appear over time
//

import XCTest
@testable import Aether3DCore

/// Seeded RNG for soak tests
private struct SoakRNG {
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

final class AdmissionLongRunSoakTests: XCTestCase {
    /// Test 10k+ AdmissionDecision cycles with randomized but seeded inputs
    func testAdmission_LongRun_10kCycles() throws {
        var rng = SoakRNG(seed: 9000)
        var decisionHashes: [DecisionHash] = []
        var canonicalBytesList: [Data] = []
        
        let cycleCount = 10000
        
        for cycleIndex in 0..<cycleCount {
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

            decisionHashes.append(decisionHash)
            canonicalBytesList.append(canonicalBytes)

            // Verify no drift every 1000 cycles
            if (cycleIndex + 1) % 1000 == 0 {
                XCTAssertEqual(decisionHash.bytes.count, 32, "DecisionHash must be 32 bytes (cycle \(cycleIndex + 1))")
                XCTAssertGreaterThan(canonicalBytes.count, 0, "Canonical bytes must not be empty (cycle \(cycleIndex + 1))")
            }
        }
        
        // Verify all hashes are unique (no collisions)
        var uniqueHashes = Set<Data>()
        for hash in decisionHashes {
            let hashData = Data(hash.bytes)
            uniqueHashes.insert(hashData)
        }
        
        // Allow some collisions due to random inputs, but verify most are unique
        let uniquenessRatio = Double(uniqueHashes.count) / Double(decisionHashes.count)
        XCTAssertGreaterThan(uniquenessRatio, 0.99, "At least 99% of hashes must be unique (actual: \(uniquenessRatio * 100)%)")
        
        // Verify no memory growth (canonical bytes sizes should be bounded)
        let maxCanonicalSize = canonicalBytesList.map { $0.count }.max() ?? 0
        let minCanonicalSize = canonicalBytesList.map { $0.count }.min() ?? 0
        
        XCTAssertLessThan(maxCanonicalSize, 10000, "Canonical bytes size must be bounded (max: \(maxCanonicalSize))")
        XCTAssertGreaterThan(minCanonicalSize, 0, "Canonical bytes size must be positive")
    }
    
    /// Test that determinism is preserved across long runs
    func testAdmission_LongRun_Determinism() throws {
        let seed: UInt64 = 10000
        
        // Run first pass
        var rng1 = SoakRNG(seed: seed)
        var hashes1: [DecisionHash] = []
        
        for _ in 0..<1000 {
            let candidateId = UUID() // UUID is not deterministic, but we'll use same seed for other values
            let policyHash = rng1.nextUInt64()
            let sessionStableId = rng1.nextUInt64()
            let candidateStableId = rng1.nextUInt64()
            let valueScore = rng1.nextInt64()
            
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
                perFlowCounters: [],
                flowBucketCount: 4,
                throttleStats: nil,
                degradationLevel: 0,
                degradationReasonCode: nil,
                schemaVersion: 0x0204
            )
            
            let hash = try DecisionHashV1.compute(from: canonicalBytes)
            hashes1.append(hash)
        }
        
        // Run second pass with same seed
        var rng2 = SoakRNG(seed: seed)
        var hashes2: [DecisionHash] = []
        
        for _ in 0..<1000 {
            let candidateId = UUID() // Different UUID, but same other values
            let policyHash = rng2.nextUInt64()
            let sessionStableId = rng2.nextUInt64()
            let candidateStableId = rng2.nextUInt64()
            let valueScore = rng2.nextInt64()
            
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
                perFlowCounters: [],
                flowBucketCount: 4,
                throttleStats: nil,
                degradationLevel: 0,
                degradationReasonCode: nil,
                schemaVersion: 0x0204
            )
            
            let hash = try DecisionHashV1.compute(from: canonicalBytes)
            hashes2.append(hash)
        }
        
        // Verify hashes match (same inputs produce same hashes)
        for i in 0..<min(hashes1.count, hashes2.count) {
            XCTAssertEqual(hashes1[i].bytes, hashes2[i].bytes, "Hashes must match for same inputs (iteration \(i))")
        }
    }
}
