//
// CircularSpanBitset.swift
// Aether3D
//
// PR3 - Circular Span Calculation on Bitset
// Bitwise rotation + maximum gap algorithm
//

import Foundation

/// Circular Span Calculation on Bitset
///
/// ALGORITHM:
/// The span is 360° minus the largest gap between consecutive filled buckets.
/// For bitset, we find the largest run of consecutive zeros (the gap),
/// then span = bucketCount - maxGap (in buckets).
///
/// TRICK: Use bit rotation to find gaps
/// - Rotate bits so that a filled bucket is at position 0
/// - Find the longest run of leading zeros
/// - This represents the gap that wraps around
///
/// COMPLEXITY: O(24) worst case, but very fast with bit operations
public enum CircularSpanBitset {

    /// Compute circular span in bucket count
    ///
    /// INPUT: theta bucket bitset (24 bits)
    /// OUTPUT: span in buckets [0, 24]
    ///
    /// SPECIAL CASES:
    /// - Empty bitset → span = 0
    /// - Single bucket → span = 0 (need at least 2 for span)
    /// - All buckets filled → span = 24
    ///
    /// - Parameter bitset: Theta bucket bitset
    /// - Returns: Span in buckets [0, 24]
    @inlinable
    public static func computeSpanBuckets(_ bitset: ThetaBucketBitset) -> Int {
        let bits = bitset.rawBits
        let count = bits.nonzeroBitCount

        // Special cases
        if count == 0 { return 0 }
        if count == 1 { return 0 }  // Single point has no span
        if count == 24 { return 24 }  // All filled

        // Find the maximum gap (run of consecutive zeros)
        // We need to handle the circular nature

        // Method: Find all gaps and take the maximum
        var maxGap = 0
        var currentGap = 0
        var inGap = false
        var firstFilledIndex = -1
        var lastFilledIndex = -1

        for i in 0..<24 {
            let isFilled = (bits & (1 << i)) != 0

            if isFilled {
                if firstFilledIndex == -1 {
                    firstFilledIndex = i
                }
                lastFilledIndex = i

                if inGap {
                    maxGap = max(maxGap, currentGap)
                    currentGap = 0
                    inGap = false
                }
            } else {
                currentGap += 1
                inGap = true
            }
        }

        // Handle wrap-around gap (from last filled to first filled)
        // Gap wraps: (24 - lastFilledIndex - 1) + firstFilledIndex
        let wrapGap = (24 - lastFilledIndex - 1) + firstFilledIndex
        maxGap = max(maxGap, wrapGap)

        // Span = total buckets - max gap
        return 24 - maxGap
    }

    /// Compute linear span in bucket count (non-circular, for phi)
    ///
    /// INPUT: phi bucket bitset (12 bits)
    /// OUTPUT: span in buckets [0, 12]
    ///
    /// - Parameter bitset: Phi bucket bitset
    /// - Returns: Span in buckets [0, 12]
    @inlinable
    public static func computeLinearSpanBuckets(_ bitset: PhiBucketBitset) -> Int {
        let bits = bitset.rawBits
        let count = bits.nonzeroBitCount

        if count == 0 { return 0 }
        if count == 1 { return 0 }

        // Find first and last filled bucket
        var firstFilled = -1
        var lastFilled = -1

        for i in 0..<12 {
            if (bits & (1 << i)) != 0 {
                if firstFilled == -1 {
                    firstFilled = i
                }
                lastFilled = i
            }
        }

        // Linear span = last - first (NOT +1, as per original spec)
        return lastFilled - firstFilled
    }

    /// Convert bucket span to degrees
    ///
    /// - Parameters:
    ///   - bucketSpan: Span in buckets
    ///   - bucketSizeDeg: Size of each bucket in degrees
    /// - Returns: Span in degrees
    @inlinable
    public static func spanToDegrees(_ bucketSpan: Int, bucketSizeDeg: Double) -> Double {
        return Double(bucketSpan) * bucketSizeDeg
    }
}
