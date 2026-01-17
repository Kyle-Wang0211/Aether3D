//
//  QualityMetricsFacade.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Milestone 2
//  QualityMetricsFacade - single entry point (PART 10.0)
//

import Foundation

/// QualityLevelAware - protocol for quality level awareness
public protocol QualityLevelAware {
    var qualityLevel: QualityLevel { get }
}

/// QualityMetricsFacade - single entry point for quality metrics
/// PART 10.0: Hides internal implementation details
public class QualityMetricsFacade {
    private let brightnessAnalyzer: BrightnessAnalyzer
    private let blurDetector: BlurDetector
    private let exposureAnalyzer: ExposureAnalyzer
    private let textureAnalyzer: TextureAnalyzer
    private let motionAnalyzer: MotionAnalyzer
    private let focusDetector: FocusDetector
    
    public init(
        brightnessAnalyzer: BrightnessAnalyzer,
        blurDetector: BlurDetector,
        exposureAnalyzer: ExposureAnalyzer,
        textureAnalyzer: TextureAnalyzer,
        motionAnalyzer: MotionAnalyzer,
        focusDetector: FocusDetector
    ) {
        self.brightnessAnalyzer = brightnessAnalyzer
        self.blurDetector = blurDetector
        self.exposureAnalyzer = exposureAnalyzer
        self.textureAnalyzer = textureAnalyzer
        self.motionAnalyzer = motionAnalyzer
        self.focusDetector = focusDetector
    }
    
    /// Compute all metrics for given quality level
    /// H2: No shared mutable state across analyzers
    public func computeMetrics(qualityLevel: QualityLevel) -> MetricBundle {
        let brightness = brightnessAnalyzer.analyze(qualityLevel: qualityLevel)
        let laplacian = blurDetector.detect(qualityLevel: qualityLevel)
        let saturation = exposureAnalyzer.analyze(qualityLevel: qualityLevel)
        let texture = textureAnalyzer.analyze(qualityLevel: qualityLevel)
        let motion = motionAnalyzer.analyze(qualityLevel: qualityLevel)
        let focus = focusDetector.detect(qualityLevel: qualityLevel)
        
        return MetricBundle(
            brightness: brightness,
            laplacian: laplacian,
            featureScore: texture,
            motionScore: motion,
            saturation: saturation,
            focus: focus
        )
    }
}

