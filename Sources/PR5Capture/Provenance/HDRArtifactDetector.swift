// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// HDRArtifactDetector.swift
// PR5Capture
//
// PR5 v1.8.1 - PART A: Raw 溯源和 ISP 真实性
// HDR 伪亮度检测，色调映射伪影识别
//

import Foundation

/// HDR artifact detector
///
/// Detects HDR pseudo-brightness and tone mapping artifacts.
/// Identifies artifacts from HDR synthesis that could affect quality metrics.
public actor HDRArtifactDetector {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - State
    
    /// Artifact detection history
    private var detectionHistory: [(timestamp: Date, score: Double, hasArtifacts: Bool)] = []
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Artifact Detection
    
    /// Detect HDR artifacts in image data
    ///
    /// Analyzes pixel value distributions and gradients to detect tone mapping artifacts
    public func detectArtifacts(
        pixelValues: [Double],
        metadata: [String: Any]
    ) -> HDRArtifactDetectionResult {
        // Check if HDR is enabled
        let isHDR = metadata["isHDR"] as? Bool ?? false
        
        if !isHDR {
            return HDRArtifactDetectionResult(
                isHDR: false,
                artifactScore: 0.0,
                hasArtifacts: false,
                threshold: 0.0
            )
        }
        
        // Analyze for pseudo-brightness
        let pseudoBrightnessScore = analyzePseudoBrightness(pixelValues)
        
        // Analyze for tone mapping artifacts
        let toneMappingScore = analyzeToneMappingArtifacts(pixelValues)
        
        // Combined artifact score
        let artifactScore = max(pseudoBrightnessScore, toneMappingScore)
        
        // Get threshold from config
        let threshold = PR5CaptureConstants.getValue(
            PR5CaptureConstants.Provenance.hdrArtifactThreshold,
            profile: config.profile
        )
        
        let hasArtifacts = artifactScore >= threshold
        
        // Record detection
        detectionHistory.append((timestamp: Date(), score: artifactScore, hasArtifacts: hasArtifacts))
        
        return HDRArtifactDetectionResult(
            isHDR: true,
            artifactScore: artifactScore,
            hasArtifacts: hasArtifacts,
            threshold: threshold,
            pseudoBrightnessScore: pseudoBrightnessScore,
            toneMappingScore: toneMappingScore
        )
    }
    
    /// Analyze pseudo-brightness from HDR synthesis
    private func analyzePseudoBrightness(_ pixelValues: [Double]) -> Double {
        guard !pixelValues.isEmpty else { return 0.0 }
        
        // Check for unnatural brightness distribution
        let mean = pixelValues.reduce(0.0, +) / Double(pixelValues.count)
        let variance = pixelValues.map { pow($0 - mean, 2) }.reduce(0.0, +) / Double(pixelValues.count)
        
        // High variance with high mean indicates potential pseudo-brightness
        let score = min(1.0, (mean * variance) / 0.25)
        
        return score
    }
    
    /// Analyze tone mapping artifacts
    private func analyzeToneMappingArtifacts(_ pixelValues: [Double]) -> Double {
        guard pixelValues.count >= 2 else { return 0.0 }
        
        // Check for unnatural gradients (hallmarks of tone mapping)
        var gradientSum = 0.0
        for i in 1..<pixelValues.count {
            let gradient = abs(pixelValues[i] - pixelValues[i-1])
            gradientSum += gradient
        }
        
        let avgGradient = gradientSum / Double(pixelValues.count - 1)
        
        // High average gradient with specific patterns indicates tone mapping artifacts
        let score = min(1.0, avgGradient * 2.0)
        
        return score
    }
    
    // MARK: - Detection History
    
    /// Get detection history
    public func getDetectionHistory() -> [(timestamp: Date, score: Double, hasArtifacts: Bool)] {
        return detectionHistory
    }
    
    // MARK: - Result Types
    
    /// HDR artifact detection result
    public struct HDRArtifactDetectionResult: Sendable {
        public let isHDR: Bool
        public let artifactScore: Double
        public let hasArtifacts: Bool
        public let threshold: Double
        public let pseudoBrightnessScore: Double?
        public let toneMappingScore: Double?
        
        public init(
            isHDR: Bool,
            artifactScore: Double,
            hasArtifacts: Bool,
            threshold: Double,
            pseudoBrightnessScore: Double? = nil,
            toneMappingScore: Double? = nil
        ) {
            self.isHDR = isHDR
            self.artifactScore = artifactScore
            self.hasArtifacts = hasArtifacts
            self.threshold = threshold
            self.pseudoBrightnessScore = pseudoBrightnessScore
            self.toneMappingScore = toneMappingScore
        }
    }
}
