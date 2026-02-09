// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// PRMathFixed.swift
// Aether3D
//
// PR3 - Fixed-Point Math Implementation (PLACEHOLDER)
// Future implementation for embedded systems
//

import Foundation

/// Fixed-point math implementation (PLACEHOLDER)
///
/// This is a placeholder for future Q32.32 fixed-point implementation.
/// Currently just forwards to Double implementation.
public enum PRMathFixed {

    /// Fixed-point sigmoid (placeholder)
    ///
    /// - Parameter x: Input value (will be Q32.32 in future)
    /// - Returns: Sigmoid value
    @inlinable
    public static func sigmoid(_ x: Double) -> Double {
        // Placeholder: use Double implementation
        return StableLogistic.sigmoid(x)
    }
}
