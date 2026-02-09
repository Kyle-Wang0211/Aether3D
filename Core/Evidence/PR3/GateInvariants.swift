// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// GateInvariants.swift
// Aether3D
//
// PR3 - Runtime Invariant Validation
// DEBUG-only validation functions
//

import Foundation

/// Runtime invariant validation functions
///
/// DESIGN:
/// - All validation is @inline(__always) and DEBUG-only
/// - No performance impact in release builds
/// - Catches bugs early in development
public enum GateInvariants {

    /// Validate gate quality is in [0, 1] range
    ///
    /// - Parameter quality: Gate quality value
    #if DEBUG
    @inline(__always)
    public static func validateGateQuality01(_ quality: Double) {
        assert(quality >= 0.0 && quality <= 1.0, "Gate quality \(quality) out of [0, 1] range")
        assert(quality.isFinite, "Gate quality \(quality) is not finite")
    }
    #else
    @inline(__always)
    public static func validateGateQuality01(_ quality: Double) {
        // No-op in release
    }
    #endif

    /// Validate value is finite
    ///
    /// - Parameter value: Value to validate
    #if DEBUG
    @inline(__always)
    public static func validateFinite(_ value: Double) {
        assert(value.isFinite, "Value \(value) is not finite")
    }
    #else
    @inline(__always)
    public static func validateFinite(_ value: Double) {
        // No-op in release
    }
    #endif

    /// Validate value is non-negative
    ///
    /// - Parameter value: Value to validate
    #if DEBUG
    @inline(__always)
    public static func validateNonNegative(_ value: Double) {
        assert(value >= 0.0, "Value \(value) is negative")
    }
    #else
    @inline(__always)
    public static func validateNonNegative(_ value: Double) {
        // No-op in release
    }
    #endif

    /// Validate ratio is in [0, 1] range
    ///
    /// - Parameter ratio: Ratio value to validate
    #if DEBUG
    @inline(__always)
    public static func validateRatio01(_ ratio: Double) {
        assert(ratio >= 0.0 && ratio <= 1.0, "Ratio \(ratio) out of [0, 1] range")
        assert(ratio.isFinite, "Ratio \(ratio) is not finite")
    }
    #else
    @inline(__always)
    public static func validateRatio01(_ ratio: Double) {
        // No-op in release
    }
    #endif

    /// Validate angle is finite
    ///
    /// - Parameter angleDeg: Angle in degrees
    #if DEBUG
    @inline(__always)
    public static func validateAngleDegFinite(_ angleDeg: Double) {
        assert(angleDeg.isFinite, "Angle \(angleDeg) is not finite")
    }
    #else
    @inline(__always)
    public static func validateAngleDegFinite(_ angleDeg: Double) {
        // No-op in release
    }
    #endif
}
