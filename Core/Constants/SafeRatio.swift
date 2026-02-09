// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// SafeRatio.swift
// Aether3D
//
// PR#1 SSOT Foundation v1.1 - Safe Ratio Calculation Struct
//
// This struct provides safe ratio calculation with audit metadata.
//

import Foundation

/// Safe ratio calculation struct with audit metadata.
///
/// **Rule ID:** MATH_SAFE_001, MATH_SAFE_001A
/// **Status:** IMMUTABLE
///
/// **Enhancements (v1.1):**
/// - NaN/Inf input defense (closed-set handling strategy)
/// - Negative input strategy (triggers EdgeCase)
/// - Audit field consistency (rawValue must exist iff clamp/edgecase triggered)
public struct SafeRatio {
    /// Clamped value (used by downstream logic).
    /// **Range:** [0.0, 1.0]
    public let clampedValue: Double
    
    /// Raw value (only present if clampTriggered == true or edgeCasesTriggered.nonEmpty).
    /// **Rule ID:** MATH_SAFE_001A
    public let rawValue: Double?
    
    /// Whether clamp was triggered.
    public let clampTriggered: Bool
    
    /// Edge cases triggered during calculation.
    public let edgeCasesTriggered: [EdgeCaseType]
    
    /// Initializes SafeRatio with numerator and denominator.
    ///
    /// **Rule ID:** MATH_SAFE_001
    /// **Status:** IMMUTABLE
    ///
    /// Rules:
    /// - If denominator == 0, return clampedValue = 0.0 and set edgeCaseTriggered
    /// - If numerator/denominator > 1.0 or < 0.0, clamp and set clampTriggered = true
    /// - NaN/Inf inputs trigger EdgeCase.NAN_OR_INF_DETECTED
    /// - Negative inputs trigger EdgeCase.NEGATIVE_INPUT
    public init(numerator: Double, denominator: Double) {
        // Check for NaN/Inf
        if !numerator.isFinite || !denominator.isFinite {
            self.clampedValue = 0.0
            self.rawValue = numerator / denominator
            self.clampTriggered = false
            self.edgeCasesTriggered = [.NAN_OR_INF_DETECTED]
            return
        }
        
        // Check for negative inputs
        if numerator < 0 || denominator < 0 {
            self.clampedValue = 0.0
            self.rawValue = numerator / denominator
            self.clampTriggered = false
            self.edgeCasesTriggered = [.NEGATIVE_INPUT]
            return
        }
        
        // Check for denominator zero
        if denominator == 0 {
            self.clampedValue = 0.0
            self.rawValue = nil
            self.clampTriggered = false
            self.edgeCasesTriggered = [.EMPTY_GEOMETRY]
            return
        }
        
        let raw = numerator / denominator
        
        // Clamp to [0.0, 1.0]
        if raw > 1.0 {
            self.clampedValue = 1.0
            self.rawValue = raw
            self.clampTriggered = true
            self.edgeCasesTriggered = []
        } else if raw < 0.0 {
            self.clampedValue = 0.0
            self.rawValue = raw
            self.clampTriggered = true
            self.edgeCasesTriggered = []
        } else {
            self.clampedValue = raw
            self.rawValue = nil
            self.clampTriggered = false
            self.edgeCasesTriggered = []
        }
    }
}
