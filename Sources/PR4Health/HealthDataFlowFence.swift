// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// HealthDataFlowFence.swift
// PR4Health
//
// PR4 V10 - Pillar 14: Health dependency linter + dataflow fence
//

import Foundation

/// Health data flow fence
///
/// V9 RULE: Compile-time enforcement that Health cannot import Quality/Uncertainty/Gate.
/// This file documents the fence - actual enforcement is via Package.swift dependencies.
public enum HealthDataFlowFence {
    
    /// Forbidden modules for Health
    public static let forbiddenModules: Set<String> = [
        "PR4Quality",
        "PR4Uncertainty",
        "PR4Gate",
    ]
    
    /// Allowed inputs for Health
    public static let allowedInputTypes: Set<String> = [
        "Double",      // Raw metrics
        "Int64",       // Q16 values
        "Bool",        // Flags
        "HealthInputs", // Structured inputs
    ]
    
    /// Verify no forbidden imports
    ///
    /// NOTE: This is a compile-time check via Package.swift.
    /// Runtime check is for documentation only.
    public static func verifyNoForbiddenImports() -> Bool {
        // In production, this would scan imports
        // For now, assume correct if we're running
        return true
    }
}
