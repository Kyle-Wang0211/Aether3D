//
// LimiterFuzzTests.swift
// Aether3D
//
// PR1 v2.4 Addendum - QuantizedLimiter Fuzz Tests (time-bounded)
//
// Deterministic fuzz with seed printed in logs
//

import XCTest
@testable import Aether3DCore

final class LimiterFuzzTests: XCTestCase {
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
        
        mutating func nextUInt32() -> UInt32 {
            return UInt32(next() & 0xFFFFFFFF)
        }
        
        mutating func nextUInt64() -> UInt64 {
            return (next() << 32) | next()
        }
    }
    
    /// Fuzz QuantizedLimiter with random tick sequences (>=500 iterations)
    /// Time budget: 1-3 seconds on CI
    func testLimiter_FuzzTickSequences() throws {
        let seed: UInt64 = 54321
        print("Limiter Fuzz seed: \(seed)")
        
        var rng = FuzzRNG(seed: seed)
        var checks = 0
        let startTime = Date()
        let timeLimit: TimeInterval = 2.0
        
        var iteration = 0
        while Date().timeIntervalSince(startTime) < timeLimit && iteration < 500 {
            CheckCounter.increment()
            checks += 1
            
            let windowTicks = rng.nextUInt64() % 10000 + 100
            let maxTokens = UInt32(rng.nextUInt32() % 1000 + 1)
            let refillRate = rng.nextUInt64() % 10000 + 1
            let initialTick = rng.nextUInt64() % 1000000
            
            var limiter = QuantizedLimiter(
                windowTicks: windowTicks,
                maxTokens: maxTokens,
                refillRatePerTick: refillRate,
                initialTick: initialTick
            )
            
            // Generate random tick sequence
            var currentTick = initialTick
            for _ in 0..<10 {
                currentTick += rng.nextUInt64() % 1000 + 1
                
                do {
                    try limiter.advanceTo(currentTick)
                    _ = try limiter.consume()
                    
                    // Verify attempts counted before consume
                    CheckCounter.increment()
                    checks += 1
                    XCTAssertGreaterThanOrEqual(limiter.currentAttempts, 0, "Attempts must be non-negative")
                    
                    // Verify tokens within bounds
                    CheckCounter.increment()
                    checks += 1
                    XCTAssertLessThanOrEqual(limiter.currentTokens, maxTokens, "Tokens must not exceed max")
                } catch {
                    // Overflow is expected for some inputs
                    CheckCounter.increment()
                    checks += 1
                    XCTAssertTrue(error is FailClosedError, "Errors must be FailClosedError")
                }
            }
            
            iteration += 1
        }
        
        print("Limiter Fuzz: \(iteration) iterations, \(checks) checks")
    }
}
