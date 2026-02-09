// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// TierContext.swift
// Aether3D
//
// PR3 - Tier Injection Context
// Explicit tier injection, no runtime auto-detect in core
//

import Foundation

/// Tier Context: Injected into algorithm layer
///
/// DESIGN:
/// - Created at App/CLI startup
/// - Passed down to all algorithm components
/// - Never mutated after creation
/// - Never auto-detected within algorithms
public struct TierContext: Sendable {

    /// The injected tier
    public let tier: PerformanceTier

    /// Create with explicit tier
    public init(tier: PerformanceTier) {
        self.tier = tier
    }

    /// Create for testing (always canonical)
    public static let forTesting = TierContext(tier: .canonical)

    /// Create for benchmark (fast)
    public static let forBenchmark = TierContext(tier: .fast)
}
