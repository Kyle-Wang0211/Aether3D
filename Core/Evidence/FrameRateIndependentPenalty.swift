// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// FrameRateIndependentPenalty.swift
// Aether3D
//
// PR2 Patch V4 - Frame-Rate Independent Penalty
// All penalty logic based on elapsed seconds, not frame count
//

import Foundation

/// Frame-rate independent penalty configuration
public struct FrameRateIndependentPenalty {
    
    // MARK: - Reference Configuration
    
    /// Reference frame rate for parameter definition
    public static let referenceFrameRate: Double = 30.0
    
    /// Current device frame rate (set at initialization)
    public static var currentFrameRate: Double = 30.0
    
    /// Frame rate multiplier (reference / current)
    public static var frameRateMultiplier: Double {
        return referenceFrameRate / currentFrameRate
    }
    
    // MARK: - Per-Second Penalty Rates
    
    /// Maximum penalty per SECOND (not per frame)
    /// At 30fps: 0.01 per frame = 0.30 per second
    /// At 60fps: 0.005 per frame = 0.30 per second (same rate)
    public static let maxPenaltyPerSecond: Double = 0.30
    
    /// Penalty per observation (base, before frame rate adjustment)
    /// This is applied per OBSERVATION, not per frame
    public static let basePenaltyPerObservation: Double = 0.01
    
    /// Compute adjusted penalty for current frame rate
    /// - Parameter observations: Number of observations this frame
    /// - Returns: Total penalty for this frame
    public static func computeFramePenalty(observations: Int) -> Double {
        // Each observation contributes basePenalty
        // But total per-second penalty is capped
        let rawPenalty = Double(observations) * basePenaltyPerObservation
        let maxPerFrame = maxPenaltyPerSecond / currentFrameRate
        return min(rawPenalty, maxPerFrame)
    }
    
    // MARK: - Cooldown (Time-Based)
    
    /// Cooldown period in SECONDS (frame-rate independent)
    public static let cooldownSeconds: Double = 0.5
    
    /// Check if cooldown has elapsed
    public static func isCooldownElapsed(lastPenaltyTime: TimeInterval, currentTime: TimeInterval) -> Bool {
        return (currentTime - lastPenaltyTime) >= cooldownSeconds
    }
    
    // MARK: - Error Streak Decay
    
    /// Error streak decay rate per SECOND
    /// At 30fps: streak -= 0.033 per frame (1 per second)
    /// At 60fps: streak -= 0.0165 per frame (still 1 per second)
    public static let errorStreakDecayPerSecond: Double = 1.0
    
    /// Compute error streak decay for this frame
    public static func computeStreakDecay() -> Double {
        return errorStreakDecayPerSecond / currentFrameRate
    }
}
