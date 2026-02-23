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
        // Deterministic overlap proxy based on frame intensity drift + temporal spacing.
        // This keeps behavior replayable while avoiding non-deterministic feature extractors.
        let baseline: Double
        switch direction {
        case .forward:
            baseline = QualityThresholds.frameOverlapForward
        case .side:
            baseline = QualityThresholds.frameOverlapSide
        case .backward:
            baseline = QualityThresholds.frameOverlapForward
        }

        let photometricDelta = sampleAbsoluteDifference(frame1.imageData, frame2.imageData)
        let photometricPenalty = min(0.45, photometricDelta * 0.55)

        let dt = abs(frame2.timestamp.timeIntervalSince(frame1.timestamp))
        let temporalPenalty = min(0.25, dt / 8.0)

        let overlap = baseline - photometricPenalty - temporalPenalty
        return max(0.0, min(1.0, overlap))
    }

    private func sampleAbsoluteDifference(_ lhs: Data, _ rhs: Data) -> Double {
        let count = min(lhs.count, rhs.count)
        guard count > 0 else { return 0.0 }

        let sampleCount = min(1024, count)
        let stride = max(1, count / sampleCount)

        var diffSum = 0.0
        var used = 0
        var index = 0
        while index < count, used < sampleCount {
            let a = Double(lhs[lhs.index(lhs.startIndex, offsetBy: index)])
            let b = Double(rhs[rhs.index(rhs.startIndex, offsetBy: index)])
            diffSum += abs(a - b)
            used += 1
            index += stride
        }

        guard used > 0 else { return 0.0 }
        return diffSum / (Double(used) * 255.0)
    }
}

/// Motion Direction
public enum MotionDirection: Sendable {
    case forward
    case side
    case backward
}
