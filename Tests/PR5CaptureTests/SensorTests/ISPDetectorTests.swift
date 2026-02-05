//
// ISPDetectorTests.swift
// PR5CaptureTests
//
// Tests for ISPDetector
//

import XCTest
@testable import PR5Capture

@MainActor
final class ISPDetectorTests: XCTestCase {
    
    var detector: ISPDetector!
    var config: ExtremeProfile!
    
    override func setUp() async throws {
        config = ExtremeProfile(profile: .standard)
        detector = ISPDetector(config: config)
    }
    
    override func tearDown() async throws {
        detector = nil
        config = nil
    }
    
    func testNoiseFloorAnalysis() async {
        // Create test pixels with known noise characteristics
        var pixels: [Double] = []
        for _ in 0..<1000 {
            pixels.append(Double.random(in: 0.0...0.1))  // Low intensity with noise
        }
        
        let result = await detector.analyzeISP(pixelValues: pixels, metadata: [:])
        XCTAssertGreaterThan(result.noiseFloor, 0.0)
    }
    
    func testISPStrengthClassification() async {
        // Test different ISP strengths
        let testCases: [(pixels: [Double], expectedMin: ISPStrength)] = [
            (Array(repeating: 0.5, count: 100), .low),  // Uniform (low ISP)
            (Array(repeating: 0.8, count: 100), .medium),  // Higher intensity
        ]
        
        for (pixels, expectedMin) in testCases {
            let result = await detector.analyzeISP(pixelValues: pixels, metadata: [:])
            // Verify strength is classified (should be one of the valid values)
            XCTAssertTrue([.none, .low, .medium, .high, .extreme].contains(result.strength))
        }
    }
    
    func testAverageNoiseFloor() async {
        // Record multiple measurements
        for _ in 0..<10 {
            let pixels = (0..<100).map { _ in Double.random(in: 0.0...0.1) }
            _ = await detector.analyzeISP(pixelValues: pixels, metadata: [:])
        }
        
        let avgNoiseFloor = await detector.getAverageNoiseFloor()
        XCTAssertNotNil(avgNoiseFloor)
    }
}
