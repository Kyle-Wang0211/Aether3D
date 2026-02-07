//
// SfMPredictor.swift
// Aether3D
//
// SfM Predictor - SfM success prediction based on quality metrics
//

import Foundation

/// SfM Predictor
///
/// Predicts SfM (Structure from Motion) success based on quality metrics.
public actor SfMPredictor {
    
    /// Predict SfM success
    /// 
    /// 符合 PR5: SfM success prediction based on quality metrics
    /// - Parameter report: Capture quality report
    /// - Returns: Prediction result
    public func predictSuccess(_ report: CaptureQualityReport) -> SfMPrediction {
        // Use research-backed thresholds
        let minAcceptableRatio = 0.75 // Minimum acceptable frame ratio
        let acceptableRatio = Double(report.acceptableFrames) / Double(report.totalFrames)
        
        // Check overall tier
        if report.overallTier == .rejected {
            return SfMPrediction(
                willSucceed: false,
                confidence: 0.9,
                reason: "Too many rejected frames"
            )
        }
        
        // Check acceptable ratio
        if acceptableRatio < minAcceptableRatio {
            return SfMPrediction(
                willSucceed: false,
                confidence: 0.8,
                reason: "Insufficient acceptable frames"
            )
        }
        
        // Check problem segments
        let totalProblemFrames = report.problemSegments.reduce(0) { $0 + ($1.endFrame - $1.startFrame + 1) }
        let problemRatio = Double(totalProblemFrames) / Double(report.totalFrames)
        
        if problemRatio > 0.3 {
            return SfMPrediction(
                willSucceed: false,
                confidence: 0.7,
                reason: "Too many problem segments"
            )
        }
        
        return SfMPrediction(
            willSucceed: true,
            confidence: 0.85,
            reason: "Quality metrics meet requirements"
        )
    }
}

/// SfM Prediction
///
/// Prediction result for SfM success.
public struct SfMPrediction: Sendable {
    public let willSucceed: Bool
    public let confidence: Double
    public let reason: String
    
    public init(willSucceed: Bool, confidence: Double, reason: String) {
        self.willSucceed = willSucceed
        self.confidence = confidence
        self.reason = reason
    }
}
