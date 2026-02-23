// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// PRMathFast.swift
// Aether3D
//
// PR3 - LUT-based Math Implementation (SHADOW/BENCHMARK ONLY)
// Not used in canonical path
//

import Foundation

/// Fast math implementation using LUT (SHADOW/BENCHMARK ONLY)
///
/// CRITICAL: This is NOT used in canonical path!
/// PURPOSE: Shadow verification, performance benchmarking
public enum PRMathFast {

    /// LUT-based sigmoid
    ///
    /// - Parameter x: Input value
    /// - Returns: Sigmoid value ∈ (0, 1) from LUT
    @inlinable
    public static func sigmoid(_ x: Double) -> Double {
        return LUTSigmoidGuarded.sigmoid(x)
    }
}
