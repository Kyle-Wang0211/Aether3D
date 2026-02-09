//
// ScanGuidanceConstantsTests.swift
// Aether3D
//
// PR#7 Scan Guidance UI — Constants Tests
//

import XCTest
@testable import Aether3DCore

final class ScanGuidanceConstantsTests: XCTestCase {
    
    func testAllSpecsRegistered() {
        // Verify all specs are registered (65 total - 2 Bool constants = 63, but actually 65 are registered)
        // Note: According to the implementation, 65 specs are registered (all Double/Int constants)
        // The 2 Bool constants (reduceMotionDisablesFlip, reduceMotionDisablesRipple) are NOT registered
        // So total registered = 65 (all non-Bool constants)
        XCTAssertEqual(ScanGuidanceConstants.allSpecs.count, 65, "Should have 65 registered specs (all Double/Int constants, Bool excluded)")
    }
    
    func testSSOTRegistration() {
        // Verify all specs are in SSOTRegistry
        let registrySpecs = SSOTRegistry.allConstantSpecs
        let scanGuidanceSpecIds = Set(ScanGuidanceConstants.allSpecs.map { $0.ssotId })
        let registrySpecIds = Set(registrySpecs.map { $0.ssotId })
        
        for specId in scanGuidanceSpecIds {
            XCTAssertTrue(registrySpecIds.contains(specId), "Spec \(specId) should be registered in SSOTRegistry")
        }
    }
    
    func testValidateRelationships() {
        // Verify validateRelationships returns empty array
        let errors = ScanGuidanceConstants.validateRelationships()
        XCTAssertTrue(errors.isEmpty, "validateRelationships should return empty array, got: \(errors)")
    }
    
    func testHapticBlurThresholdMatchesQualityThresholds() {
        // Verify hapticBlurThreshold equals QualityThresholds.laplacianBlurThreshold
        XCTAssertEqual(
            ScanGuidanceConstants.hapticBlurThreshold,
            QualityThresholds.laplacianBlurThreshold,
            "hapticBlurThreshold must equal QualityThresholds.laplacianBlurThreshold"
        )
    }
    
    func testSThresholdsMonotonic() {
        // Verify S-thresholds are strictly increasing
        let thresholds = [
            ScanGuidanceConstants.s0ToS1Threshold,
            ScanGuidanceConstants.s1ToS2Threshold,
            ScanGuidanceConstants.s2ToS3Threshold,
            ScanGuidanceConstants.s3ToS4Threshold,
            ScanGuidanceConstants.s4ToS5Threshold
        ]
        
        for i in 1..<thresholds.count {
            XCTAssertGreaterThan(
                thresholds[i],
                thresholds[i-1],
                "S-thresholds must be strictly increasing at index \(i)"
            )
        }
    }
    
    func testBorderWidthRange() {
        // Verify border width constants are in valid range
        XCTAssertLessThan(
            ScanGuidanceConstants.borderMinWidthPx,
            ScanGuidanceConstants.borderBaseWidthPx,
            "borderMinWidthPx should be less than borderBaseWidthPx"
        )
        XCTAssertLessThan(
            ScanGuidanceConstants.borderBaseWidthPx,
            ScanGuidanceConstants.borderMaxWidthPx,
            "borderBaseWidthPx should be less than borderMaxWidthPx"
        )
    }
    
    func testWedgeThicknessRange() {
        // Verify wedge thickness constants are in valid range
        XCTAssertLessThan(
            ScanGuidanceConstants.wedgeMinThicknessM,
            ScanGuidanceConstants.wedgeBaseThicknessM,
            "wedgeMinThicknessM should be less than wedgeBaseThicknessM"
        )
    }
    
    func testBorderWeightsSumToOne() {
        // Verify border weights sum to approximately 1.0
        let sum = ScanGuidanceConstants.borderDisplayWeight + ScanGuidanceConstants.borderAreaWeight
        XCTAssertEqual(sum, 1.0, accuracy: 0.01, "borderDisplayWeight + borderAreaWeight should equal 1.0")
    }
}
