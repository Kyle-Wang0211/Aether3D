// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  SpeedSmoothing.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Milestone 6
//  SpeedSmoothing - smooth speed transitions
//

import Foundation

/// SpeedSmoothing - smooth speed transitions
/// Max change rate: 30% per 200ms
public struct SpeedSmoothing {
    /// Smooth speed change
    /// Returns smoothed speed value
    public static func smooth(
        currentSpeed: Double,
        targetSpeed: Double,
        timeDeltaMs: Int64
    ) -> Double {
        let maxChangeRate = QualityPreCheckConstants.SPEED_MAX_CHANGE_RATE
        let windowMs = QualityPreCheckConstants.SPEED_SMOOTHING_WINDOW_MS
        let maxChange = maxChangeRate * (Double(timeDeltaMs) / Double(windowMs))
        
        let delta = targetSpeed - currentSpeed
        let clampedDelta = max(-maxChange, min(maxChange, delta))
        
        return currentSpeed + clampedDelta
    }
}

