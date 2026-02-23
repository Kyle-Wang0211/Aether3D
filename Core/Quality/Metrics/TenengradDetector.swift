// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  TenengradDetector.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - PR5-QUALITY-2.0
//  Tenengrad (Sobel-based) sharpness detector
//  Backup/complementary metric to Laplacian variance
//

import Foundation
import CAetherNativeBridge

/// TenengradDetector - Sobel-based sharpness detector
/// Uses sum of squared Sobel gradients: T = Σ(Gx² + Gy²)
///
/// Quality Level Behavior:
/// - Full: Full-resolution Sobel, dual-axis
/// - Degraded: 2x downsampled
/// - Emergency: Returns nil (skipped)
///
/// Reference: Krotkov & Martin, IEEE PAMI 1986
public class TenengradDetector {
    
    // MARK: - Quality Level Behavior
    
    /// Detect sharpness using Tenengrad measure
    /// - Parameter qualityLevel: Current FPS tier (Full/Degraded/Emergency)
    /// - Returns: MetricResult or nil if skipped (Emergency mode)
    public func detect(qualityLevel: QualityLevel) -> MetricResult? {
        let nativeLevel: Int32
        switch qualityLevel {
        case .full:
            nativeLevel = 0
        case .degraded:
            nativeLevel = 1
        case .emergency:
            nativeLevel = 2
        }

        var value = 0.0
        var confidence = 0.0
        var roiCoverage = 0.0
        var skipped: Int32 = 0
        let rc = aether_tenengrad_detect(
            nativeLevel,
            FrameQualityConstants.TENENGRAD_THRESHOLD,
            &value,
            &confidence,
            &roiCoverage,
            &skipped
        )
        if rc == 0 {
            if skipped != 0 {
                return nil
            }
            return MetricResult(value: value, confidence: confidence, roiCoverageRatio: roiCoverage)
        }
        return nil
    }
}
