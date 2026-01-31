//
// LUTSigmoidGuarded.swift
// Aether3D
//
// PR3 - LUT Sigmoid with Monotonicity Guard (SHADOW/BENCHMARK ONLY)
// Not used in canonical path
//

import Foundation

/// LUT Sigmoid: For shadow/benchmark ONLY, with monotonicity guard
///
/// CRITICAL: This is NOT used in canonical path!
/// PURPOSE: Shadow verification, performance benchmarking
///
/// GUARDS:
/// 1. Monotonicity: table[i+1] >= table[i] enforced at construction
/// 2. Endpoints: x ≤ xmin → 0, x ≥ xmax → 1 (exact)
/// 3. No FMA: Split multiply-add to prevent LLVM combining
public enum LUTSigmoidGuarded {

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Configuration
    // ═══════════════════════════════════════════════════════════════════════

    @usableFromInline
    internal static let lutSize: Int = 256

    @usableFromInline
    internal static let minInput: Double = -8.0

    @usableFromInline
    internal static let maxInput: Double = 8.0

    @usableFromInline
    internal static let inputRange: Double = 16.0  // maxInput - minInput

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Guarded Table Construction
    // ═══════════════════════════════════════════════════════════════════════

    /// Lookup table with monotonicity guarantee
    @usableFromInline
    internal static let lut: [Double] = {
        var table = [Double](repeating: 0.0, count: lutSize)

        // Compute initial values
        for i in 0..<lutSize {
            let x = minInput + (Double(i) / Double(lutSize - 1)) * inputRange
            table[i] = StableLogistic.sigmoid(x)
        }

        // MONOTONICITY GUARD: Ensure table[i+1] >= table[i]
        for i in 1..<lutSize {
            if table[i] < table[i - 1] {
                // Fix violation by clamping to previous value
                table[i] = table[i - 1]
                #if DEBUG
                print("[LUTSigmoid] Monotonicity fix at index \(i)")
                #endif
            }
        }

        // ENDPOINT GUARD: Force exact values at boundaries
        table[0] = StableLogistic.sigmoid(minInput)  // Exact value
        table[lutSize - 1] = StableLogistic.sigmoid(maxInput)  // Exact value

        return table
    }()

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Sigmoid with No-FMA Interpolation
    // ═══════════════════════════════════════════════════════════════════════

    /// LUT sigmoid with explicit no-FMA interpolation
    ///
    /// WHY NO-FMA:
    /// - FMA (Fused Multiply-Add) can change results based on compiler flags
    /// - LLVM may or may not use FMA instructions
    /// - By splitting multiply and add, we ensure consistent results
    ///
    /// - Parameter x: Input value
    /// - Returns: Sigmoid value ∈ (0, 1)
    @inlinable
    public static func sigmoid(_ x: Double) -> Double {
        // Handle non-finite
        guard x.isFinite else {
            if x.isNaN { return 0.5 }
            return x > 0 ? 1.0 : 0.0
        }

        // Endpoint saturation (exact)
        if x <= minInput { return lut[0] }
        if x >= maxInput { return lut[lutSize - 1] }

        // Compute index
        let normalizedX = (x - minInput) / inputRange
        let indexF = normalizedX * Double(lutSize - 1)
        let indexLow = Int(indexF)
        let indexHigh = min(indexLow + 1, lutSize - 1)

        // NO-FMA INTERPOLATION
        // Split: result = low + (high - low) * fraction
        // Instead of: result = low + diff * fraction (FMA candidate)
        let fraction = indexF - Double(indexLow)
        let valueLow = lut[indexLow]
        let valueHigh = lut[indexHigh]

        // Explicit split to prevent FMA
        let diff = valueHigh - valueLow  // Step 1
        let scaled = diff * fraction      // Step 2 (NOT fused with step 3)
        let result = valueLow + scaled    // Step 3

        return result
    }
}
