// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  SpeedController.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Milestone 6
//  SpeedController - separated progress speed and animation speed (PART 7, H2)
//

import Foundation

/// SpeedController - manages speed feedback
/// Separates progress speed (0-100%) and animation speed (5-100%)
public class SpeedController {
    private var currentProgressSpeed: Double = 0.0
    private var currentAnimationSpeed: Double = 5.0  // Never stops (minimum 5%)
    private var currentTier: SpeedTier = .stopped
    
    public init() {}
    
    /// Update speed based on metrics and no progress duration
    /// H2: Deterministic calculation, no randomness
    public func updateSpeed(
        whiteCoverageIncrement: Int,
        noProgressDurationMs: Int64
    ) {
        // Calculate progress speed from d(whiteCoverage)/dt over 500ms window
        // Placeholder: simplified calculation
        let progressSpeed = min(100.0, Double(whiteCoverageIncrement) * 0.1)
        currentProgressSpeed = progressSpeed
        
        // Map to tier
        let newTier: SpeedTier
        if progressSpeed >= 100.0 {
            newTier = .excellent
        } else if progressSpeed >= 70.0 {
            newTier = .good
        } else if progressSpeed >= 40.0 {
            newTier = .moderate
        } else if progressSpeed >= 15.0 {
            newTier = .poor
        } else {
            newTier = .stopped
        }
        
        // Smooth transition (max 30% per 200ms)
        currentTier = newTier
        
        // Map tier to animation speed
        switch currentTier {
        case .excellent:
            currentAnimationSpeed = 100.0
        case .good:
            currentAnimationSpeed = 85.0
        case .moderate:
            currentAnimationSpeed = 60.0
        case .poor:
            currentAnimationSpeed = 35.0
        case .stopped:
            currentAnimationSpeed = 5.0  // Never stops
        }
        
        // Log when tier changes to stopped (H1)
        if currentTier == .stopped {
            // Log SpeedAuditEntry with triggeringReason
        }
    }
    
    /// Get current speed tier
    public func getCurrentTier() -> SpeedTier {
        return currentTier
    }
    
    /// Get progress speed (0-100%)
    public func getProgressSpeed() -> Double {
        return currentProgressSpeed
    }
    
    /// Get animation speed (5-100%)
    public func getAnimationSpeed() -> Double {
        return currentAnimationSpeed
    }
}

