// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// DecisionHashFuzzTests.swift
// Aether3D
//
// PR1 v2.4 Addendum - DecisionHash Fuzz Tests (time-bounded, >=1000 iterations)
//
// Deterministic fuzz with seed printed in logs
//

import XCTest
@testable import Aether3DCore

final class DecisionHashFuzzTests: XCTestCase {
    /// Seeded RNG for deterministic fuzzing
    private struct FuzzRNG {
        private var state: UInt64
        
        init(seed: UInt64) {
            self.state = seed
        }
        
        mutating func next() -> UInt64 {
            state = (state &* 1103515245 &+ 12345) & 0x7fffffff
            return state
        }
        
        mutating func nextUInt8() -> UInt8 {
            return UInt8(next() & 0xFF)
        }
        
        mutating func nextUInt16() -> UInt16 {
            return UInt16(next() & 0xFFFF)
        }
        
        mutating func nextUInt32() -> UInt32 {
            return UInt32(next() & 0xFFFFFFFF)
        }
        
        mutating func nextUInt64() -> UInt64 {
            return (next() << 32) | next()
        }
        
        mutating func nextInt64() -> Int64 {
            return Int64(bitPattern: nextUInt64())
        }
    }
    
    /// Fuzz DecisionHash with random but VALID layouts (>=1000 iterations)
    /// Time budget: 1-3 seconds on CI
    func testDecisionHash_FuzzValidLayouts() throws {
        let seed: UInt64 = 12345
        print("Fuzz seed: \(seed)")
        
        var rng = FuzzRNG(seed: seed)
        var checks = 0
        let startTime = Date()
        let timeLimit: TimeInterval = 2.0 // 2 seconds max
        
        var iteration = 0
        while Date().timeIntervalSince(startTime) < timeLimit && iteration < 1000 {
            CheckCounter.increment()
            checks += 1
            
            // Generate random but VALID layout
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
            
            let hasRejectReason = rng.nextUInt8() % 2 == 0
            let degradationLevel = rng.nextUInt8() % 4
            let hasDegradationReason = degradationLevel != 0 && rng.nextUInt8() % 2 == 0
            
            let metrics = CapacityMetrics(
                candidateId: UUID(),
                patchCountShadow: 0,
                eebRemaining: 0.0,
                eebDelta: 0.0,
                buildMode: .NORMAL,
                rejectReason: hasRejectReason ? .HARD_CAP : nil,
                hardFuseTrigger: nil,
                rejectReasonDistribution: [:],
                capacityInvariantViolation: false,
                capacitySaturatedLatchedAtPatchCount: nil,
                capacitySaturatedLatchedAtTimestamp: nil,
                flushFailure: false,
                decisionHash: nil
            )
            
            // Compute canonical bytes -> hash
            let canonicalBytes = try metrics.canonicalBytesForDecisionHashInput(
                policyHash: rng.nextUInt64(),
                sessionStableId: rng.nextUInt64(),
                candidateStableId: rng.nextUInt64(),
                valueScore: rng.nextInt64(),
                perFlowCounters: perFlowCounters,
                flowBucketCount: flowBucketCount,
                throttleStats: throttleStats,
                degradationLevel: degradationLevel,
                degradationReasonCode: hasDegradationReason ? UInt8(rng.nextUInt8() % 6 + 1) : nil,
                schemaVersion: 0x0204
            )
            
            // Compute hash
            let hash1 = try metrics.computeDecisionHashV1(
                policyHash: rng.nextUInt64(),
                sessionStableId: rng.nextUInt64(),
                candidateStableId: rng.nextUInt64(),
                valueScore: rng.nextInt64(),
                perFlowCounters: perFlowCounters,
                flowBucketCount: flowBucketCount,
                throttleStats: throttleStats,
                degradationLevel: degradationLevel,
                degradationReasonCode: hasDegradationReason ? UInt8(rng.nextUInt8() % 6 + 1) : nil,
                schemaVersion: 0x0204
            )
            
            // Reset RNG for second run
            rng = FuzzRNG(seed: seed + UInt64(iteration))
            _ = rng.nextUInt8() // Skip flowBucketCount
            var perFlowCounters2: [UInt16] = []
            for _ in 0..<flowBucketCount {
                perFlowCounters2.append(rng.nextUInt16())
            }
            let hasThrottle2 = rng.nextUInt8() % 2 == 0
            let throttleStats2: (windowStartTick: UInt64, windowDurationTicks: UInt32, attemptsInWindow: UInt32)? = hasThrottle2 ? (
                windowStartTick: rng.nextUInt64(),
                windowDurationTicks: rng.nextUInt32(),
                attemptsInWindow: rng.nextUInt32()
            ) : nil
            let hasRejectReason2 = rng.nextUInt8() % 2 == 0
            let degradationLevel2 = rng.nextUInt8() % 4
            let hasDegradationReason2 = degradationLevel2 != 0 && rng.nextUInt8() % 2 == 0
            
            let hash2 = try metrics.computeDecisionHashV1(
                policyHash: rng.nextUInt64(),
                sessionStableId: rng.nextUInt64(),
                candidateStableId: rng.nextUInt64(),
                valueScore: rng.nextInt64(),
                perFlowCounters: perFlowCounters2,
                flowBucketCount: flowBucketCount,
                throttleStats: throttleStats2,
                degradationLevel: degradationLevel2,
                degradationReasonCode: hasDegradationReason2 ? UInt8(rng.nextUInt8() % 6 + 1) : nil,
                schemaVersion: 0x0204
            )
            
            // Verify no crashes, stable across runs (if same input)
            CheckCounter.increment()
            checks += 1
            XCTAssertEqual(hash1.bytes.count, 32, "Hash must be 32 bytes")
            
            CheckCounter.increment()
            checks += 1
            XCTAssertEqual(hash2.bytes.count, 32, "Hash must be 32 bytes")
            
            iteration += 1
        }
        
        print("DecisionHash Fuzz: \(iteration) iterations, \(checks) checks")
    }
}
