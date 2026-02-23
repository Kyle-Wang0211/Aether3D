// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

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

/// QualityMetricsFacade - single entry point for quality metrics (PR5-QUALITY-2.0)
/// PART 10.0: Hides internal implementation details
public class QualityMetricsFacade {
    private let brightnessAnalyzer: BrightnessAnalyzer
    private let blurDetector: BlurDetector
    private let exposureAnalyzer: ExposureAnalyzer
    private let textureAnalyzer: TextureAnalyzer
    private let motionAnalyzer: MotionAnalyzer
    private let focusDetector: FocusDetector

    // NEW: PR5-QUALITY-2.0 analyzers
    private let tenengradDetector: TenengradDetector
    private let materialAnalyzer: MaterialAnalyzer
    private let photometricChecker: PhotometricConsistencyChecker

    public init(
        brightnessAnalyzer: BrightnessAnalyzer,
        blurDetector: BlurDetector,
        exposureAnalyzer: ExposureAnalyzer,
        textureAnalyzer: TextureAnalyzer,
        motionAnalyzer: MotionAnalyzer,
        focusDetector: FocusDetector,
        // NEW
        tenengradDetector: TenengradDetector? = nil,
        materialAnalyzer: MaterialAnalyzer? = nil,
        photometricChecker: PhotometricConsistencyChecker? = nil
    ) {
        self.brightnessAnalyzer = brightnessAnalyzer
        self.blurDetector = blurDetector
        self.exposureAnalyzer = exposureAnalyzer
        self.textureAnalyzer = textureAnalyzer
        self.motionAnalyzer = motionAnalyzer
        self.focusDetector = focusDetector
        // NEW
        self.tenengradDetector = tenengradDetector ?? TenengradDetector()
        self.materialAnalyzer = materialAnalyzer ?? MaterialAnalyzer()
        self.photometricChecker = photometricChecker ?? PhotometricConsistencyChecker()
    }

    /// Compute all metrics for given quality level (PR5-QUALITY-2.0)
    /// H2: No shared mutable state across analyzers
    public func computeMetrics(qualityLevel: QualityLevel) -> MetricBundle {
        // Existing metrics
        let brightness = brightnessAnalyzer.analyze(qualityLevel: qualityLevel)
        let laplacian = blurDetector.detect(qualityLevel: qualityLevel)
        let saturation = exposureAnalyzer.analyze(qualityLevel: qualityLevel)
        let texture = textureAnalyzer.analyze(qualityLevel: qualityLevel)
        let motion = motionAnalyzer.analyze(qualityLevel: qualityLevel)
        let focus = focusDetector.detect(qualityLevel: qualityLevel)

        // NEW: PR5-QUALITY-2.0 metrics
        let tenengrad = tenengradDetector.detect(qualityLevel: qualityLevel)
        let material = materialAnalyzer.analyze(qualityLevel: qualityLevel)
        let photometric = photometricChecker.checkConsistency()

        return MetricBundle(
            brightness: brightness,
            laplacian: laplacian,
            featureScore: texture,
            motionScore: motion,
            saturation: saturation,
            focus: focus,
            // NEW
            tenengrad: tenengrad,
            material: material,
            photometric: photometric,
            angularVelocity: nil,  // Computed from motion analyzer internals
            depthQuality: nil      // Computed from depth sensor if available
        )
    }
}
