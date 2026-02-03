//
// SoftmaxMassConservationStrictTests.swift
// PR4SoftmaxTests
//
// PR4 V10 - STRICT verification that softmax sum is EXACTLY 65536
//

import XCTest
@testable import PR4Softmax
@testable import PR4Math

final class SoftmaxMassConservationStrictTests: XCTestCase {
    
    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - F1: Sum Must Be EXACTLY 65536
    // ═══════════════════════════════════════════════════════════════════════
    
    /// Test 10000 random inputs - sum MUST be exactly 65536 for ALL
    func testMassConservation10000RandomInputs() {
        var failures: [(seed: Int, sum: Int64, weights: [Int64])] = []
        
        for seed in 0..<10000 {
            var rng = SplitMix64(seed: UInt64(seed))
            
            // Random count 2-100
            let count = Int.random(in: 2...100, using: &rng)
            
            // Random logits in valid range [-32, +32] in Q16
            let logits = (0..<count).map { _ in
                Int64.random(in: -32 * 65536...32 * 65536, using: &rng)
            }
            
            let weights = SoftmaxExactSumV2.softmaxExactSum(logitsQ16: logits)
            let sum = weights.reduce(0, +)
            
            if sum != 65536 {
                failures.append((seed: seed, sum: sum, weights: weights))
                
                // Stop early if too many failures
                if failures.count >= 10 {
                    break
                }
            }
        }
        
        if !failures.isEmpty {
            for f in failures {
                print("FAILURE seed=\(f.seed): sum=\(f.sum), delta=\(f.sum - 65536)")
            }
        }
        
        XCTAssertTrue(failures.isEmpty,
            "Mass conservation failed for \(failures.count) inputs. First: seed=\(failures.first?.seed ?? -1)")
    }
    
    /// Test extreme spread (historical failure F1a)
    func testExtremeSpreadMassConservation() {
        let extremeCases: [[Int64]] = [
            // Maximum spread
            [32 * 65536, -32 * 65536],
            
            // Large spread with middle
            [30 * 65536, 0, -30 * 65536],
            
            // One dominant, many tiny
            [20 * 65536] + Array(repeating: Int64(-20 * 65536), count: 99),
            
            // All very negative (potential underflow)
            Array(repeating: Int64(-30 * 65536), count: 50),
            
            // Alternating extreme
            (0..<100).map { i in Int64((i % 2 == 0 ? 20 : -20) * 65536) },
        ]
        
        for (i, logits) in extremeCases.enumerated() {
            let weights = SoftmaxExactSumV2.softmaxExactSum(logitsQ16: logits)
            let sum = weights.reduce(0, +)
            
            XCTAssertEqual(sum, 65536,
                "Extreme case \(i) failed: sum=\(sum), delta=\(sum - 65536)")
            
            // All weights must be non-negative
            XCTAssertTrue(weights.allSatisfy { $0 >= 0 },
                "Extreme case \(i) has negative weight")
        }
    }
    
    /// Test near-zero spread (all equal)
    func testUniformDistributionMassConservation() {
        for count in 1...256 {
            let logits = Array(repeating: Int64(0), count: count)
            let weights = SoftmaxExactSumV2.softmaxExactSum(logitsQ16: logits)
            let sum = weights.reduce(0, +)
            
            XCTAssertEqual(sum, 65536,
                "Uniform distribution count=\(count) failed: sum=\(sum)")
            
            // Each weight should be approximately 65536 / count
            // Allow wider tolerance for remainder distribution
            // The remainder (up to count-1) is added to one element
            let expectedWeight = 65536 / count
            let maxRemainder = 65536 % count
            for (j, w) in weights.enumerated() {
                // Allow for base weight + full remainder (which goes to one element)
                let tolerance = Int64(maxRemainder)
                XCTAssertTrue(abs(w - Int64(expectedWeight)) <= tolerance,
                    "Uniform weight[\(j)] for count=\(count): expected ~\(expectedWeight)±\(tolerance), got \(w)")
            }
        }
    }
    
    /// Test single element
    func testSingleElementMassConservation() {
        for value in stride(from: -32 * 65536, through: 32 * 65536, by: 65536) {
            let weights = SoftmaxExactSumV2.softmaxExactSum(logitsQ16: [Int64(value)])
            
            XCTAssertEqual(weights.count, 1)
            XCTAssertEqual(weights[0], 65536,
                "Single element \(value) should have weight 65536, got \(weights[0])")
        }
    }
    
    /// Test empty input
    func testEmptyInputMassConservation() {
        let weights = SoftmaxExactSumV2.softmaxExactSum(logitsQ16: [])
        XCTAssertEqual(weights, [], "Empty input should return empty output")
    }
}

// SplitMix64 defined in SoftmaxMassConservationTests.swift
