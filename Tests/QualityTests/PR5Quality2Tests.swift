// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  PR5Quality2Tests.swift
//  Aether3DTests
//
//  PR#5 Quality Pre-check - PR5-QUALITY-2.0 Tests
//

import XCTest
@testable import Aether3DCore

final class PR5Quality2Tests: XCTestCase {
    
    // MARK: - Constants Validation
    
    func testTenengradThreshold() {
        XCTAssertEqual(FrameQualityConstants.TENENGRAD_THRESHOLD, 50.0)
        XCTAssertTrue(FrameQualityConstants.TENENGRAD_THRESHOLD >= 30.0)
        XCTAssertTrue(FrameQualityConstants.TENENGRAD_THRESHOLD <= 80.0)
    }
    
    func testMinOrbFeaturesForSfM() {
        XCTAssertEqual(FrameQualityConstants.MIN_ORB_FEATURES_FOR_SFM, 500)
        XCTAssertTrue(FrameQualityConstants.WARN_ORB_FEATURES_FOR_SFM > FrameQualityConstants.MIN_ORB_FEATURES_FOR_SFM)
        XCTAssertTrue(FrameQualityConstants.OPTIMAL_ORB_FEATURES_FOR_SFM > FrameQualityConstants.WARN_ORB_FEATURES_FOR_SFM)
    }
    
    func testSpecularHighlightThresholds() {
        XCTAssertEqual(FrameQualityConstants.SPECULAR_HIGHLIGHT_MAX_PERCENT, 5.0)
        XCTAssertEqual(FrameQualityConstants.SPECULAR_HIGHLIGHT_WARN_PERCENT, 3.0)
        XCTAssertTrue(FrameQualityConstants.SPECULAR_HIGHLIGHT_WARN_PERCENT < FrameQualityConstants.SPECULAR_HIGHLIGHT_MAX_PERCENT)
    }
    
    func testMotionThresholds() {
        XCTAssertEqual(FrameQualityConstants.MAX_ANGULAR_VELOCITY_DEG_PER_SEC, 30.0)
        XCTAssertEqual(FrameQualityConstants.MOTION_BLUR_RISK_THRESHOLD, 0.6)
        XCTAssertTrue(FrameQualityConstants.WARN_ANGULAR_VELOCITY_DEG_PER_SEC < FrameQualityConstants.MAX_ANGULAR_VELOCITY_DEG_PER_SEC)
    }
    
    func testPhotometricThresholds() {
        XCTAssertEqual(FrameQualityConstants.MAX_LUMINANCE_VARIANCE_FOR_NERF, 0.08)
        XCTAssertEqual(FrameQualityConstants.MAX_LAB_VARIANCE_FOR_NERF, 15.0)
        XCTAssertEqual(FrameQualityConstants.MIN_EXPOSURE_CONSISTENCY_RATIO, 0.85)
    }
    
    func testProfileMultipliers() {
        XCTAssertEqual(FrameQualityConstants.LAPLACIAN_MULTIPLIER_PRO_MACRO, 1.25)
        XCTAssertEqual(FrameQualityConstants.LAPLACIAN_MULTIPLIER_LARGE_SCENE, 0.90)
        XCTAssertEqual(FrameQualityConstants.FEATURE_MULTIPLIER_CINEMATIC, 0.70)
    }
    
    // MARK: - RuleId Validation
    
    func testNewRuleIdsExist() {
        // Ensure all new rule IDs are in the enum
        let newRuleIds: [RuleId] = [
            .TENENGRAD_PASS, .TENENGRAD_FAIL, .TENENGRAD_DEGRADED,
            .SFM_FEATURES_PASS, .SFM_FEATURES_WARN, .SFM_FEATURES_FAIL, .SFM_FEATURES_CLUSTERED,
            .MATERIAL_SPECULAR_DETECTED, .MATERIAL_TRANSPARENT_WARNING, .MATERIAL_TEXTURELESS_WARNING,
            .MOTION_ANGULAR_VELOCITY_EXCEEDED, .MOTION_BLUR_RISK_HIGH,
            .PHOTOMETRIC_LUMINANCE_INCONSISTENT, .PHOTOMETRIC_EXPOSURE_JUMP, .PHOTOMETRIC_LAB_VARIANCE_EXCEEDED,
            .DEPTH_CONFIDENCE_LOW, .DEPTH_VARIANCE_HIGH
        ]
        
        for ruleId in newRuleIds {
            XCTAssertTrue(RuleId.allCases.contains(ruleId), "Missing rule ID: \(ruleId)")
        }
    }
    
    func testRuleIdCount() {
        // Original: 32, New: +17 = 49 total
        XCTAssertGreaterThanOrEqual(RuleId.allCases.count, 49)
    }
    
    // MARK: - Analyzer Tests
    
    func testTenengradDetector() {
        let detector = TenengradDetector()
        
        // Full mode should return result
        let fullResult = detector.detect(qualityLevel: .full)
        XCTAssertNotNil(fullResult)
        XCTAssertEqual(fullResult?.confidence, 0.95)
        
        // Degraded mode should return result with lower confidence
        let degradedResult = detector.detect(qualityLevel: .degraded)
        XCTAssertNotNil(degradedResult)
        XCTAssertEqual(degradedResult?.confidence, 0.85)
        
        // Emergency mode should skip (return nil)
        let emergencyResult = detector.detect(qualityLevel: .emergency)
        XCTAssertNil(emergencyResult)
    }
    
    func testMaterialAnalyzer() {
        let analyzer = MaterialAnalyzer()
        
        let result = analyzer.analyze(qualityLevel: .full)
        XCTAssertLessThanOrEqual(result.specularPercent, 100.0)
        XCTAssertGreaterThanOrEqual(result.specularPercent, 0.0)
        XCTAssertGreaterThan(result.confidence, 0.0)
    }
    
    func testPhotometricConsistencyChecker() {
        let checker = PhotometricConsistencyChecker(windowSize: 5)
        
        // Add consistent frames (very small variation to ensure consistency)
        for _ in 0..<5 {
            checker.update(
                luminance: 128.0,  // Identical luminance
                exposure: 0.01,     // Identical exposure
                lab: LabColor(l: 50.0, a: 0.0, b: 0.0)  // Identical Lab
            )
        }
        
        let result = checker.checkConsistency()
        XCTAssertTrue(result.isConsistent, "Consistent frames should pass")
        XCTAssertEqual(result.confidence, 1.0)
    }
    
    func testPhotometricConsistencyCheckerInconsistent() {
        let checker = PhotometricConsistencyChecker(windowSize: 5)
        
        // Add inconsistent frames (large luminance jumps)
        checker.update(luminance: 50.0, exposure: 0.01, lab: LabColor(l: 30.0, a: 0.0, b: 0.0))
        checker.update(luminance: 200.0, exposure: 0.05, lab: LabColor(l: 80.0, a: 0.0, b: 0.0))
        checker.update(luminance: 100.0, exposure: 0.02, lab: LabColor(l: 50.0, a: 0.0, b: 0.0))
        checker.update(luminance: 180.0, exposure: 0.04, lab: LabColor(l: 70.0, a: 0.0, b: 0.0))
        checker.update(luminance: 60.0, exposure: 0.01, lab: LabColor(l: 35.0, a: 0.0, b: 0.0))
        
        let result = checker.checkConsistency()
        XCTAssertFalse(result.isConsistent, "Inconsistent frames should fail")
    }
    
    // MARK: - Profile-Aware Threshold Tests
    
    func testProfileAwareLaplacianThreshold() {
        let standardThreshold = DecisionPolicy.getEffectiveLaplacianThreshold(for: .standard)
        XCTAssertEqual(standardThreshold, 200.0)
        
        let proMacroThreshold = DecisionPolicy.getEffectiveLaplacianThreshold(for: .proMacro)
        XCTAssertEqual(proMacroThreshold, 250.0)  // 200 × 1.25
        
        let largeSceneThreshold = DecisionPolicy.getEffectiveLaplacianThreshold(for: .largeScene)
        XCTAssertEqual(largeSceneThreshold, 180.0)  // 200 × 0.9
    }
    
    func testProfileAwareFeatureCount() {
        let standardCount = DecisionPolicy.getEffectiveMinFeatureCount(for: .standard)
        XCTAssertEqual(standardCount, 500)
        
        let proMacroCount = DecisionPolicy.getEffectiveMinFeatureCount(for: .proMacro)
        XCTAssertEqual(proMacroCount, 600)  // 500 × 1.2
        
        let cinematicCount = DecisionPolicy.getEffectiveMinFeatureCount(for: .cinematicScene)
        XCTAssertEqual(cinematicCount, 350)  // 500 × 0.7
    }
    
    // MARK: - MetricBundle Tests
    
    func testMetricBundleIncludesNewFields() {
        let bundle = MetricBundle(
            brightness: nil,
            laplacian: nil,
            featureScore: nil,
            motionScore: nil,
            saturation: nil,
            focus: nil,
            tenengrad: MetricResult(value: 60.0, confidence: 0.9, roiCoverageRatio: 1.0),
            material: MaterialResult(
                specularPercent: 2.0,
                transparentPercent: 5.0,
                texturelessPercent: 10.0,
                isNonLambertian: false,
                confidence: 0.95,
                largestSpecularRegion: 200
            ),
            photometric: PhotometricResult(
                luminanceVariance: 0.05,
                labVariance: 10.0,
                exposureConsistency: 0.92,
                isConsistent: true,
                confidence: 1.0
            ),
            angularVelocity: nil,
            depthQuality: nil
        )
        
        XCTAssertNotNil(bundle.tenengrad)
        XCTAssertNotNil(bundle.material)
        XCTAssertNotNil(bundle.photometric)
    }
    
    // MARK: - Cross-Platform Determinism
    
    func testLabColorVarianceIsDeterministic() {
        let colors1 = [
            LabColor(l: 50.0, a: 10.0, b: -5.0),
            LabColor(l: 52.0, a: 8.0, b: -3.0),
            LabColor(l: 48.0, a: 12.0, b: -7.0)
        ]
        
        let colors2 = [
            LabColor(l: 50.0, a: 10.0, b: -5.0),
            LabColor(l: 52.0, a: 8.0, b: -3.0),
            LabColor(l: 48.0, a: 12.0, b: -7.0)
        ]
        
        var buffer1 = RingBuffer<LabColor>(maxCapacity: 10)
        var buffer2 = RingBuffer<LabColor>(maxCapacity: 10)
        
        for color in colors1 { buffer1.append(color) }
        for color in colors2 { buffer2.append(color) }
        
        XCTAssertEqual(buffer1.labVariance(), buffer2.labVariance())
    }
}
