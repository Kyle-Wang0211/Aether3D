//
// FloatingPointCanonicalizer.swift
// PR5Capture
//
// PR5 v1.8.1 - PART K: 跨平台确定性
// 浮点数规范化，处理 NaN/Inf/denormal
//

import Foundation

/// Floating-point canonicalizer
///
/// Canonicalizes floating-point values to handle NaN/Inf/denormal consistently.
/// Ensures platform-independent representation.
public actor FloatingPointCanonicalizer {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Canonicalization
    
    /// Canonicalize floating-point value
    ///
    /// Normalizes special values (NaN, Inf, denormal) to consistent representation
    public func canonicalize(_ value: Double) -> Double {
        // Handle NaN
        if value.isNaN {
            return Double.nan  // Canonical NaN
        }
        
        // Handle Infinity
        if value.isInfinite {
            return value > 0 ? Double.infinity : -Double.infinity
        }
        
        // Handle denormal (subnormal) numbers
        if value.isSubnormal {
            // Flush denormals to zero for consistency
            return 0.0
        }
        
        // Handle zero
        if value == 0.0 {
            return 0.0  // Canonical zero
        }
        
        // Normal number - return as-is
        return value
    }
    
    /// Canonicalize array
    public func canonicalize(_ values: [Double]) -> [Double] {
        return values.map { canonicalize($0) }
    }
    
    /// Check if value is canonical
    public func isCanonical(_ value: Double) -> Bool {
        if value.isNaN {
            return true  // NaN is canonical
        }
        if value.isInfinite {
            return true  // Infinity is canonical
        }
        if value.isSubnormal {
            return false  // Denormals are not canonical
        }
        return true
    }
}
