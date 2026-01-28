//
// SafeRatioContractTests.swift
// Aether3D
//
// PR#1 SSOT Foundation v1.1 - SafeRatio Contract Tests
//
// This test file validates SafeRatio contract compliance.
//

import XCTest
@testable import Aether3DCore

/// Tests for SafeRatio contract.
///
/// **Rule ID:** MATH_SAFE_001, MATH_SAFE_001A
/// **Status:** IMMUTABLE
final class SafeRatioContractTests: XCTestCase {
    
    func test_safeRatio_denominatorZero_setsEdgeCase() {
        let result = SafeRatio(numerator: 10.0, denominator: 0.0)
        XCTAssertEqual(result.clampedValue, 0.0)
        XCTAssertTrue(result.edgeCasesTriggered.contains(.EMPTY_GEOMETRY))
        XCTAssertFalse(result.clampTriggered)
    }
    
    func test_safeRatio_nanInf_input_defense() {
        let nanResult = SafeRatio(numerator: Double.nan, denominator: 1.0)
        XCTAssertTrue(nanResult.edgeCasesTriggered.contains(.NAN_OR_INF_DETECTED))
        
        let infResult = SafeRatio(numerator: Double.infinity, denominator: 1.0)
        XCTAssertTrue(infResult.edgeCasesTriggered.contains(.NAN_OR_INF_DETECTED))
    }
    
    func test_safeRatio_negative_input_strategy() {
        let result = SafeRatio(numerator: -10.0, denominator: 100.0)
        XCTAssertEqual(result.clampedValue, 0.0)
        XCTAssertTrue(result.edgeCasesTriggered.contains(.NEGATIVE_INPUT))
    }
    
    func test_safeRatio_auditField_consistency() {
        // When clamp triggered, rawValue must exist
        let clampedResult = SafeRatio(numerator: 150.0, denominator: 100.0)
        XCTAssertTrue(clampedResult.clampTriggered)
        XCTAssertNotNil(clampedResult.rawValue)
        
        // When edge case triggered, rawValue must exist
        let edgeCaseResult = SafeRatio(numerator: -10.0, denominator: 100.0)
        XCTAssertFalse(edgeCaseResult.edgeCasesTriggered.isEmpty)
        XCTAssertNotNil(edgeCaseResult.rawValue)
        
        // When no clamp/edgecase, rawValue must be nil
        let normalResult = SafeRatio(numerator: 50.0, denominator: 100.0)
        XCTAssertFalse(normalResult.clampTriggered)
        XCTAssertTrue(normalResult.edgeCasesTriggered.isEmpty)
        XCTAssertNil(normalResult.rawValue)
    }
    
    func test_rawWeightedScore_mayExceedOne_but_ratioClamped() {
        // Raw score can exceed 1.0, but clamped value must be <= 1.0
        let result = SafeRatio(numerator: 150.0, denominator: 100.0)
        XCTAssertEqual(result.clampedValue, 1.0)
        XCTAssertEqual(result.rawValue, 1.5)
    }
}
