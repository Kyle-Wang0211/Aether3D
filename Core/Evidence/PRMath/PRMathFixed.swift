// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// PRMathFixed.swift
// Aether3D
//
// PR3 - Fixed-point math compatibility layer
// Current implementation forwards to deterministic Double backend.
//

import Foundation

/// Fixed-point math compatibility layer.
///
/// Q32.32 backend is intentionally deferred; deterministic behavior currently
/// reuses the Double implementation.
public enum PRMathFixed {

    /// Fixed-point sigmoid compatibility entry.
    ///
    /// - Parameter x: Input value (will be Q32.32 in future)
    /// - Returns: Sigmoid value
    @inlinable
    public static func sigmoid(_ x: Double) -> Double {
        // Reuse stable Double implementation until Q32.32 backend is activated.
        return StableLogistic.sigmoid(x)
    }
}
