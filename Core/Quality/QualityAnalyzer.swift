//
// QualityAnalyzer.swift
// Aether3D
//
// Quality Analyzer - Real-time quality analyzer with multi-metric fusion
// 符合 PR5: Quality Pre-check
//

import Foundation

/// Quality Analyzer
///
/// Real-time quality analyzer with multi-metric fusion.
/// 符合 PR5: Quality Pre-check
public actor QualityAnalyzer {
    
    // MARK: - Components
    
    private let blurDetector: BlurDetector
    private let exposureAnalyzer: ExposureAnalyzer
    private let textureAnalyzer: TextureAnalyzer
    private let motionAnalyzer: MotionAnalyzer
    
    // MARK: - State
    
    private var frameReports: [FrameQualityReport] = []
    private let maxReports: Int = 1000
    
    // MARK: - Initialization
    
    /// Initialize Quality Analyzer
    public init() {
        self.blurDetector = BlurDetector()
        self.exposureAnalyzer = ExposureAnalyzer()
        self.textureAnalyzer = TextureAnalyzer()
        self.motionAnalyzer = MotionAnalyzer()
    }
    
    // MARK: - Analysis
    
    /// Analyze frame quality
    /// 
    /// 符合 PR5: All 9 quality metrics computed per frame
    /// - Parameter frame: Frame data
    /// - Returns: Frame quality report
    public func analyzeFrame(_ frame: FrameData) async -> FrameQualityReport {
        // Analyze blur (multi-method)
        let blurResult = await blurDetector.detect(frame: frame)
        
        // Analyze exposure
        let exposureResult = await exposureAnalyzer.analyze(frame: frame)
        
        // Analyze texture
        let textureResult = await textureAnalyzer.analyze(frame: frame)
        
        // Analyze motion
        let motionResult = await motionAnalyzer.analyze(frame: frame)
        
        // Create report
        let report = FrameQualityReport(
            frameIndex: frame.index,
            timestamp: frame.timestamp,
            blur: blurResult,
            exposure: exposureResult,
            texture: textureResult,
            motion: motionResult,
            qualityTier: calculateQualityTier(blur: blurResult, exposure: exposureResult, texture: textureResult, motion: motionResult)
        )
        
        // Store report
        frameReports.append(report)
        if frameReports.count > maxReports {
            frameReports.removeFirst()
        }
        
        return report
    }
    
    /// Calculate quality tier
    /// 
    /// - Parameters:
    ///   - blur: Blur result
    ///   - exposure: Exposure result
    ///   - texture: Texture result
    ///   - motion: Motion result
    /// - Returns: Quality tier
    private func calculateQualityTier(blur: BlurResult, exposure: SaturationResult, texture: TextureResult, motion: MotionResult) -> QualityTier {
        // Use research-backed thresholds from QualityThresholds
        let blurThreshold = QualityThresholds.laplacianBlurThreshold
        let minFeatureDensity = QualityThresholds.minFeatureDensity
        
        // Check blur
        if blur.variance < blurThreshold {
            return .rejected
        }
        
        // Check feature density (use rawCount if available, otherwise score)
        let featureCount = texture.rawCount ?? Int(texture.score ?? 0)
        if featureCount < minFeatureDensity {
            return .rejected
        }
        
        // Check exposure (use SaturationResult fields)
        if exposure.overexposePct > 0.1 || exposure.underexposePct > 0.1 {
            return .warning
        }
        
        // Check motion
        if motion.isFastPan || motion.isHandShake {
            return .warning
        }
        
        return .acceptable
    }
    
    /// Get capture quality report
    /// 
    /// - Returns: Capture quality report
    public func getCaptureReport() -> CaptureQualityReport {
        let problemSegments = identifyProblemSegments()
        let overallTier = calculateOverallTier()
        
        return CaptureQualityReport(
            totalFrames: frameReports.count,
            acceptableFrames: frameReports.filter { $0.qualityTier == .acceptable }.count,
            warningFrames: frameReports.filter { $0.qualityTier == .warning }.count,
            rejectedFrames: frameReports.filter { $0.qualityTier == .rejected }.count,
            problemSegments: problemSegments,
            overallTier: overallTier
        )
    }
    
    /// Identify problem segments
    /// 
    /// - Returns: Array of problem segments
    private func identifyProblemSegments() -> [ProblemSegment] {
        var segments: [ProblemSegment] = []
        var currentSegmentStart: Int?
        
        for (index, report) in frameReports.enumerated() {
            if report.qualityTier != .acceptable {
                if currentSegmentStart == nil {
                    currentSegmentStart = index
                }
            } else {
                if let start = currentSegmentStart {
                    segments.append(ProblemSegment(
                        startFrame: start,
                        endFrame: index - 1,
                        issue: report.qualityTier == .rejected ? .blur : .warning
                    ))
                    currentSegmentStart = nil
                }
            }
        }
        
        // Handle segment at end
        if let start = currentSegmentStart {
            segments.append(ProblemSegment(
                startFrame: start,
                endFrame: frameReports.count - 1,
                issue: frameReports[start].qualityTier == .rejected ? .blur : .warning
            ))
        }
        
        return segments
    }
    
    /// Calculate overall tier
    /// 
    /// - Returns: Overall quality tier
    private func calculateOverallTier() -> QualityTier {
        let acceptableCount = frameReports.filter { $0.qualityTier == .acceptable }.count
        let totalCount = frameReports.count
        
        guard totalCount > 0 else {
            return .rejected
        }
        
        let acceptableRatio = Double(acceptableCount) / Double(totalCount)
        
        if acceptableRatio >= 0.9 {
            return .acceptable
        } else if acceptableRatio >= 0.7 {
            return .warning
        } else {
            return .rejected
        }
    }
}

/// Frame Data
public struct FrameData: Sendable {
    public let index: Int
    public let timestamp: Date
    public let imageData: Data
    
    public init(index: Int, timestamp: Date, imageData: Data) {
        self.index = index
        self.timestamp = timestamp
        self.imageData = imageData
    }
}
