//
// PRMath.swift
// Aether3D
//
// PR3 - Unified Math Facade
// All mathematical operations in Core/Evidence/ MUST go through PRMath
//
// RULE: Business logic layer can ONLY import PRMath (not PRMathDouble, PRMathFast, etc.)
// FORBIDDEN: Direct use of Foundation.exp, Darwin.exp, pow, tanh, etc.
//
// PERFORMANCE MODES:
// - canonical (default): PRMathDouble, stable sigmoid
// - fast: PRMathFast, LUT-based (shadow/benchmark only)
// - fixed: PRMathFixed, Q32.32 fixed-point (future)
//

import Foundation

/// Unified math facade for Evidence layer
///
/// RULE: All mathematical operations in Core/Evidence/ MUST go through PRMath
/// FORBIDDEN: Direct use of Foundation.exp, Darwin.exp, pow, tanh, etc.
///
/// PERFORMANCE MODES:
/// - canonical (default): PRMathDouble, stable sigmoid
/// - fast: PRMathFast, LUT-based (shadow/benchmark only)
/// - fixed: PRMathFixed, Q32.32 fixed-point (future)
public enum PRMath {

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Core Sigmoid Functions
    // ═══════════════════════════════════════════════════════════════════════

    /// Standard sigmoid: σ(x) = 1 / (1 + e^(-x))
    ///
    /// IMPLEMENTATION:
    /// - Canonical: StableLogistic.sigmoid (piecewise formula)
    /// - Fast: LUTSigmoid.sigmoid (256-entry LUT, shadow only)
    ///
    /// GUARANTEE: No NaN, no Inf, output ∈ (0, 1)
    ///
    /// - Parameter x: Input value
    /// - Parameter context: Tier context (determines implementation)
    /// - Returns: Sigmoid value ∈ (0, 1)
    @inlinable
    public static func sigmoid(_ x: Double, context: TierContext = .forTesting) -> Double {
        switch context.tier {
        case .canonical:
            return PRMathDouble.sigmoid(x)
        case .fast:
            #if PRMATH_FAST
            return PRMathFast.sigmoid(x)
            #else
            // Fallback to Double if Fast not available
            return PRMathDouble.sigmoid(x)
            #endif
        case .fixed:
            #if PRMATH_FIXED
            return PRMathFixed.sigmoid(x)
            #else
            // Fallback to Double if Fixed not available
            return PRMathDouble.sigmoid(x)
            #endif
        }
    }

    /// Sigmoid from threshold with transition width
    ///
    /// FORMULA: sigmoid((value - threshold) / slope)
    /// where slope = transitionWidth / 4.4
    ///
    /// - Parameters:
    ///   - value: Input value
    ///   - threshold: 50% point of sigmoid
    ///   - transitionWidth: Width of transition zone (10% to 90%)
    ///   - context: Tier context
    /// - Returns: Sigmoid value ∈ (0, 1)
    @inlinable
    public static func sigmoid01FromThreshold(
        _ value: Double,
        threshold: Double,
        transitionWidth: Double,
        context: TierContext = .forTesting
    ) -> Double {
        // Compute slope from transition width
        let slope = transitionWidth / 4.4
        let safeSlope = max(slope, 1e-10)  // Avoid division by zero
        let normalized = (value - threshold) / safeSlope
        return sigmoid(normalized, context: context)
    }

    /// Inverted sigmoid (for "lower is better" metrics)
    ///
    /// FORMULA: sigmoid((threshold - value) / slope)
    ///
    /// - Parameters:
    ///   - value: Input value (lower is better)
    ///   - threshold: 50% point of sigmoid
    ///   - transitionWidth: Width of transition zone
    ///   - context: Tier context
    /// - Returns: Sigmoid value ∈ (0, 1)
    @inlinable
    public static func sigmoidInverted01FromThreshold(
        _ value: Double,
        threshold: Double,
        transitionWidth: Double,
        context: TierContext = .forTesting
    ) -> Double {
        let slope = transitionWidth / 4.4
        let safeSlope = max(slope, 1e-10)
        let normalized = (threshold - value) / safeSlope
        return sigmoid(normalized, context: context)
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Safe Math Functions
    // ═══════════════════════════════════════════════════════════════════════

    /// Safe exponential: clamps input to prevent overflow
    /// INPUT RANGE: clamped to [-80, 80]
    ///
    /// - Parameter x: Input value
    /// - Returns: exp(x) with clamped input
    @inlinable
    public static func expSafe(_ x: Double) -> Double {
        return PRMathDouble.expSafe(x)
    }

    /// Safe atan2: handles NaN/Inf inputs
    ///
    /// NOTE: This is NOT used in canonical path (zero-trig policy)
    /// Only available for shadow verification
    ///
    /// - Parameters:
    ///   - y: Y component
    ///   - x: X component
    /// - Returns: atan2(y, x) with NaN/Inf handling
    @inlinable
    public static func atan2Safe(_ y: Double, _ x: Double) -> Double {
        // Handle degenerate cases
        guard y.isFinite && x.isFinite else {
            // Return 0 for any non-finite input (deterministic fallback)
            return 0.0
        }
        guard !(y == 0 && x == 0) else {
            // atan2(0, 0) is undefined, return 0 (deterministic)
            return 0.0
        }
        return atan2(y, x)
    }

    /// Safe asin: clamps input to [-1, 1]
    ///
    /// NOTE: This is NOT used in canonical path (zero-trig policy)
    /// Only available for shadow verification
    ///
    /// - Parameter x: Input value
    /// - Returns: asin(clamped x) with NaN/Inf handling
    @inlinable
    public static func asinSafe(_ x: Double) -> Double {
        guard x.isFinite else { return 0.0 }
        let clamped = max(-1.0, min(1.0, x))
        return asin(clamped)
    }

    /// Safe sqrt: returns 0 for negative input
    ///
    /// - Parameter x: Input value
    /// - Returns: sqrt(x) or 0 if x < 0 or non-finite
    @inlinable
    public static func sqrtSafe(_ x: Double) -> Double {
        guard x.isFinite && x >= 0 else { return 0.0 }
        return sqrt(x)
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Utility Functions
    // ═══════════════════════════════════════════════════════════════════════

    /// Clamp to [0, 1]
    ///
    /// - Parameter x: Input value
    /// - Returns: Clamped value ∈ [0, 1]
    @inlinable
    public static func clamp01(_ x: Double) -> Double {
        return max(0.0, min(1.0, x))
    }

    /// Clamp to arbitrary range
    ///
    /// - Parameters:
    ///   - x: Input value
    ///   - lo: Lower bound
    ///   - hi: Upper bound
    /// - Returns: Clamped value ∈ [lo, hi]
    @inlinable
    public static func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
        return max(lo, min(hi, x))
    }

    /// Check if value is usable (finite and not NaN)
    ///
    /// - Parameter x: Input value
    /// - Returns: true if value is finite
    @inlinable
    public static func isUsable(_ x: Double) -> Bool {
        return x.isFinite
    }
}
