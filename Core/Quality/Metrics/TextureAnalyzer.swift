// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  TextureAnalyzer.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Milestone 2
//  TextureAnalyzer - ORB feature detection with spatial distribution
//

import Foundation

/// TextureResult - result of texture analysis
public struct TextureResult: Codable, Sendable {
    public let rawCount: Int?
    public let spatialSpread: Double?
    public let repetitivePenalty: Double?
    public let score: Double?
    public let confidence: Double
    public let skipped: Bool
    
    public init(rawCount: Int? = nil, spatialSpread: Double? = nil, repetitivePenalty: Double? = nil, score: Double? = nil, confidence: Double, skipped: Bool) {
        self.rawCount = rawCount
        self.spatialSpread = spatialSpread
        self.repetitivePenalty = repetitivePenalty
        self.score = score
        self.confidence = confidence
        self.skipped = skipped
    }
}

/// TextureAnalyzer - ORB feature detection
public final class TextureAnalyzer: @unchecked Sendable {
    private struct FeatureStatistics {
        let count: Int
        let spatialSpread: Double
    }

    // H2: Independent state
    public init() {}
    
    /// Analyze texture for frame
    /// 
    /// - Parameter frame: Frame data
    /// - Returns: Texture result
    public func analyze(frame: FrameData) async -> TextureResult {
        // Analyze feature count, distribution quality, and repetition penalty.
        let featureStats = calculateFeatureStatistics(frame: frame)
        let featureCount = featureStats.count
        let textureEntropy = calculateTextureEntropy(frame: frame)
        let repetitivePenalty = calculateRepetitivePenalty(textureEntropy: textureEntropy)
        let spread = featureStats.spatialSpread

        let normalizedFeature = min(1.0, Double(featureCount) / Double(max(1, QualityThresholds.minFeatureDensity)))
        let normalizedEntropy = min(1.0, textureEntropy / 7.5)
        let fusedScore = max(
            0.0,
            (0.55 * normalizedFeature + 0.25 * normalizedEntropy + 0.20 * spread) * (1.0 - 0.5 * repetitivePenalty)
        )
        let confidence = min(1.0, 0.55 + 0.45 * spread)
        
        return TextureResult(
            rawCount: featureCount,
            spatialSpread: spread,
            repetitivePenalty: repetitivePenalty,
            score: fusedScore,
            confidence: confidence,
            skipped: false
        )
    }
    
    /// Calculate feature count
    /// 
    /// 符合 PR5-02: Research-backed thresholds (MIN_FEATURE_DENSITY: 300)
    private func calculateFeatureCount(frame: FrameData) -> Int {
        return calculateFeatureStatistics(frame: frame).count
    }

    private func calculateFeatureStatistics(frame: FrameData) -> FeatureStatistics {
        guard
            let width = frame.width,
            let height = frame.height,
            width >= 5,
            height >= 5,
            frame.imageData.count >= width * height
        else {
            return FeatureStatistics(count: 0, spatialSpread: 0.0)
        }

        let gridSize = 8
        var activeGrid = [UInt8](repeating: 0, count: gridSize * gridSize)
        var featureCount = 0
        let sampleStride = max(1, min(width, height) / 256)
        let gradientThresholdSq = 28 * 28
        let localContrastThreshold = 18

        frame.imageData.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)

            var y = 2
            while y < height - 2 {
                let row = y * width
                var x = 2
                while x < width - 2 {
                    let centerIdx = row + x
                    let gx = Int(bytes[centerIdx + 1]) - Int(bytes[centerIdx - 1])
                    let gy = Int(bytes[centerIdx + width]) - Int(bytes[centerIdx - width])
                    let gradientSq = gx * gx + gy * gy
                    if gradientSq >= gradientThresholdSq {
                        let p1 = Int(bytes[centerIdx - width - 1])
                        let p2 = Int(bytes[centerIdx - width + 1])
                        let p3 = Int(bytes[centerIdx + width - 1])
                        let p4 = Int(bytes[centerIdx + width + 1])
                        let localMin = min(p1, p2, p3, p4)
                        let localMax = max(p1, p2, p3, p4)
                        if localMax - localMin >= localContrastThreshold {
                            featureCount += 1
                            let gxIndex = min(gridSize - 1, x * gridSize / width)
                            let gyIndex = min(gridSize - 1, y * gridSize / height)
                            activeGrid[gyIndex * gridSize + gxIndex] = 1
                        }
                    }
                    x += sampleStride
                }
                y += sampleStride
            }
        }

        let activeCellCount = activeGrid.reduce(0) { $0 + Int($1) }
        let spread = Double(activeCellCount) / Double(activeGrid.count)
        return FeatureStatistics(count: featureCount, spatialSpread: spread)
    }
    
    /// Calculate texture entropy
    private func calculateTextureEntropy(frame: FrameData) -> Double {
        guard
            let width = frame.width,
            let height = frame.height,
            width > 0,
            height > 0,
            frame.imageData.count >= width * height
        else {
            return 0.0
        }

        let sampleStride = max(1, min(width, height) / 320)
        let binCount = 32
        var histogram = [Int](repeating: 0, count: binCount)
        var sampleCount = 0

        frame.imageData.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)

            var y = 0
            while y < height {
                let rowOffset = y * width
                var x = 0
                while x < width {
                    let luma = Int(bytes[rowOffset + x])
                    let bucket = min(binCount - 1, (luma * binCount) / 256)
                    histogram[bucket] += 1
                    sampleCount += 1
                    x += sampleStride
                }
                y += sampleStride
            }
        }

        guard sampleCount > 0 else { return 0.0 }

        var entropy = 0.0
        for count in histogram where count > 0 {
            let probability = Double(count) / Double(sampleCount)
            entropy -= probability * log2(probability)
        }
        return entropy
    }

    private func calculateRepetitivePenalty(textureEntropy: Double) -> Double {
        let normalizedEntropy = min(1.0, max(0.0, textureEntropy / 7.5))
        return max(0.0, 1.0 - normalizedEntropy)
    }
    
    /// Analyze texture for given quality level (legacy method)
    /// Full: ORB (fastThreshold=20, nLevels=8, scaleFactor=1.2) + spatial distribution + repetitive penalty
    /// Emergency: skip (return nil)
    public func analyze(qualityLevel: QualityLevel) -> MetricResult? {
        // Emergency: skip
        if qualityLevel == .emergency {
            return nil
        }
        
        let score: Double
        let confidence: Double
        switch qualityLevel {
        case .full:
            score = 0.80
            confidence = 0.80
        case .degraded:
            score = 0.65
            confidence = 0.65
        case .emergency:
            return nil
        }
        
        // H1: NaN/Inf check
        if score.isNaN || score.isInfinite {
            return MetricResult(value: 0.0, confidence: 0.0)
        }
        
        return MetricResult(value: score, confidence: confidence)
    }
}
