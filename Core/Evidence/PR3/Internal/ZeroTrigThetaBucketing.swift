// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// ZeroTrigThetaBucketing.swift
// Aether3D
//
// PR3 - Zero-Trig Theta Bucketing (Horizontal Angle)
// No atan2() needed - uses precomputed unit vectors
//

import Foundation

/// Zero-Trig Theta Bucketing: No atan2() needed
///
/// PROBLEM: atan2(d.x, d.z) is non-deterministic across platforms
///
/// SOLUTION: Sector classification via dot product with precomputed unit vectors
///
/// MATH:
/// - Theta range: [0°, 360°) → 24 buckets of 15° each
/// - Bucket k center: θ_k = k * 15°
/// - Unit vector for bucket k: u_k = (sin(θ_k), cos(θ_k))
/// - For direction (d.x, d.z), find bucket with max dot product:
///   bucket = argmax_k { d.x * sin(θ_k) + d.z * cos(θ_k) }
///
/// PRECOMPUTED UNIT VECTORS (compile-time constants):
/// For bucket k at angle θ_k = k * 15°:
/// - u_k.x = sin(θ_k)  (horizontal component)
/// - u_k.z = cos(θ_k)  (depth component)
public enum ZeroTrigThetaBucketing {

    /// Precomputed unit vectors for 24 theta buckets
    /// Index k contains (sin(k * 15°), cos(k * 15°))
    public static let unitVectors: [(x: Double, z: Double)] = [
        (0.0, 1.0),                                      // 0°
        (0.2588190451025208, 0.9659258262890683),        // 15°
        (0.5, 0.8660254037844387),                       // 30°
        (0.7071067811865476, 0.7071067811865476),        // 45°
        (0.8660254037844387, 0.5),                       // 60°
        (0.9659258262890683, 0.2588190451025208),        // 75°
        (1.0, 0.0),                                      // 90°
        (0.9659258262890683, -0.2588190451025208),       // 105°
        (0.8660254037844387, -0.5),                      // 120°
        (0.7071067811865476, -0.7071067811865476),       // 135°
        (0.5, -0.8660254037844387),                      // 150°
        (0.2588190451025208, -0.9659258262890683),       // 165°
        (0.0, -1.0),                                     // 180°
        (-0.2588190451025208, -0.9659258262890683),      // 195°
        (-0.5, -0.8660254037844387),                     // 210°
        (-0.7071067811865476, -0.7071067811865476),      // 225°
        (-0.8660254037844387, -0.5),                     // 240°
        (-0.9659258262890683, -0.2588190451025208),      // 255°
        (-1.0, 0.0),                                     // 270°
        (-0.9659258262890683, 0.2588190451025208),       // 285°
        (-0.8660254037844387, 0.5),                      // 300°
        (-0.7071067811865476, 0.7071067811865476),       // 315°
        (-0.5, 0.8660254037844387),                      // 330°
        (-0.2588190451025208, 0.9659258262890683)        // 345°
    ]

    /// Number of theta buckets
    public static let bucketCount: Int = 24

    /// Convert (d.x, d.z) to theta bucket using dot product
    ///
    /// PRECONDITION: (d.x, d.z) is normalized in XZ plane (or will be normalized)
    /// OUTPUT: bucket index ∈ [0, 23]
    /// DETERMINISM: Pure arithmetic, no trig functions
    ///
    /// ALGORITHM: Find bucket with maximum dot product
    /// TIME: O(24) = O(1) for fixed size
    ///
    /// - Parameters:
    ///   - dx: X component of direction vector
    ///   - dz: Z component of direction vector
    /// - Returns: Bucket index ∈ [0, 23]
    @inlinable
    public static func thetaBucket(dx: Double, dz: Double) -> Int {
        // Normalize XZ component (handle degenerate case)
        let lengthXZ = sqrt(dx * dx + dz * dz)
        guard lengthXZ > 1e-10 else {
            // Degenerate case: looking straight up/down
            // Return bucket 0 as deterministic fallback
            return 0
        }

        let nx = dx / lengthXZ
        let nz = dz / lengthXZ

        // Find bucket with maximum dot product
        var bestBucket = 0
        var bestDot = -2.0  // Minimum possible dot product is -1

        for k in 0..<bucketCount {
            let dot = nx * unitVectors[k].x + nz * unitVectors[k].z
            if dot > bestDot {
                bestDot = dot
                bestBucket = k
            }
        }

        return bestBucket
    }

    /// OPTIMIZED VERSION: Use quadrant + fine search
    /// Reduces comparisons from 24 to ~8
    ///
    /// - Parameters:
    ///   - dx: X component of direction vector
    ///   - dz: Z component of direction vector
    /// - Returns: Bucket index ∈ [0, 23]
    @inlinable
    public static func thetaBucketOptimized(dx: Double, dz: Double) -> Int {
        // Normalize XZ component
        let lengthXZ = sqrt(dx * dx + dz * dz)
        guard lengthXZ > 1e-10 else { return 0 }

        let nx = dx / lengthXZ
        let nz = dz / lengthXZ

        // Determine quadrant (0-3) based on signs
        let quadrant: Int
        if nz >= 0 {
            quadrant = nx >= 0 ? 0 : 3  // Q0: +x+z, Q3: -x+z
        } else {
            quadrant = nx >= 0 ? 1 : 2  // Q1: +x-z, Q2: -x-z
        }

        // Search only within quadrant (6 buckets each)
        let startBucket = quadrant * 6
        var bestBucket = startBucket
        var bestDot = -2.0

        for offset in 0..<6 {
            let k = startBucket + offset
            let dot = nx * unitVectors[k].x + nz * unitVectors[k].z
            if dot > bestDot {
                bestDot = dot
                bestBucket = k
            }
        }

        return bestBucket
    }
}
