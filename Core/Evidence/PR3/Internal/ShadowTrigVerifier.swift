// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// ShadowTrigVerifier.swift
// Aether3D
//
// PR3 - Shadow Trig Verifier (DEBUG Only)
// Uses actual trig functions for verification, does NOT participate in canonical output
//

import Foundation

/// Shadow Trig Verifier: Uses actual trig functions for verification
///
/// PURPOSE:
/// - Verify that zero-trig bucketing matches trig-based bucketing
/// - Track mismatch statistics (should be 0 in theory)
/// - Does NOT participate in canonical output
///
/// USAGE:
/// - Called in DEBUG builds only
/// - Logs mismatches for investigation
/// - Never affects gate quality computation
public enum ShadowTrigVerifier {

    /// Statistics for mismatch tracking
    public struct MismatchStats {
        public var totalComparisons: Int = 0
        public var thetaMismatches: Int = 0
        public var phiMismatches: Int = 0

        public init() {}
    }

    /// Thread-local mismatch stats (DEBUG only)
    /// Note: This is not thread-safe, intended for single-threaded DEBUG verification only
    #if DEBUG
    public static var stats = MismatchStats()
    #endif

    /// Verify phi bucket using actual asin
    ///
    /// RETURNS: true if canonical and trig-based match
    ///
    /// - Parameters:
    ///   - dy: Vertical component of direction vector
    ///   - canonicalBucket: Bucket from zero-trig method
    /// - Returns: true if match, false if mismatch
    @inlinable
    public static func verifyPhiBucket(dy: Double, canonicalBucket: Int) -> Bool {
        #if DEBUG
        stats.totalComparisons += 1

        // Trig-based calculation (LINT_OK: Shadow verifier intentionally uses trig)
        let phi = asin(max(-1.0, min(1.0, dy)))  // LINT_OK radians
        let phiDeg = phi * 180.0 / .pi           // degrees [-90, 90]
        let trigBucket = Int(floor((phiDeg + 90.0) / 15.0))
        let clampedTrigBucket = max(0, min(11, trigBucket))

        if canonicalBucket != clampedTrigBucket {
            stats.phiMismatches += 1
            // Log for investigation
            print("[ShadowTrig] Phi mismatch: dy=\(dy), canonical=\(canonicalBucket), trig=\(clampedTrigBucket)")
            return false
        }
        return true
        #else
        return true  // No verification in release
        #endif
    }

    /// Verify theta bucket using actual atan2
    ///
    /// - Parameters:
    ///   - dx: X component of direction vector
    ///   - dz: Z component of direction vector
    ///   - canonicalBucket: Bucket from zero-trig method
    /// - Returns: true if match, false if mismatch
    @inlinable
    public static func verifyThetaBucket(dx: Double, dz: Double, canonicalBucket: Int) -> Bool {
        #if DEBUG
        stats.totalComparisons += 1

        // Trig-based calculation (LINT_OK: Shadow verifier intentionally uses trig)
        let theta = atan2(dx, dz)  // LINT_OK radians, from +Z axis
        var thetaDeg = theta * 180.0 / .pi       // degrees [-180, 180]
        if thetaDeg < 0 { thetaDeg += 360.0 }    // normalize to [0, 360)
        let trigBucket = Int(floor(thetaDeg / 15.0))
        let clampedTrigBucket = max(0, min(23, trigBucket))

        if canonicalBucket != clampedTrigBucket {
            stats.thetaMismatches += 1
            print("[ShadowTrig] Theta mismatch: dx=\(dx), dz=\(dz), canonical=\(canonicalBucket), trig=\(clampedTrigBucket)")
            return false
        }
        return true
        #else
        return true
        #endif
    }
}
