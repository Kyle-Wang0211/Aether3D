// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// PerformanceTier.swift
// Aether3D
//
// PR3 - Performance Tier Selection
// Explicit injection only, no auto-detect in core
//

import Foundation

/// Performance Tier: Explicitly injected, never auto-detected in core
///
/// RULE: Core algorithm layer MUST NOT call autoDetect()
/// RULE: Tier MUST be injected from App/CLI layer
/// RULE: Tests MUST use .canonical (Double)
public enum PerformanceTier: String, Codable, Sendable {

    /// Canonical tier: PRMathDouble, stable sigmoid
    /// USAGE: All production code, all tests, all golden comparisons
    case canonical = "canonical"

    /// Fast tier: PRMathFast, LUT sigmoid
    /// USAGE: Benchmark, shadow verification, performance profiling ONLY
    case fast = "fast"

    /// Fixed tier: PRMathFixed, fixed-point (future)
    /// USAGE: Embedded systems (future)
    case fixed = "fixed"

    /// Auto-detect based on device (FORBIDDEN in core!)
    /// USAGE: App/CLI initialization ONLY
    ///
    /// NOTE: This method exists but is FORBIDDEN to call from core algorithm layer
    /// CI lint will flag any usage in Core/Evidence/PR3/
    public static func autoDetect() -> PerformanceTier {
        #if targetEnvironment(simulator)
        return .canonical
        #else
        let cores = ProcessInfo.processInfo.processorCount
        return cores >= 6 ? .canonical : .fast
        #endif
    }
}
