// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// DeterminismMode.swift
// PR4Determinism
//
// PR4 V10 - Pillar 36: Determinism mode separation (STRICT vs FAST)
//

import Foundation

/// Determinism mode
///
/// V8 RULE: Two modes with different error handling but same core computation.
public enum DeterminismMode: String, Codable {
    case strict = "STRICT"
    case fast = "FAST"
    
    /// Current mode (set at build time)
    public static var current: DeterminismMode {
        #if DETERMINISM_STRICT
        return .strict
        #else
        return .fast
        #endif
    }
    
    /// Check if in STRICT mode
    public static var isStrict: Bool {
        return current == .strict
    }
    
    /// Check if in FAST mode
    public static var isFast: Bool {
        return current == .fast
    }
}
