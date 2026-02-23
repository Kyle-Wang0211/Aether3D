// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// MathSafetyConstants.swift
// Aether3D
//
// PR#1 SSOT Foundation v1.1 - Math Safety Constants
//
// This file defines math safety constants including clamp rules.
//

import Foundation

/// Math safety constants for safe mathematical operations.
///
/// **Rule ID:** MATH_CLAMP_001, MATH_SAFE_001
/// **Status:** IMMUTABLE
public enum MathSafetyConstants {
    
    // MARK: - Clamp Rules Table
    
    /// Clamp rule for ratio values.
    /// **Unit:** ratio
    /// **Scope:** identity
    /// **Range:** [0.0, 1.0]
    public static let RATIO_MIN: Double = 0.0
    public static let RATIO_MAX: Double = 1.0
    
    /// Clamp rule for score values.
    /// **Unit:** ratio
    /// **Scope:** identity
    /// **Range:** [0.0, 1.0]
    public static let SCORE_MIN: Double = 0.0
    public static let SCORE_MAX: Double = 1.0
    
    /// Clamp rule for weight values.
    /// **Unit:** dimensionless
    /// **Scope:** identity
    /// **Range:** [0.0, +∞)
    public static let WEIGHT_MIN: Double = 0.0
    // No upper limit for weights
    
    /// Clamp rule for count values.
    /// **Unit:** count
    /// **Scope:** identity
    /// **Range:** [0, +∞)
    public static let COUNT_MIN: Int = 0
    // No upper limit for counts
    
    /// Clamp rule for area values.
    /// **Unit:** meters²
    /// **Scope:** identity
    /// **Range:** [0.0, +∞)
    public static let AREA_MIN: Double = 0.0
    // No upper limit for areas
    
    // MARK: - Negative Input Policy
    
    /// Negative input policy for v1.1.
    /// **Rule ID:** MATH_SAFE_003
    /// **Status:** IMMUTABLE
    ///
    /// v1.1 choice: clamp_to_zero_and_flag
    public static let NEGATIVE_INPUT_POLICY = "clamp_to_zero_and_flag"
}
