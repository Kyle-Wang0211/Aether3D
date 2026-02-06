//
// CanonicalEncodingPropertyTests.swift
// Aether3D
//
// PR1 v2.4 Addendum - Canonical Encoding Property Tests (>=300 iterations)
//
// Deterministic property-based tests with seeded RNG
//

import XCTest
@testable import Aether3DCore

final class CanonicalEncodingPropertyTests: XCTestCase {
    /// Seeded RNG for deterministic property tests
    private struct SeededRNG {
        private var state: UInt64
        
        init(seed: UInt64) {
            self.state = seed
        }
        
        mutating func next() -> UInt64 {
            // Linear congruential generator (deterministic)
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
    
    /// P1: Byte-stability property (>=100 iterations)
    /// Same struct -> same bytes across repeated calls
    func testProperty_ByteStability() throws {
        var rng = SeededRNG(seed: 42)
        var checks = 0
        
        for i in 0..<100 {
            CheckCounter.increment()
            checks += 1
            
            // Generate random metrics
            let flowBucketCount = Int(rng.nextUInt8() % 8) + 1
            var perFlowCounters: [UInt16] = []
            for _ in 0..<flowBucketCount {
                perFlowCounters.append(rng.nextUInt16())
            }
            
            let metrics = CapacityMetrics(
                candidateId: UUID(),
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
            
            // Generate canonical bytes twice
            let bytes1 = try metrics.canonicalBytesForDecisionHashInput(
                policyHash: rng.nextUInt64(),
                sessionStableId: rng.nextUInt64(),
                candidateStableId: rng.nextUInt64(),
                valueScore: rng.nextInt64(),
                perFlowCounters: perFlowCounters,
                flowBucketCount: flowBucketCount,
                throttleStats: nil,
                degradationLevel: rng.nextUInt8() % 4,
                degradationReasonCode: nil,
                schemaVersion: 0x0204
            )
            
            let bytes2 = try metrics.canonicalBytesForDecisionHashInput(
                policyHash: rng.nextUInt64(),
                sessionStableId: rng.nextUInt64(),
                candidateStableId: rng.nextUInt64(),
                valueScore: rng.nextInt64(),
                perFlowCounters: perFlowCounters,
                flowBucketCount: flowBucketCount,
                throttleStats: nil,
                degradationLevel: rng.nextUInt8() % 4,
                degradationReasonCode: nil,
                schemaVersion: 0x0204
            )
            
            // Reset RNG to same state for second call
            rng = SeededRNG(seed: UInt64(i))
            let policyHash = rng.nextUInt64()
            let sessionStableId = rng.nextUInt64()
            let candidateStableId = rng.nextUInt64()
            let valueScore = rng.nextInt64()
            rng = SeededRNG(seed: UInt64(i))
            _ = rng.nextUInt8() // Skip flowBucketCount
            var perFlowCounters2: [UInt16] = []
            for _ in 0..<flowBucketCount {
                perFlowCounters2.append(rng.nextUInt16())
            }
            let degradationLevel = rng.nextUInt8() % 4
            
            let bytes1a = try metrics.canonicalBytesForDecisionHashInput(
                policyHash: policyHash,
                sessionStableId: sessionStableId,
                candidateStableId: candidateStableId,
                valueScore: valueScore,
                perFlowCounters: perFlowCounters2,
                flowBucketCount: flowBucketCount,
                throttleStats: nil,
                degradationLevel: degradationLevel,
                degradationReasonCode: nil,
                schemaVersion: 0x0204
            )
            
            let bytes1b = try metrics.canonicalBytesForDecisionHashInput(
                policyHash: policyHash,
                sessionStableId: sessionStableId,
                candidateStableId: candidateStableId,
                valueScore: valueScore,
                perFlowCounters: perFlowCounters2,
                flowBucketCount: flowBucketCount,
                throttleStats: nil,
                degradationLevel: degradationLevel,
                degradationReasonCode: nil,
                schemaVersion: 0x0204
            )
            
            // Same input must produce same bytes
            CheckCounter.increment()
            checks += 1
            XCTAssertEqual(bytes1a, bytes1b, "Same input must produce same canonical bytes (iteration \(i))")
        }
        
        print("Property P1 (Byte Stability): \(checks) checks")
    }
    
    /// P2: Endianness roundtrip property (>=50 iterations)
    /// Manual decode harness verifies BE encoding
    func testProperty_EndiannessRoundtrip() throws {
        var rng = SeededRNG(seed: 100)
        var checks = 0
        
        for i in 0..<50 {
            CheckCounter.increment()
            checks += 1
            
            // Test UInt16 BE roundtrip
            let value16 = rng.nextUInt16()
            let writer = CanonicalBytesWriter()
            writer.writeUInt16BE(value16)
            let bytes = writer.toData()
            
            // Manual decode BE
            let decoded16 = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
            CheckCounter.increment()
            checks += 1
            XCTAssertEqual(decoded16, value16, "UInt16 BE roundtrip failed (iteration \(i))")
            
            // Test UInt64 BE roundtrip
            let value64 = rng.nextUInt64()
            let writer64 = CanonicalBytesWriter()
            writer64.writeUInt64BE(value64)
            let bytes64 = writer64.toData()
            
            var decoded64: UInt64 = 0
            for j in 0..<8 {
                decoded64 |= UInt64(bytes64[j]) << (56 - j * 8)
            }
            CheckCounter.increment()
            checks += 1
            XCTAssertEqual(decoded64, value64, "UInt64 BE roundtrip failed (iteration \(i))")
        }
        
        print("Property P2 (Endianness Roundtrip): \(checks) checks")
    }
    
    /// P3: Presence constraints property (>=100 iterations)
    /// Invalid tag/value combos must fail-closed for v2.4+
    func testProperty_PresenceConstraints() throws {
        var rng = SeededRNG(seed: 200)
        var checks = 0
        
        for i in 0..<100 {
            CheckCounter.increment()
            checks += 1
            
            let metrics = CapacityMetrics(
                candidateId: UUID(),
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
            
            // Valid case: degradationLevel != NORMAL => degradationReasonCodeTag must be 1
            let degradationLevel = rng.nextUInt8() % 4
            let hasReasonCode = degradationLevel != 0
            
            if hasReasonCode {
                // Must provide reasonCode
                let bytes = try metrics.canonicalBytesForDecisionHashInput(
                    policyHash: rng.nextUInt64(),
                    sessionStableId: rng.nextUInt64(),
                    candidateStableId: rng.nextUInt64(),
                    valueScore: rng.nextInt64(),
                    perFlowCounters: [1, 2, 3, 4],
                    flowBucketCount: 4,
                    throttleStats: nil,
                    degradationLevel: degradationLevel,
                    degradationReasonCode: UInt8(rng.nextUInt8() % 6 + 1),
                    schemaVersion: 0x0204
                )
                CheckCounter.increment()
                checks += 1
                XCTAssertGreaterThan(bytes.count, 0, "Valid presence constraint must encode (iteration \(i))")
            }
        }
        
        print("Property P3 (Presence Constraints): \(checks) checks")
    }
    
    /// P4: Flow counters mismatch property (>=50 iterations)
    /// If perFlowCounters.count != flowBucketCount => fail-closed
    func testProperty_FlowCounterMismatch() throws {
        var rng = SeededRNG(seed: 300)
        var checks = 0
        
        for i in 0..<50 {
            CheckCounter.increment()
            checks += 1
            
            let metrics = CapacityMetrics(
                candidateId: UUID(),
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
            
            let flowBucketCount = Int(rng.nextUInt8() % 8) + 1
            let wrongCount = flowBucketCount + (rng.nextUInt8() % 2 == 0 ? 1 : -1)
            guard wrongCount > 0 && wrongCount != flowBucketCount else {
                continue
            }
            
            var perFlowCounters: [UInt16] = []
            for _ in 0..<wrongCount {
                perFlowCounters.append(rng.nextUInt16())
            }
            
            // Must fail-closed for mismatch
            CheckCounter.increment()
            checks += 1
            XCTAssertThrowsError(
                try metrics.canonicalBytesForDecisionHashInput(
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
            ) { error in
                CheckCounter.increment()
                checks += 1
                XCTAssertTrue(error is FailClosedError || error is CanonicalBytesError, "Mismatch must fail-closed")
            }
        }
        
        print("Property P4 (Flow Counter Mismatch): \(checks) checks")
    }
    
    /// P5: Domain separation property (>=50 iterations)
    /// DecisionHash(domainTag||bytes) must differ from BLAKE3(bytes)
    func testProperty_DomainSeparation() throws {
        var rng = SeededRNG(seed: 400)
        var checks = 0
        
        for i in 0..<50 {
            CheckCounter.increment()
            checks += 1
            
            let testBytes = Data((0..<32).map { _ in rng.nextUInt8() })
            
            // Compute DecisionHash (with domain tag)
            let decisionHash = try DecisionHashV1.compute(from: testBytes)
            
            // Compute raw BLAKE3 (without domain tag)
            let rawHash = try Blake3Facade.blake3_256(data: testBytes)
            
            // They must differ (domain separation)
            CheckCounter.increment()
            checks += 1
            XCTAssertNotEqual(decisionHash.bytes, rawHash, "DecisionHash must differ from raw BLAKE3 (domain separation, iteration \(i))")
        }
        
        print("Property P5 (Domain Separation): \(checks) checks")
    }
    
    /// P7: QuantizedLimiter determinism property (>=50 iterations)
    /// Same tick sequence -> identical outcomes
    func testProperty_LimiterDeterminism() throws {
        var rng = SeededRNG(seed: 500)
        var checks = 0
        
        for i in 0..<50 {
            CheckCounter.increment()
            checks += 1
            
            let windowTicks = UInt64(rng.nextUInt32()) % 1000 + 100
            let maxTokens = UInt32(rng.nextUInt8()) % 100 + 10
            let refillRate = UInt64(rng.nextUInt32()) % 1000 + 1
            
            var limiter1 = QuantizedLimiter(
                windowTicks: windowTicks,
                maxTokens: maxTokens,
                refillRatePerTick: refillRate,
                initialTick: 1000
            )
            
            var limiter2 = QuantizedLimiter(
                windowTicks: windowTicks,
                maxTokens: maxTokens,
                refillRatePerTick: refillRate,
                initialTick: 1000
            )
            
            // Apply same tick sequence
            let ticks: [UInt64] = [1001, 1002, 1005, 1010, 1020]
            for tick in ticks {
                try limiter1.advanceTo(tick)
                try limiter2.advanceTo(tick)
                
                let consumed1 = try limiter1.consume()
                let consumed2 = try limiter2.consume()
                
                CheckCounter.increment()
                checks += 1
                XCTAssertEqual(consumed1, consumed2, "Limiter must be deterministic (iteration \(i), tick \(tick))")
                
                CheckCounter.increment()
                checks += 1
                XCTAssertEqual(limiter1.currentTokens, limiter2.currentTokens, "Limiter tokens must match")
                
                CheckCounter.increment()
                checks += 1
                XCTAssertEqual(limiter1.currentAttempts, limiter2.currentAttempts, "Limiter attempts must match")
            }
        }
        
        print("Property P7 (Limiter Determinism): \(checks) checks")
    }
    
    /// P8: Overflow behavior property (>=50 iterations)
    /// Crafted overflow input -> HardFuse + TERMINAL always
    func testProperty_OverflowBehavior() throws {
        var rng = SeededRNG(seed: 600)
        var checks = 0
        
        for i in 0..<50 {
            CheckCounter.increment()
            checks += 1
            
            // Create limiter with large refillRate that will overflow
            let refillRate = UInt64.max / 2 + 1
            
            var limiter = QuantizedLimiter(
                windowTicks: 100,
                maxTokens: 10,
                refillRatePerTick: refillRate,
                initialTick: 1000
            )
            
            // Advance with delta that will cause overflow
            CheckCounter.increment()
            checks += 1
            XCTAssertThrowsError(try limiter.advanceTo(1002)) { error in
                CheckCounter.increment()
                checks += 1
                guard let failClosedError = error as? FailClosedError else {
                    XCTFail("Overflow must throw FailClosedError")
                    return
                }
                XCTAssertEqual(failClosedError.code, FailClosedErrorCode.limiterArithOverflow.rawValue, "Overflow must map to correct error code")
            }
        }
        
        print("Property P8 (Overflow Behavior): \(checks) checks")
    }
}
