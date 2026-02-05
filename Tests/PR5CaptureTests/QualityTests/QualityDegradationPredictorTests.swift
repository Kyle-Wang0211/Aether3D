//
// QualityDegradationPredictorTests.swift
// PR5CaptureTests
//
// Tests for QualityDegradationPredictor
//

import XCTest
@testable import PR5Capture

@MainActor
final class QualityDegradationPredictorTests: XCTestCase {
    
    var predictor: QualityDegradationPredictor!
    var config: ExtremeProfile!
    
    override func setUp() async throws {
        config = ExtremeProfile(profile: .standard)
        predictor = QualityDegradationPredictor(config: config)
    }
    
    override func tearDown() async throws {
        predictor = nil
        config = nil
    }
    
    func testDegradationPrediction() async {
        // Record improving quality
        for i in 0..<5 {
            _ = await predictor.predictDegradation(0.6 + Double(i) * 0.05)
        }
        
        let prediction = await predictor.predictDegradation(0.85)
        XCTAssertGreaterThan(prediction.predictedQuality, 0.0)
    }
    
    func testWarningGeneration() async {
        // Record degrading quality
        for i in 0..<5 {
            _ = await predictor.predictDegradation(0.8 - Double(i) * 0.1)
        }
        
        let prediction = await predictor.predictDegradation(0.3)
        // May generate warning if risk is high
        XCTAssertNotNil(prediction.warning)
    }
}
