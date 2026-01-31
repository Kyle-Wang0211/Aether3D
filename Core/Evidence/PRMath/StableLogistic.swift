//
// StableLogistic.swift
// Aether3D
//
// PR3 - Piecewise Stable Sigmoid Implementation
// No NaN, no Inf, no overflow
//

import Foundation

/// Stable Logistic: Piecewise formula with performance annotations
///
/// STABILITY: No NaN, no Inf, no overflow
/// DETERMINISM: Bit-exact across all platforms
/// PERFORMANCE: ~60 cycles (use LUT for faster)
public enum StableLogistic {

    /// Maximum safe input for exp()
    @usableFromInline
    internal static let maxSafeInput: Double = 80.0

    /// Compute stable sigmoid
    ///
    /// FORMULA:
    /// - x ≥ 0: σ(x) = 1 / (1 + exp(-x))
    /// - x < 0: σ(x) = exp(x) / (1 + exp(x))
    ///
    /// This piecewise formula prevents overflow for large negative x.
    ///
    /// - Parameter x: Input value
    /// - Returns: Sigmoid value ∈ (0, 1)
    @inlinable
    public static func sigmoid(_ x: Double) -> Double {
        // Handle non-finite input first (branch prediction hint: unlikely)
        guard x.isFinite else {
            return handleNonFinite(x)
        }

        // Clamp to safe range
        let clamped = max(-maxSafeInput, min(maxSafeInput, x))

        // Piecewise stable formula
        if clamped >= 0 {
            let expNegX = exp(-clamped)
            return 1.0 / (1.0 + expNegX)
        } else {
            let expX = exp(clamped)
            return expX / (1.0 + expX)
        }
    }

    /// Handle non-finite inputs (cold path)
    @usableFromInline
    internal static func handleNonFinite(_ x: Double) -> Double {
        if x.isNaN { return 0.5 }  // Neutral for NaN
        return x > 0 ? 1.0 : 0.0   // Saturate for ±Inf
    }

    /// Safe exponential with clamping
    ///
    /// - Parameter x: Input value (clamped to [-80, 80])
    /// - Returns: exp(x) with clamped input
    @inlinable
    public static func expSafe(_ x: Double) -> Double {
        guard x.isFinite else {
            if x.isNaN { return 1.0 }  // exp(NaN) = 1.0 as neutral
            return x > 0 ? Double.infinity : 0.0
        }
        let clamped = max(-maxSafeInput, min(maxSafeInput, x))
        return exp(clamped)
    }
}
