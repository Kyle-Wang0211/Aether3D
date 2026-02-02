//
// DeterministicRounding.swift
// PR4Math
//
// PR4 V10 - Deterministic rounding policy: round half to even (banker's rounding)
// Task 1.3: Foundation module with no dependencies
//

import Foundation

/// Deterministic rounding
///
/// V10 RULE: All rounding uses "round half to even" (banker's rounding)
/// This is deterministic and reduces bias in cumulative operations.
public enum DeterministicRounding {
    
    /// Round to nearest integer, ties to even
    @inline(__always)
    public static func roundToEven(_ value: Double) -> Int64 {
        return Int64(value.rounded(.toNearestOrEven))
    }
    
    /// Round Q16 value to integer part only
    @inline(__always)
    public static func roundQ16ToInt(_ value: Int64) -> Int64 {
        // Add half (32768) and truncate
        // For ties, we need to check if result is odd and adjust
        let half: Int64 = 32768
        let rounded = (value + half) >> 16
        
        // Check for tie (fractional part was exactly 0.5)
        let fractional = value & 0xFFFF
        if fractional == half {
            // Tie: round to even
            if rounded & 1 == 1 {
                return (rounded - 1) << 16
            }
        }
        
        return rounded << 16
    }
    
    /// Divide with deterministic rounding
    ///
    /// For integer division, we want to round to nearest, ties to even.
    @inline(__always)
    public static func divideRounded(_ numerator: Int64, _ denominator: Int64) -> Int64 {
        guard denominator != 0 else { return Q16.invalid }
        
        let quotient = numerator / denominator
        let remainder = numerator % denominator
        
        // Check if we should round up
        let absRemainder = remainder < 0 ? -remainder : remainder
        let absDenominator = denominator < 0 ? -denominator : denominator
        let threshold = absDenominator / 2
        
        if absRemainder > threshold {
            // Round away from zero
            return numerator > 0 ? quotient + 1 : quotient - 1
        } else if absRemainder == threshold {
            // Tie: round to even
            if quotient & 1 == 1 {
                return numerator > 0 ? quotient + 1 : quotient - 1
            }
        }
        
        return quotient
    }
}
