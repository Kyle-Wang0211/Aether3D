//
// SoftmaxMassConservationTests.swift
// PR4SoftmaxTests
//
// PR4 V10 - Verify softmax sum is EXACTLY 65536
//

import XCTest
@testable import PR4Softmax

final class SoftmaxMassConservationTests: XCTestCase {
    
    func testMassConservation1000Random() {
        for seed in 0..<1000 {
            var rng = SplitMix64(seed: UInt64(seed))
            let count = Int.random(in: 2...100, using: &rng)
            let logits = (0..<count).map { _ in
                Int64.random(in: -20*65536...20*65536, using: &rng)
            }
            
            let weights = SoftmaxExactSumV2.softmaxExactSum(logitsQ16: logits)
            
            let sum = weights.reduce(0, +)
            XCTAssertEqual(sum, 65536,
                "Mass conservation failed for seed \(seed): sum = \(sum)")
            
            for (i, w) in weights.enumerated() {
                XCTAssertGreaterThanOrEqual(w, 0,
                    "Negative weight at index \(i) for seed \(seed)")
            }
        }
    }
    
    func testMassConservationExtreme() {
        let extremeCases: [[Int64]] = [
            [-30 * 65536, -30 * 65536, -30 * 65536],
            [20 * 65536, -20 * 65536],
            Array(repeating: Int64(-10 * 65536), count: 100),
            [0] + Array(repeating: Int64(-30 * 65536), count: 99),
        ]
        
        for (i, logits) in extremeCases.enumerated() {
            let weights = SoftmaxExactSumV2.softmaxExactSum(logitsQ16: logits)
            
            let sum = weights.reduce(0, +)
            XCTAssertEqual(sum, 65536,
                "Mass conservation failed for extreme case \(i): sum = \(sum)")
        }
    }
    
    func testStepInvariants() {
        let logits: [Int64] = [65536, 32768, 0, -32768, -65536]
        
        let step1 = SoftmaxExactSumV2.step1_findMax(logits)
        XCTAssertEqual(step1.maxLogit, 65536)
        XCTAssertEqual(step1.maxIndex, 0)
        
        let step2 = SoftmaxExactSumV2.step2_computeExp(logits: logits, step1: step1)
        XCTAssertTrue(step2.expValues.allSatisfy { $0 >= 0 }, "All exp >= 0")
        XCTAssertEqual(step2.expValues[0], 65536, "exp(0) == 65536")
        
        let step3 = SoftmaxExactSumV2.step3_kahanSum(step2: step2)
        XCTAssertGreaterThan(step3.sumExp, 0, "Sum > 0")
        
        let step4 = SoftmaxExactSumV2.step4_normalize(
            step2: step2, step3: step3, count: logits.count)
        XCTAssertTrue(step4.weights.allSatisfy { $0 >= 0 }, "All weights >= 0")
        
        let step5 = SoftmaxExactSumV2.step5_computeSum(step4: step4)
        XCTAssertEqual(step5.actualSum + step5.remainder, 65536)
        
        let step6 = SoftmaxExactSumV2.step6_distributeRemainder(
            step4: step4, step5: step5)
        let finalSum = step6.finalWeights.reduce(0, +)
        XCTAssertEqual(finalSum, 65536, "Final sum MUST be exactly 65536")
    }
}

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    
    init(seed: UInt64) { state = seed }
    
    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }
}
