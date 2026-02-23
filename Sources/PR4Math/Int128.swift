// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// Int128.swift
// PR4Math
//
// PR4 V10 - 128-bit integer arithmetic for overflow-safe computation
// Task 1.1: Foundation module with no dependencies
//

import Foundation

/// 128-bit signed integer
///
/// Used for intermediate results in Q16.16 multiplication
/// to prevent overflow before right-shift.
public struct Int128: Comparable, Equatable {
    
    // MARK: - Storage
    
    /// High 64 bits (signed)
    public let high: Int64
    
    /// Low 64 bits (unsigned)
    public let low: UInt64
    
    // MARK: - Initialization
    
    public init(high: Int64, low: UInt64) {
        self.high = high
        self.low = low
    }
    
    public init(_ value: Int64) {
        if value >= 0 {
            self.high = 0
            self.low = UInt64(value)
        } else {
            self.high = -1
            self.low = UInt64(bitPattern: value)
        }
    }
    
    public init(_ value: UInt64) {
        self.high = 0
        self.low = value
    }
    
    // MARK: - Arithmetic
    
    /// Multiply two Int64 values, returning Int128
    public static func multiply(_ a: Int64, _ b: Int64) -> Int128 {
        // Split into 32-bit parts for safe multiplication
        let aSign = a < 0
        let bSign = b < 0
        let resultSign = aSign != bSign
        
        let aAbs = aSign ? UInt64(bitPattern: -a) : UInt64(a)
        let bAbs = bSign ? UInt64(bitPattern: -b) : UInt64(b)
        
        // Multiply unsigned
        let result = multiplyUnsigned(aAbs, bAbs)
        
        // Apply sign
        if resultSign {
            return result.negated()
        }
        return result
    }
    
    /// Unsigned multiplication
    private static func multiplyUnsigned(_ a: UInt64, _ b: UInt64) -> Int128 {
        let aLo = a & 0xFFFFFFFF
        let aHi = a >> 32
        let bLo = b & 0xFFFFFFFF
        let bHi = b >> 32
        
        let ll = aLo * bLo
        let lh = aLo * bHi
        let hl = aHi * bLo
        let hh = aHi * bHi
        
        let mid = lh + hl + (ll >> 32)
        let low = (ll & 0xFFFFFFFF) | ((mid & 0xFFFFFFFF) << 32)
        let high = hh + (mid >> 32) + (lh > UInt64.max - hl ? 1 << 32 : 0)
        
        return Int128(high: Int64(bitPattern: high), low: low)
    }
    
    /// Negate
    public func negated() -> Int128 {
        let invertedLow = ~low
        let (newLow, overflow) = invertedLow.addingReportingOverflow(1)
        let newHigh = ~high + (overflow ? 1 : 0)
        return Int128(high: newHigh, low: newLow)
    }
    
    /// Right shift
    public static func >> (lhs: Int128, rhs: Int) -> Int128 {
        guard rhs > 0 else { return lhs }
        guard rhs < 128 else {
            return lhs.high < 0 ? Int128(high: -1, low: UInt64.max) : Int128(high: 0, low: 0)
        }
        
        if rhs < 64 {
            let newLow = (lhs.low >> rhs) | (UInt64(bitPattern: lhs.high) << (64 - rhs))
            let newHigh = lhs.high >> rhs
            return Int128(high: newHigh, low: newLow)
        } else {
            let newLow = UInt64(bitPattern: lhs.high >> (rhs - 64))
            let newHigh: Int64 = lhs.high < 0 ? -1 : 0
            return Int128(high: newHigh, low: newLow)
        }
    }
    
    /// Convert to Int64 (with saturation)
    public func toInt64Saturating() -> Int64 {
        if high > 0 || (high == 0 && low > UInt64(Int64.max)) {
            return Int64.max
        }
        if high < -1 || (high == -1 && low < UInt64(bitPattern: Int64.min)) {
            return Int64.min
        }
        return Int64(bitPattern: low)
    }
    
    // MARK: - Comparable
    
    public static func < (lhs: Int128, rhs: Int128) -> Bool {
        if lhs.high != rhs.high {
            return lhs.high < rhs.high
        }
        return lhs.low < rhs.low
    }
}
