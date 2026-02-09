// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// OverlapEstimator.swift
// Aether3D
//
// Overlap Estimator - Frame overlap estimation
//

import Foundation

/// Overlap Estimator
///
/// Estimates frame overlap for photogrammetry.
public actor OverlapEstimator {
    
    /// Estimate frame overlap
    /// 
    /// 符合 PR5-02: Research-backed thresholds (FRAME_OVERLAP_FORWARD: 0.80, FRAME_OVERLAP_SIDE: 0.65)
    /// - Parameters:
    ///   - frame1: First frame
    ///   - frame2: Second frame
    ///   - direction: Motion direction
    /// - Returns: Overlap ratio (0.0 to 1.0)
    public func estimateOverlap(frame1: FrameData, frame2: FrameData, direction: MotionDirection) async -> Double {
        // Placeholder - in production, use feature matching to estimate overlap
        // Use research-backed thresholds from QualityThresholds
        switch direction {
        case .forward:
            return QualityThresholds.frameOverlapForward
        case .side:
            return QualityThresholds.frameOverlapSide
        case .backward:
            return QualityThresholds.frameOverlapForward // Same as forward
        }
    }
}

/// Motion Direction
public enum MotionDirection: Sendable {
    case forward
    case side
    case backward
}
