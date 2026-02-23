// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// PR4DigestGenerator.swift
// PR4Tools
//
// PR4 V10 - Tool to generate determinism digest for CI comparison
//

import Foundation
#if canImport(PR4Math)
import PR4Math
#endif
#if canImport(PR4Softmax)
import PR4Softmax
#endif
#if canImport(PR4LUT)
import PR4LUT
#endif

@main
struct PR4DigestGenerator {
    
    static func main() {
        var hasher = FNV1aHasher()
        
        // Test 1: Softmax
        let softmaxInput: [Int64] = [65536, 32768, 0, -32768, -65536]
        let softmaxResult = SoftmaxExactSumV2.softmaxExactSum(logitsQ16: softmaxInput)
        for value in softmaxResult {
            hasher.update(value)
        }
        
        // Test 2: LUT lookups
        let lutTestPoints: [Int64] = [-32*65536, -16*65536, -8*65536, -65536, 0]
        for x in lutTestPoints {
            let exp = RangeCompleteSoftmaxLUT.expQ16(x)
            hasher.update(exp)
        }
        
        // Test 3: Median/MAD
        let medianInput: [Int64] = [9, 3, 7, 1, 5, 8, 2, 6, 4]
        let median = DeterministicMedianMAD.medianQ16(medianInput)
        hasher.update(median)
        
        let mad = DeterministicMedianMAD.madQ16(medianInput)
        hasher.update(mad)
        
        // Test 4: Q16 arithmetic
        let (sum, _) = Q16.add(65536, 32768)
        hasher.update(sum)
        
        let (product, _) = Q16.multiply(65536, 32768)
        hasher.update(product)
        
        // Output final digest
        let digest = hasher.finalize()
        print(String(format: "%016llx", digest))
    }
}

struct FNV1aHasher {
    private var hash: UInt64 = 14695981039346656037
    
    mutating func update(_ value: Int64) {
        let bytes = withUnsafeBytes(of: value.bigEndian) { Array($0) }
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
    }
    
    func finalize() -> UInt64 {
        return hash
    }
}
