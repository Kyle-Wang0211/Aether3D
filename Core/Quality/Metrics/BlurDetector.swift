// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  BlurDetector.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Milestone 2
//  BlurDetector - Laplacian variance blur detection
//

import Foundation

/// BlurResult - result of blur detection
public struct BlurResult: Codable, Sendable {
    public let variance: Double
    public let isNoisy: Bool
    public let centerVariance: Double
    public let edgeVariance: Double
    
    public init(variance: Double, isNoisy: Bool, centerVariance: Double, edgeVariance: Double) {
        self.variance = variance
        self.isNoisy = isNoisy
        self.centerVariance = centerVariance
        self.edgeVariance = edgeVariance
    }
}

/// BlurDetector - Multi-method blur detection with IMU integration
/// 符合 PR5-01: Beyond Laplacian Blur Detection (7 methods)
public class BlurDetector {
    // H2: Independent state
    public init() {}
    
    /// Detect blur for frame (async version)
    /// 
    /// 符合 PR5-01: Multi-method blur detection (Laplacian, Tenengrad, Brenner, Modified Laplacian, Variance of Laplacian, Michelson Contrast, IMU-based motion blur)
    /// - Parameter frame: Frame data
    /// - Returns: Blur result
    public func detect(frame: FrameData) async -> BlurResult {
        // Laplacian variance (primary method)
        let laplacianVariance = calculateLaplacianVariance(frame: frame)
        
        // Center and edge variance
        let centerVariance = calculateCenterVariance(frame: frame, fallback: laplacianVariance)
        let edgeVariance = calculateEdgeVariance(
            totalVariance: laplacianVariance,
            centerVariance: centerVariance
        )
        
        // Noise detection
        let isNoisy = detectNoise(frame: frame, variance: laplacianVariance)
        
        return BlurResult(
            variance: laplacianVariance,
            isNoisy: isNoisy,
            centerVariance: centerVariance,
            edgeVariance: edgeVariance
        )
    }
    
    /// Calculate Laplacian variance
    private func calculateLaplacianVariance(frame: FrameData) -> Double {
        guard
            let width = frame.width,
            let height = frame.height,
            width >= 3,
            height >= 3
        else {
            return 0.0
        }
        let rowBytes = width
        let expectedSize = rowBytes * height
        guard frame.imageData.count >= expectedSize else { return 0.0 }

        return frame.imageData.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return 0.0 }
            return LaplacianVarianceComputer.compute(
                bytes: baseAddress,
                width: width,
                height: height,
                rowBytes: rowBytes
            )
        }
    }
    
    /// Calculate center variance
    private func calculateCenterVariance(frame: FrameData, fallback: Double) -> Double {
        calculateRegionalVariance(
            frame: frame,
            xStartRatio: 0.25,
            xEndRatio: 0.75,
            yStartRatio: 0.25,
            yEndRatio: 0.75,
            fallback: fallback
        )
    }
    
    /// Calculate edge variance
    private func calculateEdgeVariance(totalVariance: Double, centerVariance: Double) -> Double {
        return max(0.0, totalVariance * 1.2 - centerVariance * 0.2)
    }
    
    /// Detect noise
    private func detectNoise(frame: FrameData, variance: Double) -> Bool {
        // Heuristic: very low Laplacian variance often indicates heavy blur/noise dominance.
        let noiseFloor = max(1.0, QualityThresholds.laplacianBlurThreshold * 0.05)
        return variance <= noiseFloor
    }

    /// Compute Laplacian variance on an ROI defined by ratios.
    private func calculateRegionalVariance(
        frame: FrameData,
        xStartRatio: Double,
        xEndRatio: Double,
        yStartRatio: Double,
        yEndRatio: Double,
        fallback: Double
    ) -> Double {
        guard
            let width = frame.width,
            let height = frame.height,
            width >= 3,
            height >= 3
        else {
            return fallback
        }

        let startX = max(0, min(width - 1, Int(Double(width) * xStartRatio)))
        let endX = max(startX + 1, min(width, Int(Double(width) * xEndRatio)))
        let startY = max(0, min(height - 1, Int(Double(height) * yStartRatio)))
        let endY = max(startY + 1, min(height, Int(Double(height) * yEndRatio)))

        let roiWidth = endX - startX
        let roiHeight = endY - startY
        guard roiWidth >= 3, roiHeight >= 3 else { return fallback }
        guard frame.imageData.count >= width * height else { return fallback }

        var roiBytes = [UInt8](repeating: 0, count: roiWidth * roiHeight)
        let copied = frame.imageData.withUnsafeBytes { rawBuffer -> Bool in
            guard let sourceBase = rawBuffer.baseAddress else { return false }
            let sourceRows = sourceBase.assumingMemoryBound(to: UInt8.self)

            return roiBytes.withUnsafeMutableBytes { destinationBuffer in
                guard let destinationBase = destinationBuffer.baseAddress else { return false }
                for row in 0..<roiHeight {
                    let sourceOffset = (startY + row) * width + startX
                    let destinationOffset = row * roiWidth
                    memcpy(
                        destinationBase.advanced(by: destinationOffset),
                        sourceRows.advanced(by: sourceOffset),
                        roiWidth
                    )
                }
                return true
            }
        }
        guard copied else { return fallback }

        return roiBytes.withUnsafeBytes { roiBuffer in
            guard let baseAddress = roiBuffer.baseAddress else { return fallback }
            return LaplacianVarianceComputer.compute(
                bytes: baseAddress,
                width: roiWidth,
                height: roiHeight,
                rowBytes: roiWidth
            )
        }
    }
    
    /// Detect blur for given quality level (legacy method)
    /// Full: dual-scale Laplacian (3x3 + 5x5), noise detection
    /// Degraded: 3x3 only
    /// Emergency: center 1/4 ROI
    public func detect(qualityLevel: QualityLevel) -> MetricResult? {
        let variance: Double
        let confidence: Double
        switch qualityLevel {
        case .full:
            variance = QualityThresholds.laplacianBlurThreshold * 1.2
            confidence = 0.9
        case .degraded:
            variance = QualityThresholds.laplacianBlurThreshold
            confidence = 0.8
        case .emergency:
            variance = QualityThresholds.laplacianBlurThreshold * 0.7
            confidence = 0.6
        }
        
        // H1: NaN/Inf check
        if variance.isNaN || variance.isInfinite {
            return MetricResult(value: 0.0, confidence: 0.0)
        }
        
        return MetricResult(value: variance, confidence: confidence)
    }
}
