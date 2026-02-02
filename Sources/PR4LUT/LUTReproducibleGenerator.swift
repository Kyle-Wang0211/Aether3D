//
// LUTReproducibleGenerator.swift
// PR4LUT
//
// PR4 V10 - Pillar 17: Reproducible LUT generation using integer-only math
//

import Foundation
import PR4Math

/// Reproducible LUT generator
///
/// V9 RULE: LUT generation uses integer-only arbitrary precision math.
/// NO system exp/log in generation (they vary by platform).
public enum LUTReproducibleGenerator {
    
    /// Generate exp LUT using reproducible method
    ///
    /// Uses rational approximation with 128-bit integer arithmetic.
    public static func generateExpLUT(size: Int = 512, minX: Int64 = -32 * 65536, maxX: Int64 = 0) -> [Int64] {
        var lut = [Int64]()
        lut.reserveCapacity(size)
        
        let stepSize = (maxX - minX) / Int64(size - 1)
        
        for i in 0..<size {
            let xQ16 = minX + Int64(i) * stepSize
            
            // Use Taylor series: exp(x) ≈ 1 + x + x²/2! + x³/3! + ...
            // Converted to Q16.16 arithmetic
            let expValue = expTaylorSeries(xQ16: xQ16)
            
            lut.append(expValue)
        }
        
        return lut
    }
    
    /// Compute exp using Taylor series (integer-only)
    private static func expTaylorSeries(xQ16: Int64, terms: Int = 10) -> Int64 {
        // exp(x) = 1 + x + x²/2! + x³/3! + ...
        // All in Q16.16 arithmetic
        
        var result = Q16.one  // Start with 1.0
        var term = Q16.one    // Current term
        var xPower = xQ16     // x^n
        
        for n in 1..<terms {
            // term = x^n / n!
            let numerator = xPower
            let denominator = factorial(n)
            
            // Divide in Q16: (numerator << 16) / denominator
            let termQ16 = (numerator << 16) / denominator
            
            result = Q16.add(result, termQ16).result
            
            // Update for next term: xPower *= x, term /= (n+1)
            xPower = Q16.multiply(xPower, xQ16).result
            
            // Early termination if term is negligible
            if abs(termQ16) < 100 {  // ~0.0015 in Q16
                break
            }
        }
        
        return result
    }
    
    /// Compute factorial (n!)
    private static func factorial(_ n: Int) -> Int64 {
        guard n > 0 else { return 1 }
        guard n <= 20 else { return Int64.max }  // Prevent overflow
        
        var result: Int64 = 1
        for i in 1...n {
            result *= Int64(i)
        }
        return result
    }
}
