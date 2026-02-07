//
// QualityReport.swift
// Aether3D
//
// Quality Report - Report structures for quality analysis
//

import Foundation

/// Frame Quality Report
///
/// Quality report for a single frame.
public struct FrameQualityReport: Sendable {
    public let frameIndex: Int
    public let timestamp: Date
    public let blur: BlurResult
    public let exposure: SaturationResult
    public let texture: TextureResult
    public let motion: MotionResult
    public let qualityTier: QualityTier
    
    public init(frameIndex: Int, timestamp: Date, blur: BlurResult, exposure: SaturationResult, texture: TextureResult, motion: MotionResult, qualityTier: QualityTier) {
        self.frameIndex = frameIndex
        self.timestamp = timestamp
        self.blur = blur
        self.exposure = exposure
        self.texture = texture
        self.motion = motion
        self.qualityTier = qualityTier
    }
}

/// Capture Quality Report
///
/// Overall quality report for a capture session.
public struct CaptureQualityReport: Sendable {
    public let totalFrames: Int
    public let acceptableFrames: Int
    public let warningFrames: Int
    public let rejectedFrames: Int
    public let problemSegments: [ProblemSegment]
    public let overallTier: QualityTier
    
    public init(totalFrames: Int, acceptableFrames: Int, warningFrames: Int, rejectedFrames: Int, problemSegments: [ProblemSegment], overallTier: QualityTier) {
        self.totalFrames = totalFrames
        self.acceptableFrames = acceptableFrames
        self.warningFrames = warningFrames
        self.rejectedFrames = rejectedFrames
        self.problemSegments = problemSegments
        self.overallTier = overallTier
    }
}

/// Problem Segment
///
/// Identifies a problematic segment in the capture.
public struct ProblemSegment: Sendable {
    public let startFrame: Int
    public let endFrame: Int
    public let issue: QualityIssue
    
    public init(startFrame: Int, endFrame: Int, issue: QualityIssue) {
        self.startFrame = startFrame
        self.endFrame = endFrame
        self.issue = issue
    }
}

/// Quality Issue
///
/// Type of quality issue.
public enum QualityIssue: String, Sendable {
    case blur
    case exposure
    case texture
    case motion
    case warning
}

/// Quality Tier
///
/// Quality tier classification.
public enum QualityTier: String, Sendable {
    case acceptable
    case warning
    case rejected
}

// BlurResult, ExposureResult, TextureResult, MotionResult are defined in their respective analyzer files
