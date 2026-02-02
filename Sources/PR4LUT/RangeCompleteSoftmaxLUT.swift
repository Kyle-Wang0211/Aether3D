//
// RangeCompleteSoftmaxLUT.swift
// PR4LUT
//
// PR4 V10 - Pillar 21: Range-complete softmax LUT [-32, 0] in Q16.16
//

import Foundation
import PR4Math

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Range-complete softmax LUT
///
/// V8 RULE: LUT covers exp(x) for x in [-32, 0] in Q16.16 format.
/// This is sufficient for softmax computation (after subtracting max).
public enum RangeCompleteSoftmaxLUT {
    
    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Constants
    // ═══════════════════════════════════════════════════════════════════════
    
    /// LUT size: 512 entries (covers -32.0 to 0.0 in steps of 0.0625)
    public static let lutSize: Int = 512
    
    /// Minimum input value (in Q16.16)
    public static let minInput: Int64 = -32 * 65536  // -32.0
    
    /// Maximum input value (in Q16.16)
    public static let maxInput: Int64 = 0
    
    /// Step size (in Q16.16)
    public static let stepSize: Int64 = 65536 / 16  // 0.0625
    
    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - LUT Storage
    // ═══════════════════════════════════════════════════════════════════════
    
    /// Pre-computed LUT (loaded from binary file)
    private static var cachedLUT: [Int64]?
    
    /// Load LUT from bundle or generate
    public static func loadLUT() -> [Int64] {
        if let cached = cachedLUT {
            return cached
        }
        
        // Try to load from bundle
        if let url = Bundle.main.url(forResource: "exp_lut_512", withExtension: "v2.bin", subdirectory: "Artifacts/LUT") {
            do {
                let lut = try LUTBinaryFormatV2.read(from: url)
                cachedLUT = lut
                return lut
            } catch {
                print("⚠️ Failed to load LUT from bundle: \(error), generating...")
            }
        }
        
        // Generate fallback LUT
        let lut = generateFallbackLUT()
        cachedLUT = lut
        return lut
    }
    
    /// Generate fallback LUT using system math (for development)
    private static func generateFallbackLUT() -> [Int64] {
        var lut = [Int64]()
        lut.reserveCapacity(lutSize)
        
        for i in 0..<lutSize {
            let x = Double(i) * Q16.toDouble(stepSize) + Q16.toDouble(minInput)
            // x is in [-32, 0], so exp(x) is in [exp(-32), 1]
            // exp(-32) ≈ 1.27e-14, so exp(x) * 65536 is in [0, 65536]
            let expValue = Foundation.exp(x)
            // Clamp to [0, 1] range before converting to Q16
            let clampedExp = Swift.max(0.0, Swift.min(expValue, 1.0))
            let q16Value = Q16.fromDouble(clampedExp)
            lut.append(q16Value)
        }
        
        // Ensure exp(0) = 65536 exactly
        if lutSize > 0 {
            let zeroIndex = Int((-minInput) / stepSize)
            if zeroIndex >= 0 && zeroIndex < lutSize {
                lut[zeroIndex] = 65536
            }
        }
        
        return lut
    }
    
    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Lookup
    // ═══════════════════════════════════════════════════════════════════════
    
    /// Lookup exp(x) in Q16.16 format
    ///
    /// - Parameter xQ16: Input in Q16.16 format (must be in [-32*65536, 0])
    /// - Returns: exp(x) in Q16.16 format
    @inline(__always)
    public static func expQ16(_ xQ16: Int64) -> Int64 {
        // Special case: exp(0) = 1.0 = 65536 in Q16
        if xQ16 == 0 {
            return 65536
        }
        
        // Clamp to valid range
        let clamped = Swift.max(minInput, Swift.min(maxInput, xQ16))
        
        // Compute index
        let offset = clamped - minInput
        let index = Int(offset / stepSize)
        
        // Ensure index is valid
        let safeIndex = Swift.max(0, Swift.min(lutSize - 1, index))
        
        // Load LUT
        let lut = loadLUT()
        
        // Linear interpolation for better precision
        if index < lutSize - 1 && clamped < 0 {
            let lower = lut[safeIndex]
            let upper = lut[Swift.min(safeIndex + 1, lutSize - 1)]
            
            // Interpolation factor
            let remainder = offset % stepSize
            let factor = Double(remainder) / Double(stepSize)
            
            let interpolated = Double(lower) * (1.0 - factor) + Double(upper) * factor
            return Q16.fromDouble(interpolated)
        }
        
        return lut[safeIndex]
    }
    
    /// Verify LUT integrity
    public static func verifyIntegrity() -> Bool {
        let lut = loadLUT()
        
        // Check size
        guard lut.count == lutSize else {
            return false
        }
        
        // Check all values are non-negative
        guard lut.allSatisfy({ $0 >= 0 }) else {
            return false
        }
        
        // Check exp(0) == 65536
        let expZero = expQ16(0)
        guard expZero == 65536 || abs(expZero - 65536) <= 1 else {
            return false
        }
        
        return true
    }
}
