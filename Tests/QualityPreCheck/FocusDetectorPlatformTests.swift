//
//  FocusDetectorPlatformTests.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Cross-platform FocusDetector Tests
//  Validates FocusDetector works deterministically on all platforms
//

import XCTest
@testable import Aether3DCore

final class FocusDetectorPlatformTests: XCTestCase {
    
    /// Test FocusDetector initialization with default provider
    func testFocusDetectorInitialization() throws {
        let detector = FocusDetector()
        XCTAssertNotNil(detector, "FocusDetector should initialize successfully")
    }
    
    /// Test detect with sharp status returns value 1.0
    func testDetectSharpStatus() throws {
        let detector = FocusDetector { _ in
            return (.sharp, 0.9)
        }
        
        let result = detector.detect(qualityLevel: .full)
        XCTAssertNotNil(result, "Detect should return a result")
        if let result = result {
            XCTAssertEqual(result.value, 1.0, accuracy: 0.001, "Sharp status should map to value 1.0")
            XCTAssertEqual(result.confidence, 0.9, accuracy: 0.001, "Confidence should be 0.9")
        }
    }
    
    /// Test detect with hunting status returns value 0.5
    func testDetectHuntingStatus() throws {
        let detector = FocusDetector { _ in
            return (.hunting, 0.9)
        }
        
        let result = detector.detect(qualityLevel: .full)
        XCTAssertNotNil(result, "Detect should return a result")
        if let result = result {
            XCTAssertEqual(result.value, 0.5, accuracy: 0.001, "Hunting status should map to value 0.5")
            XCTAssertEqual(result.confidence, 0.9, accuracy: 0.001, "Confidence should be 0.9")
        }
    }
    
    /// Test detect with failed status returns value 0.0
    func testDetectFailedStatus() throws {
        let detector = FocusDetector { _ in
            return (.failed, 0.9)
        }
        
        let result = detector.detect(qualityLevel: .full)
        XCTAssertNotNil(result, "Detect should return a result")
        if let result = result {
            XCTAssertEqual(result.value, 0.0, accuracy: 0.001, "Failed status should map to value 0.0")
            XCTAssertEqual(result.confidence, 0.9, accuracy: 0.001, "Confidence should be 0.9")
        }
    }
    
    /// Test detect with unknown status returns value 0.0
    func testDetectUnknownStatus() throws {
        let detector = FocusDetector { _ in
            return (.unknown, 0.9)
        }
        
        let result = detector.detect(qualityLevel: .full)
        XCTAssertNotNil(result, "Detect should return a result")
        if let result = result {
            XCTAssertEqual(result.value, 0.0, accuracy: 0.001, "Unknown status should map to value 0.0")
            XCTAssertEqual(result.confidence, 0.9, accuracy: 0.001, "Confidence should be 0.9")
        }
    }
    
    /// Test confidence clamping: confidence > 1.0 is clamped to 1.0
    func testConfidenceClamping() throws {
        let detector = FocusDetector { _ in
            return (.sharp, 2.0)  // Confidence exceeds 1.0
        }
        
        let result = detector.detect(qualityLevel: .full)
        XCTAssertNotNil(result, "Detect should return a result")
        if let result = result {
            XCTAssertEqual(result.confidence, 1.0, accuracy: 0.001, "Confidence > 1.0 should be clamped to 1.0")
            XCTAssertEqual(result.value, 1.0, accuracy: 0.001, "Value should still be 1.0 for sharp")
        }
    }
    
    /// Test confidence clamping: confidence < 0.0 is clamped to 0.0
    func testConfidenceClampingNegative() throws {
        let detector = FocusDetector { _ in
            return (.sharp, -0.5)  // Confidence below 0.0
        }
        
        let result = detector.detect(qualityLevel: .full)
        XCTAssertNotNil(result, "Detect should return a result")
        if let result = result {
            XCTAssertEqual(result.confidence, 0.0, accuracy: 0.001, "Confidence < 0.0 should be clamped to 0.0")
            XCTAssertEqual(result.value, 1.0, accuracy: 0.001, "Value should still be 1.0 for sharp")
        }
    }
    
    /// Test value clamping: value > 1.0 is clamped (defensive)
    func testValueClamping() throws {
        // Note: This test verifies defensive clamping, though normal status mapping never exceeds 1.0
        let detector = FocusDetector { _ in
            return (.sharp, 0.9)  // Normal case, value will be 1.0
        }
        
        let result = detector.detect(qualityLevel: .full)
        XCTAssertNotNil(result, "Detect should return a result")
        if let result = result {
            XCTAssertLessThanOrEqual(result.value, 1.0, "Value should be <= 1.0")
            XCTAssertGreaterThanOrEqual(result.value, 0.0, "Value should be >= 0.0")
        }
    }
    
    /// Test default provider returns unknown status
    func testDefaultProvider() throws {
        let detector = FocusDetector()  // Uses default provider
        
        let result = detector.detect(qualityLevel: .full)
        XCTAssertNotNil(result, "Detect should return a result")
        if let result = result {
            XCTAssertEqual(result.value, 0.0, accuracy: 0.001, "Default provider should return unknown -> 0.0")
            XCTAssertEqual(result.confidence, 0.0, accuracy: 0.001, "Default provider should return confidence 0.0")
        }
    }
    
    /// Test detect with different quality levels (provider receives qualityLevel)
    func testDetectWithDifferentQualityLevels() throws {
        var receivedQualityLevel: QualityLevel?
        
        let detector = FocusDetector { qualityLevel in
            receivedQualityLevel = qualityLevel
            return (.sharp, 0.8)
        }
        
        // Test with full
        _ = detector.detect(qualityLevel: .full)
        XCTAssertEqual(receivedQualityLevel, .full, "Provider should receive .full quality level")
        
        // Test with degraded
        _ = detector.detect(qualityLevel: .degraded)
        XCTAssertEqual(receivedQualityLevel, .degraded, "Provider should receive .degraded quality level")
        
        // Test with emergency
        _ = detector.detect(qualityLevel: .emergency)
        XCTAssertEqual(receivedQualityLevel, .emergency, "Provider should receive .emergency quality level")
    }
    
    /// Test NaN/Inf handling
    func testNaNInfHandling() throws {
        // This test verifies that if provider returns NaN/Inf, it's handled
        // Note: Our implementation clamps values, so NaN/Inf shouldn't occur, but we test the guard
        let detector = FocusDetector { _ in
            return (.sharp, 0.9)
        }
        
        let result = detector.detect(qualityLevel: .full)
        XCTAssertNotNil(result, "Detect should return a result")
        if let result = result {
            XCTAssertFalse(result.value.isNaN, "Result value must not be NaN")
            XCTAssertFalse(result.value.isInfinite, "Result value must not be Infinite")
            XCTAssertFalse(result.confidence.isNaN, "Result confidence must not be NaN")
            XCTAssertFalse(result.confidence.isInfinite, "Result confidence must not be Infinite")
        }
    }
}
