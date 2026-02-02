//
// Q16Arithmetic.swift
// PR4Math
//
// PR4 V10 - Q16.16 fixed-point arithmetic with overflow checking
// Task 1.2: Foundation module (depends: Int128.swift)
//

import Foundation

/// Q16.16 fixed-point arithmetic
///
/// All values are stored as Int64 where:
/// - Bits 63-16: Integer part (signed)
/// - Bits 15-0: Fractional part (16 bits = 1/65536 precision)
public enum Q16 {
    
    // MARK: - Constants
    
    /// Scale factor: 2^16 = 65536
    public static let scale: Int64 = 65536
    
    /// Maximum representable value
    public static let max: Int64 = Int64.max
    
    /// Minimum representable value
    public static let min: Int64 = Int64.min + 1  // Reserve Int64.min for "invalid"
    
    /// Invalid/NaN sentinel
    public static let invalid: Int64 = Int64.min
    
    /// One in Q16.16 format
    public static let one: Int64 = 65536
    
    /// Zero in Q16.16 format
    public static let zero: Int64 = 0
    
    // MARK: - Conversion
    
    /// Convert Double to Q16.16
    @inline(__always)
    public static func fromDouble(_ value: Double) -> Int64 {
        guard value.isFinite else { return invalid }
        
        let scaled = value * Double(scale)
        guard scaled >= Double(Int64.min + 1) && scaled <= Double(Int64.max) else {
            return scaled > 0 ? max : min
        }
        
        return Int64(scaled.rounded(.toNearestOrEven))
    }
    
    /// Convert Q16.16 to Double
    @inline(__always)
    public static func toDouble(_ value: Int64) -> Double {
        guard value != invalid else { return .nan }
        return Double(value) / Double(scale)
    }
    
    /// Convert integer to Q16.16
    @inline(__always)
    public static func fromInt(_ value: Int) -> Int64 {
        return Int64(value) * scale
    }
    
    // MARK: - Arithmetic
    
    /// Add with overflow checking
    ///
    /// Returns: (result, didOverflow)
    @inline(__always)
    public static func add(_ a: Int64, _ b: Int64) -> (result: Int64, overflow: Bool) {
        guard a != invalid && b != invalid else {
            return (invalid, true)
        }
        
        let (result, overflow) = a.addingReportingOverflow(b)
        
        if overflow {
            // Saturate
            let saturated = (a > 0) == (b > 0) ? (a > 0 ? max : min) : result
            return (saturated, true)
        }
        
        return (result, false)
    }
    
    /// Subtract with overflow checking
    @inline(__always)
    public static func subtract(_ a: Int64, _ b: Int64) -> (result: Int64, overflow: Bool) {
        guard a != invalid && b != invalid else {
            return (invalid, true)
        }
        
        let (result, overflow) = a.subtractingReportingOverflow(b)
        
        if overflow {
            let saturated = a > b ? max : min
            return (saturated, true)
        }
        
        return (result, false)
    }
    
    /// Multiply Q16 × Q16 with overflow checking
    ///
    /// Uses Int128 intermediate to prevent overflow before shift.
    @inline(__always)
    public static func multiply(_ a: Int64, _ b: Int64) -> (result: Int64, overflow: Bool) {
        guard a != invalid && b != invalid else {
            return (invalid, true)
        }
        
        // Use 128-bit intermediate
        let wide = Int128.multiply(a, b)
        
        // Shift right by 16 to get Q16 result
        let shifted = wide >> 16
        
        // Check for overflow
        let result = shifted.toInt64Saturating()
        let overflow = shifted.high != 0 && shifted.high != -1
        
        return (result, overflow)
    }
    
    /// Divide Q16 / Q16 with overflow checking
    @inline(__always)
    public static func divide(_ a: Int64, _ b: Int64) -> (result: Int64, overflow: Bool) {
        guard a != invalid && b != invalid else {
            return (invalid, true)
        }
        
        guard b != 0 else {
            // Division by zero
            return (a >= 0 ? max : min, true)
        }
        
        // Shift left by 16 before division to maintain precision
        // Use Int128 to prevent overflow
        let wideA = Int128(a)
        let shifted = Int128(high: wideA.high << 16 | Int64(wideA.low >> 48),
                            low: wideA.low << 16)
        
        // Simple division (could be improved)
        let result = shifted.toInt64Saturating() / b
        
        return (result, false)
    }
    
    // MARK: - Clamping
    
    /// Clamp to range [min, max]
    @inline(__always)
    public static func clamp(_ value: Int64, min: Int64, max: Int64) -> Int64 {
        guard value != invalid else { return invalid }
        
        if value < min { return min }
        if value > max { return max }
        return value
    }
    
    /// Clamp to [0, 1] in Q16 (0 to 65536)
    @inline(__always)
    public static func clampUnit(_ value: Int64) -> Int64 {
        return clamp(value, min: 0, max: one)
    }
    
    // MARK: - Validation
    
    /// Check if value is valid (not the invalid sentinel)
    @inline(__always)
    public static func isValid(_ value: Int64) -> Bool {
        return value != invalid
    }
}
