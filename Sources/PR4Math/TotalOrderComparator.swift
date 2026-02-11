// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// TotalOrderComparator.swift
// PR4Math
//
// PR4 V10 - Pillars 9 & 19: IEEE 754 totalOrder for deterministic NaN/Inf/Zero handling
//

import Foundation

/// Total order comparator for deterministic floating-point comparison
///
/// V10 RULE: All NaN/Inf/-0 handling MUST go through this comparator.
/// No ad-hoc .isNaN checks allowed.
public enum TotalOrderComparator {
    
    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Sanitization (SSOT for special values)
    // ═══════════════════════════════════════════════════════════════════════
    
    /// Sanitize special values
    ///
    /// V10 RULE: This is the ONLY function for handling NaN/Inf/-0
    @inline(__always)
    public static func sanitize(_ value: Double) -> (sanitized: Double, wasSpecial: Bool) {
        if value.isNaN {
            return (0.0, true)  // NaN → 0.0 (neutral)
        }
        if value == .infinity {
            return (Double.greatestFiniteMagnitude, true)
        }
        if value == -.infinity {
            return (-Double.greatestFiniteMagnitude, true)
        }
        if value == 0 && value.sign == .minus {
            return (0.0, true)  // -0 → +0 (normalize)
        }
        return (value, false)
    }
    
    /// Sanitize Int64 Q16 value
    @inline(__always)
    public static func sanitizeQ16(_ value: Int64) -> (sanitized: Int64, wasSpecial: Bool) {
        if value == Int64.min {
            return (0, true)  // Int64.min is our "invalid" sentinel
        }
        return (value, false)
    }
    
    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Total Order Comparison
    // ═══════════════════════════════════════════════════════════════════════
    
    /// Compare using IEEE 754 totalOrder
    ///
    /// Order: -NaN < -Inf < negatives < -0 < +0 < positives < +Inf < +NaN
    public static func totalOrder(_ a: Double, _ b: Double) -> Int {
        // Get bit patterns
        let aBits = a.bitPattern
        let bBits = b.bitPattern
        
        // Handle sign
        let aSign = (aBits >> 63) != 0
        let bSign = (bBits >> 63) != 0
        
        if aSign != bSign {
            return aSign ? -1 : 1  // Negative < Positive
        }
        
        // Same sign: compare magnitude
        // For negatives: larger magnitude = smaller value
        if aSign {
            return aBits > bBits ? -1 : (aBits < bBits ? 1 : 0)
        } else {
            return aBits < bBits ? -1 : (aBits > bBits ? 1 : 0)
        }
    }
    
    /// Deterministic minimum
    @inline(__always)
    public static func min(_ a: Double, _ b: Double) -> Double {
        return totalOrder(a, b) <= 0 ? a : b
    }
    
    /// Deterministic maximum
    @inline(__always)
    public static func max(_ a: Double, _ b: Double) -> Double {
        return totalOrder(a, b) >= 0 ? a : b
    }
    
    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Sanitization Logger
    // ═══════════════════════════════════════════════════════════════════════
    
    /// Track sanitization events for digest
    public final class SanitizationTracker {
        public private(set) var nanCount: Int = 0
        public private(set) var infCount: Int = 0
        public private(set) var negZeroCount: Int = 0
        
        public func record(_ type: SanitizationType) {
            switch type {
            case .nan: nanCount += 1
            case .infinity: infCount += 1
            case .negativeZero: negZeroCount += 1
            }
        }
        
        public var totalCount: Int { nanCount + infCount + negZeroCount }
        
        public func reset() {
            nanCount = 0
            infCount = 0
            negZeroCount = 0
        }
    }
    
    public enum SanitizationType {
        case nan
        case infinity
        case negativeZero
    }
}
