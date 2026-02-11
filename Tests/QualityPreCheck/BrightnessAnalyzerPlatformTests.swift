// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  BrightnessAnalyzerPlatformTests.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Cross-platform BrightnessAnalyzer Tests
//  Validates BrightnessAnalyzer works on all platforms (with/without Accelerate)
//

import XCTest
@testable import Aether3DCore

final class BrightnessAnalyzerPlatformTests: XCTestCase {
    
    /// Test BrightnessAnalyzer initialization (works on all platforms)
    func testBrightnessAnalyzerInitialization() throws {
        let analyzer = BrightnessAnalyzer()
        XCTAssertNotNil(analyzer, "BrightnessAnalyzer should initialize successfully")
    }
    
    /// Test analyze method returns valid result (works on all platforms)
    func testAnalyzeReturnsValidResult() throws {
        let analyzer = BrightnessAnalyzer()
        
        // Test with Full tier
        let resultFull = analyzer.analyze(qualityLevel: .full)
        XCTAssertNotNil(resultFull, "Analyze should return a result for Full tier")
        if let result = resultFull {
            XCTAssertFalse(result.value.isNaN, "Result value must not be NaN")
            XCTAssertFalse(result.value.isInfinite, "Result value must not be Infinite")
            XCTAssertGreaterThanOrEqual(result.confidence, 0.0, "Confidence must be >= 0")
            XCTAssertLessThanOrEqual(result.confidence, 1.0, "Confidence must be <= 1")
        }
        
        // Test with Degraded tier
        let resultDegraded = analyzer.analyze(qualityLevel: .degraded)
        XCTAssertNotNil(resultDegraded, "Analyze should return a result for Degraded tier")
        if let result = resultDegraded {
            XCTAssertFalse(result.value.isNaN, "Result value must not be NaN")
            XCTAssertFalse(result.value.isInfinite, "Result value must not be Infinite")
        }
        
        // Test with Emergency tier
        let resultEmergency = analyzer.analyze(qualityLevel: .emergency)
        XCTAssertNotNil(resultEmergency, "Analyze should return a result for Emergency tier")
        if let result = resultEmergency {
            XCTAssertFalse(result.value.isNaN, "Result value must not be NaN")
            XCTAssertFalse(result.value.isInfinite, "Result value must not be Infinite")
        }
    }
    
    /// Test deterministic output: same input produces same output (works on all platforms)
    func testDeterministicOutput() throws {
        let analyzer = BrightnessAnalyzer()
        
        // Run analyze multiple times with same input
        let result1 = analyzer.analyze(qualityLevel: .full)
        let result2 = analyzer.analyze(qualityLevel: .full)
        let result3 = analyzer.analyze(qualityLevel: .full)
        
        // All results should be non-nil
        XCTAssertNotNil(result1)
        XCTAssertNotNil(result2)
        XCTAssertNotNil(result3)
        
        if let r1 = result1, let r2 = result2, let r3 = result3 {
            // Values should be identical (deterministic)
            XCTAssertEqual(r1.value, r2.value, accuracy: 0.000001, "Results must be deterministic")
            XCTAssertEqual(r2.value, r3.value, accuracy: 0.000001, "Results must be deterministic")
            XCTAssertEqual(r1.confidence, r2.confidence, accuracy: 0.000001, "Confidence must be deterministic")
            XCTAssertEqual(r2.confidence, r3.confidence, accuracy: 0.000001, "Confidence must be deterministic")
        }
    }
    
    /// Test NaN/Inf handling (works on all platforms)
    func testNaNInfHandling() throws {
        let analyzer = BrightnessAnalyzer()
        
        // The analyzer should handle NaN/Inf gracefully
        // Current implementation returns MetricResult(value: 0.0, confidence: 0.0) for NaN/Inf
        let result = analyzer.analyze(qualityLevel: .full)
        XCTAssertNotNil(result, "Analyzer should return a result even if internal calculations produce NaN/Inf")
        
        if let r = result {
            XCTAssertFalse(r.value.isNaN, "Result value must never be NaN")
            XCTAssertFalse(r.value.isInfinite, "Result value must never be Infinite")
            XCTAssertFalse(r.confidence.isNaN, "Confidence must never be NaN")
            XCTAssertFalse(r.confidence.isInfinite, "Confidence must never be Infinite")
        }
    }
    
    /// Test all quality levels produce valid results (works on all platforms)
    func testAllQualityLevels() throws {
        let analyzer = BrightnessAnalyzer()
        
        let qualityLevels: [QualityLevel] = [.full, .degraded, .emergency]
        
        for level in qualityLevels {
            let result = analyzer.analyze(qualityLevel: level)
            XCTAssertNotNil(result, "Analyze should return a result for \(level)")
            
            if let r = result {
                XCTAssertFalse(r.value.isNaN, "Result value must not be NaN for \(level)")
                XCTAssertFalse(r.value.isInfinite, "Result value must not be Infinite for \(level)")
                XCTAssertGreaterThanOrEqual(r.value, 0.0, "Result value should be >= 0 for \(level)")
                XCTAssertLessThanOrEqual(r.value, 1.0, "Result value should be <= 1 for \(level)")
            }
        }
    }
    
    #if canImport(Accelerate)
    /// Test that Accelerate path compiles on Apple platforms
    /// This test only compiles on Apple platforms where Accelerate is available
    func testAcceleratePathCompiles() throws {
        // Verify the module compiles with Accelerate available
        // The actual Accelerate usage would be in BrightnessAnalyzer implementation
        let analyzer = BrightnessAnalyzer()
        let result = analyzer.analyze(qualityLevel: .full)
        XCTAssertNotNil(result, "Analyzer should work with Accelerate available")
    }
    #else
    /// Test that analyzer compiles without Accelerate on non-Apple platforms
    func testNoAccelerateCompilation() throws {
        // On Linux/non-Apple platforms, BrightnessAnalyzer should compile without Accelerate
        let analyzer = BrightnessAnalyzer()
        let result = analyzer.analyze(qualityLevel: .full)
        XCTAssertNotNil(result, "Analyzer should work without Accelerate")
    }
    #endif
}

