//
// ZeroTrigPhiBucketing.swift
// Aether3D
//
// PR3 - Zero-Trig Phi Bucketing (Vertical Angle)
// No asin() needed - uses precomputed sin boundaries
//

import Foundation

/// Zero-Trig Phi Bucketing: No asin() needed
///
/// PROBLEM: asin(d.y) is non-deterministic across platforms
///
/// SOLUTION: Precompute sin(φ_k) boundaries and compare d.y directly
///
/// MATH:
/// - Phi range: [-90°, +90°] → 12 buckets of 15° each
/// - Bucket k covers: [φ_k, φ_{k+1}) where φ_k = -90° + k * 15°
/// - sin(φ_k) is a constant for each bucket boundary
/// - d.y = sin(φ) where φ is the actual vertical angle
/// - Therefore: bucket = findInterval(d.y, precomputedSinBoundaries)
///
/// PRECOMPUTED BOUNDARIES (compile-time constants):
/// - sin(-90°) = -1.0
/// - sin(-75°) = -0.9659258262890683
/// - sin(-60°) = -0.8660254037844387
/// - sin(-45°) = -0.7071067811865476
/// - sin(-30°) = -0.5
/// - sin(-15°) = -0.2588190451025208
/// - sin(0°)   = 0.0
/// - sin(15°)  = 0.2588190451025208
/// - sin(30°)  = 0.5
/// - sin(45°)  = 0.7071067811865476
/// - sin(60°)  = 0.8660254037844387
/// - sin(75°)  = 0.9659258262890683
/// - sin(90°)  = 1.0
public enum ZeroTrigPhiBucketing {

    /// Precomputed sin boundaries for 12 phi buckets
    /// Index i contains sin(-90° + i * 15°)
    /// 13 boundaries for 12 buckets
    public static let sinBoundaries: [Double] = [
        -1.0,                    // sin(-90°) - bucket 0 lower
        -0.9659258262890683,     // sin(-75°) - bucket 1 lower
        -0.8660254037844387,     // sin(-60°) - bucket 2 lower
        -0.7071067811865476,     // sin(-45°) - bucket 3 lower
        -0.5,                    // sin(-30°) - bucket 4 lower
        -0.2588190451025208,     // sin(-15°) - bucket 5 lower
        0.0,                     // sin(0°)   - bucket 6 lower
        0.2588190451025208,      // sin(15°)  - bucket 7 lower
        0.5,                     // sin(30°)  - bucket 8 lower
        0.7071067811865476,      // sin(45°)  - bucket 9 lower
        0.8660254037844387,      // sin(60°)  - bucket 10 lower
        0.9659258262890683,      // sin(75°)  - bucket 11 lower
        1.0                      // sin(90°)  - upper bound
    ]

    /// Number of phi buckets
    public static let bucketCount: Int = 12

    /// Convert d.y (vertical component of normalized direction) to phi bucket
    ///
    /// PRECONDITION: d.y ∈ [-1, 1] (from normalized direction vector)
    /// OUTPUT: bucket index ∈ [0, 11]
    /// DETERMINISM: Pure comparison, no trig functions
    ///
    /// ALGORITHM: Binary search on precomputed boundaries
    /// TIME: O(log 12) = O(1) for fixed size
    ///
    /// - Parameter dy: Vertical component of normalized direction vector
    /// - Returns: Bucket index ∈ [0, 11]
    @inlinable
    public static func phiBucket(dy: Double) -> Int {
        // Clamp to valid range (defensive)
        let clampedDy = max(-1.0, min(1.0, dy))

        // Binary search for bucket
        // Find largest i such that sinBoundaries[i] <= clampedDy
        var lo = 0
        var hi = bucketCount  // 12 buckets

        while lo < hi {
            let mid = (lo + hi + 1) / 2  // Ceiling division
            if sinBoundaries[mid] <= clampedDy {
                lo = mid
            } else {
                hi = mid - 1
            }
        }

        // Clamp to valid bucket range
        return max(0, min(bucketCount - 1, lo))
    }
}
