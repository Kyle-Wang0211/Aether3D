// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// PRMathDouble.swift
// Aether3D
//
// PR3 - Double Precision Math Implementation (CANONICAL)
// Stable, deterministic, no LUT in core
//

import Foundation

/// Double precision math implementation (CANONICAL PATH)
///
/// This is the reference implementation used in production.
/// All golden tests use this backend.
public enum PRMathDouble {

    /// Standard sigmoid using stable logistic
    ///
    /// - Parameter x: Input value
    /// - Returns: Sigmoid value ∈ (0, 1)
    @inlinable
    public static func sigmoid(_ x: Double) -> Double {
        return StableLogistic.sigmoid(x)
    }

    /// Safe exponential with clamping
    ///
    /// - Parameter x: Input value (clamped to [-80, 80])
    /// - Returns: exp(x) with clamped input
    @inlinable
    public static func expSafe(_ x: Double) -> Double {
        return StableLogistic.expSafe(x)
    }
}
