// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// QualityFeedback.swift
// Aether3D
//
// Quality Feedback - Real-time quality feedback during capture
// 符合 PR5-03: Real-time Quality Feedback
//

import Foundation

/// Quality Feedback
///
/// Provides real-time quality feedback during capture.
/// 符合 PR5-03: Real-time Quality Feedback
public actor QualityFeedback {
    
    // MARK: - State
    
    private var recentReports: [FrameQualityReport] = []
    private let windowSize: Int = 30 // Rolling window (30 frames ≈ 0.5s at 60fps)
    
    // MARK: - Callbacks
    
    /// Callback for quality updates
    public var onQualityUpdate: ((QualityFeedbackUpdate) -> Void)?
    
    // MARK: - Feedback
    
    /// Add frame report and generate feedback
    /// 
    /// - Parameter report: Frame quality report
    public func addFrameReport(_ report: FrameQualityReport) {
        recentReports.append(report)
        
        // Keep only recent reports
        if recentReports.count > windowSize {
            recentReports.removeFirst()
        }
        
        // Generate feedback
        let update = generateFeedback()
        onQualityUpdate?(update)
    }
    
    /// Generate feedback from recent reports
    /// 
    /// - Returns: Quality feedback update
    private func generateFeedback() -> QualityFeedbackUpdate {
        guard !recentReports.isEmpty else {
            return QualityFeedbackUpdate(
                averageBlur: 0.0,
                averageExposure: 0.0,
                averageTexture: 0.0,
                averageMotion: 0.0,
                qualityTier: .acceptable,
                warnings: []
            )
        }
        
        // Calculate averages
        let avgBlur = recentReports.map { $0.blur.variance }.reduce(0.0, +) / Double(recentReports.count)
        let avgExposure = recentReports.map { $0.exposure.overexposePct + $0.exposure.underexposePct }.reduce(0.0, +) / Double(recentReports.count)
        // Use rawCount if available, otherwise derive from score (multiplied by a reasonable scale factor)
        let avgTexture = recentReports.map { report -> Double in
            if let rawCount = report.texture.rawCount {
                return Double(rawCount)
            } else if let score = report.texture.score {
                // Scale score (0-1 range) to approximate feature count (0-500 range)
                return score * 500.0
            }
            return 0.0  // Fallback for skipped frames
        }.reduce(0.0, +) / Double(recentReports.count)
        let avgMotion = recentReports.map { $0.motion.score }.reduce(0.0, +) / Double(recentReports.count)
        
        // Determine overall tier
        let rejectedCount = recentReports.filter { $0.qualityTier == .rejected }.count
        let warningCount = recentReports.filter { $0.qualityTier == .warning }.count
        
        let qualityTier: QualityTier
        if Double(rejectedCount) / Double(recentReports.count) > 0.1 {
            qualityTier = .rejected
        } else if Double(warningCount) / Double(recentReports.count) > 0.2 {
            qualityTier = .warning
        } else {
            qualityTier = .acceptable
        }
        
        // Generate warnings
        var warnings: [String] = []
        if avgBlur < QualityThresholds.laplacianBlurThreshold {
            warnings.append("Blur detected - slow down movement")
        }
        if avgExposure > 0.1 {
            warnings.append("Exposure issues detected")
        }
        if avgTexture < Double(QualityThresholds.minFeatureDensity) {
            warnings.append("Low texture detail - move closer to subject")
        }
        if avgMotion > 0.7 {
            warnings.append("Excessive motion detected")
        }
        
        return QualityFeedbackUpdate(
            averageBlur: avgBlur,
            averageExposure: avgExposure,
            averageTexture: avgTexture,
            averageMotion: avgMotion,
            qualityTier: qualityTier,
            warnings: warnings
        )
    }
    
    /// Clear feedback
    public func clear() {
        recentReports.removeAll()
    }
}

/// Quality Feedback Update
///
/// Update message for quality feedback.
public struct QualityFeedbackUpdate: Sendable {
    public let averageBlur: Double
    public let averageExposure: Double
    public let averageTexture: Double
    public let averageMotion: Double
    public let qualityTier: QualityTier
    public let warnings: [String]
    
    public init(averageBlur: Double, averageExposure: Double, averageTexture: Double, averageMotion: Double, qualityTier: QualityTier, warnings: [String]) {
        self.averageBlur = averageBlur
        self.averageExposure = averageExposure
        self.averageTexture = averageTexture
        self.averageMotion = averageMotion
        self.qualityTier = qualityTier
        self.warnings = warnings
    }
}
