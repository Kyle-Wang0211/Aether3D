// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// SoftmaxExactSumV2.swift
// PR4Softmax
//
// PR4 V10 - Pillars 5, 13, 28: Softmax with exact sum = 65536 and step invariants
//

import Foundation
import PR4Math
import PR4LUT
import PR4Overflow
import PR4PathTrace

/// Softmax with exact sum guarantee and step-by-step invariants
public enum SoftmaxExactSumV2 {
    
    public static let targetSum: Int64 = 65536
    
    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Step Results
    // ═══════════════════════════════════════════════════════════════════════
    
    public struct Step1Result {
        public let maxLogit: Int64
        public let maxIndex: Int
    }
    
    public struct Step2Result {
        public let expValues: [Int64]
    }
    
    public struct Step3Result {
        public let sumExp: Int64
    }
    
    public struct Step4Result {
        public let weights: [Int64]
        public let usedUniformFallback: Bool
    }
    
    public struct Step5Result {
        public let actualSum: Int64
        public let remainder: Int64
    }
    
    public struct Step6Result {
        public let finalWeights: [Int64]
    }
    
    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Step Implementations
    // ═══════════════════════════════════════════════════════════════════════
    
    public static func step1_findMax(_ logits: [Int64]) -> Step1Result {
        precondition(!logits.isEmpty, "Logits must not be empty")
        
        var maxLogit = logits[0]
        var maxIndex = 0
        
        for i in 1..<logits.count {
            if logits[i] > maxLogit {
                maxLogit = logits[i]
                maxIndex = i
            }
        }
        
        return Step1Result(maxLogit: maxLogit, maxIndex: maxIndex)
    }
    
    public static func step2_computeExp(logits: [Int64], step1: Step1Result) -> Step2Result {
        var expValues = [Int64](repeating: 0, count: logits.count)
        
        for i in 0..<logits.count {
            let diff = logits[i] - step1.maxLogit
            expValues[i] = RangeCompleteSoftmaxLUT.expQ16(diff)
            if expValues[i] < 0 { expValues[i] = 0 }
        }
        
        #if DEBUG
        assert(expValues.allSatisfy { $0 >= 0 }, "Step 2 postcondition: all exp >= 0")
        // exp(0) should be 65536, but allow small rounding error from LUT interpolation
        let expZero = expValues[step1.maxIndex]
        assert(expZero >= 65535 && expZero <= 65537, "Step 2 postcondition: exp(0) ≈ 65536, got \(expZero)")
        #endif
        
        return Step2Result(expValues: expValues)
    }
    
    public static func step3_kahanSum(step2: Step2Result) -> Step3Result {
        var sum: Int64 = 0
        var compensation: Int64 = 0
        
        for exp in step2.expValues {
            let y = exp - compensation
            let t = sum &+ y
            compensation = (t &- sum) &- y
            sum = t
        }
        
        #if DEBUG
        assert(sum >= 0, "Step 3 postcondition: sum >= 0")
        #endif
        
        return Step3Result(sumExp: sum)
    }
    
    public static func step4_normalize(step2: Step2Result, step3: Step3Result, count: Int) -> Step4Result {
        if step3.sumExp <= 0 {
            let uniform = targetSum / Int64(count)
            var weights = [Int64](repeating: uniform, count: count)
            weights[0] += targetSum - uniform * Int64(count)
            return Step4Result(weights: weights, usedUniformFallback: true)
        }
        
        var weights = [Int64](repeating: 0, count: count)
        for i in 0..<count {
            let raw = (step2.expValues[i] << 16) / step3.sumExp
            weights[i] = Swift.max(0, raw)
        }
        
        #if DEBUG
        assert(weights.allSatisfy { $0 >= 0 }, "Step 4 postcondition: all weights >= 0")
        #endif
        
        return Step4Result(weights: weights, usedUniformFallback: false)
    }
    
    public static func step5_computeSum(step4: Step4Result) -> Step5Result {
        let actualSum = step4.weights.reduce(0, +)
        return Step5Result(actualSum: actualSum, remainder: targetSum - actualSum)
    }
    
    public static func step6_distributeRemainder(step4: Step4Result, step5: Step5Result) -> Step6Result {
        var weights = step4.weights
        
        if step5.remainder != 0 {
            var maxWeight = weights[0]
            var maxIndex = 0
            
            for i in 1..<weights.count {
                if weights[i] > maxWeight {
                    maxWeight = weights[i]
                    maxIndex = i
                }
            }
            
            weights[maxIndex] += step5.remainder
        }
        
        #if DEBUG
        let finalSum = weights.reduce(0, +)
        assert(finalSum == targetSum, "Step 6 postcondition: sum == 65536, got \(finalSum)")
        assert(weights.allSatisfy { $0 >= 0 }, "Step 6 postcondition: all weights >= 0")
        #endif
        
        return Step6Result(finalWeights: weights)
    }
    
    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Complete Algorithm
    // ═══════════════════════════════════════════════════════════════════════
    
    public static func softmaxExactSum(
        logitsQ16: [Int64],
        trace: PathDeterminismTraceV2? = nil
    ) -> [Int64] {
        guard !logitsQ16.isEmpty else { return [] }
        guard logitsQ16.count > 1 else { return [targetSum] }
        
        let step1 = step1_findMax(logitsQ16)
        let step2 = step2_computeExp(logits: logitsQ16, step1: step1)
        let step3 = step3_kahanSum(step2: step2)
        let step4 = step4_normalize(step2: step2, step3: step3, count: logitsQ16.count)
        
        if step4.usedUniformFallback {
            trace?.record(.softmaxUniform)
        }
        
        let step5 = step5_computeSum(step4: step4)
        let step6 = step6_distributeRemainder(step4: step4, step5: step5)
        
        if step5.remainder != 0 {
            trace?.record(.softmaxRemainderDistributed)
        }
        
        trace?.record(.softmaxNormal)
        
        return step6.finalWeights
    }
}
