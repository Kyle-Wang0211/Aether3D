// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  ConfidenceGate.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Milestone 3
//  ConfidenceGate - pure helper for confidence checks (P19/P23)
//

import Foundation

/// ConfidenceGate - pure helper for confidence threshold checks
/// P19/P23: Cannot be used directly for final Gray→White decisions
/// Must be called only from within DecisionPolicy
public struct ConfidenceGate {
    /// Check Black→Gray confidence
    /// Threshold: 0.7 (exposure OR focus either passes)
    public static func checkBlackToGray(
        brightness: MetricResult?,
        laplacian: MetricResult?,
        focus: MetricResult?
    ) -> Bool {
        let brightnessPass: Bool
        if let brightness = brightness {
            brightnessPass = brightness.confidence >= 0.7
        } else {
            brightnessPass = false
        }
        
        let focusPass: Bool
        if let focus = focus {
            focusPass = focus.confidence >= 0.7
        } else {
            focusPass = false
        }
        
        return brightnessPass || focusPass
    }
    
    // NOTE: checkGrayToWhite has been moved to DecisionPolicy as private nested helper
    // This ensures compile-time sealing - cannot be called outside DecisionPolicy.swift
}

