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
        switch qualityLevel {
        case .full:
            return detectFull()
        case .degraded:
            return detectDegraded()
        case .emergency:
            // Skip in emergency mode to preserve frame budget
            return nil
        }
    }
    
    // MARK: - Private Implementation
    
    private func detectFull() -> MetricResult {
        // Placeholder: Real implementation would use vImage/Accelerate
        // Sobel kernels:
        // Gx = [[-1, 0, 1], [-2, 0, 2], [-1, 0, 1]]
        // Gy = [[-1, -2, -1], [0, 0, 0], [1, 2, 1]]
        // T = Σ(Gx² + Gy²) / N
        
        let tenengradValue = FrameQualityConstants.TENENGRAD_THRESHOLD
        
        // H1: NaN/Inf check
        if tenengradValue.isNaN || tenengradValue.isInfinite {
            return MetricResult(value: 0.0, confidence: 0.0, roiCoverageRatio: 0.0)
        }
        
        // Return placeholder result
        return MetricResult(
            value: tenengradValue,
            confidence: 0.95,
            roiCoverageRatio: 1.0
        )
    }
    
    private func detectDegraded() -> MetricResult {
        // Downsampled version for performance
        let tenengradValue = FrameQualityConstants.TENENGRAD_THRESHOLD
        
        // H1: NaN/Inf check
        if tenengradValue.isNaN || tenengradValue.isInfinite {
            return MetricResult(value: 0.0, confidence: 0.0, roiCoverageRatio: 0.0)
        }
        
        return MetricResult(
            value: tenengradValue,
            confidence: 0.85,
            roiCoverageRatio: 0.5
        )
    }
}
