//
// AdaptiveBorderTests.swift
// Aether3D
//
// PR#7 Scan Guidance UI — Adaptive Border Tests
//

import XCTest
@testable import Aether3DCore

final class AdaptiveBorderTests: XCTestCase {
    
    func testBorderWidthClamping() {
        let calculator = AdaptiveBorderCalculator()
        
        // Test minimum clamping
        let minWidth = calculator.calculate(
            display: 1.0,  // Maximum display
            areaSqM: 0.001,  // Small area
            medianArea: 0.5
        )
        XCTAssertGreaterThanOrEqual(
            minWidth,
            Float(ScanGuidanceConstants.borderMinWidthPx),
            "Border width should be clamped to minimum"
        )
        
        // Test maximum clamping
        let maxWidth = calculator.calculate(
            display: 0.0,  // Minimum display
            areaSqM: 10.0,  // Large area
            medianArea: 0.5
        )
        XCTAssertLessThanOrEqual(
            maxWidth,
            Float(ScanGuidanceConstants.borderMaxWidthPx),
            "Border width should be clamped to maximum"
        )
    }
    
    func testBorderWidthDecreasesWithDisplay() {
        let calculator = AdaptiveBorderCalculator()
        let areaSqM: Float = 0.5
        let medianArea: Float = 0.5
        
        let width0 = calculator.calculate(display: 0.0, areaSqM: areaSqM, medianArea: medianArea)
        let width05 = calculator.calculate(display: 0.5, areaSqM: areaSqM, medianArea: medianArea)
        let width1 = calculator.calculate(display: 1.0, areaSqM: areaSqM, medianArea: medianArea)
        
        // Border width should decrease as display increases
        XCTAssertGreaterThan(width0, width05, "Border width should decrease with display")
        XCTAssertGreaterThan(width05, width1, "Border width should decrease with display")
    }
    
    func testBorderWidthIncreasesWithArea() {
        let calculator = AdaptiveBorderCalculator()
        let display = 0.5
        let medianArea: Float = 0.5
        
        let widthSmall = calculator.calculate(display: display, areaSqM: 0.1, medianArea: medianArea)
        let widthLarge = calculator.calculate(display: display, areaSqM: 1.0, medianArea: medianArea)
        
        // Border width should increase with area
        XCTAssertGreaterThan(widthLarge, widthSmall, "Border width should increase with area")
    }
    
    func testDualFactorCalculation() {
        let calculator = AdaptiveBorderCalculator()
        
        // Test that both display and area factors affect the result
        let baseWidth = calculator.calculate(
            display: 0.5,
            areaSqM: 0.5,
            medianArea: 0.5
        )
        
        // Change display only
        let displayChanged = calculator.calculate(
            display: 0.0,
            areaSqM: 0.5,
            medianArea: 0.5
        )
        XCTAssertNotEqual(baseWidth, displayChanged, "Changing display should change border width")
        
        // Change area only
        let areaChanged = calculator.calculate(
            display: 0.5,
            areaSqM: 1.0,
            medianArea: 0.5
        )
        XCTAssertNotEqual(baseWidth, areaChanged, "Changing area should change border width")
    }
    
    func testGammaCorrection() {
        let calculator = AdaptiveBorderCalculator()
        
        // Test that gamma correction is applied
        // Without gamma, the relationship would be linear
        // With gamma > 1, the curve is steeper
        
        let widthLow = calculator.calculate(display: 0.1, areaSqM: 0.5, medianArea: 0.5)
        let widthMid = calculator.calculate(display: 0.5, areaSqM: 0.5, medianArea: 0.5)
        let widthHigh = calculator.calculate(display: 0.9, areaSqM: 0.5, medianArea: 0.5)
        
        // Verify non-linear relationship (gamma correction)
        let deltaLow = widthLow - widthMid
        let deltaHigh = widthMid - widthHigh
        
        // With gamma > 1, the difference should be larger at low display values
        XCTAssertGreaterThan(deltaLow, deltaHigh, "Gamma correction should create non-linear relationship")
    }
    
    func testBatchCalculation() {
        let calculator = AdaptiveBorderCalculator()
        
        let displayValues = [
            "patch-1": 0.0,
            "patch-2": 0.5,
            "patch-3": 1.0
        ]
        let triangles = [
            ScanTriangle(
                patchId: "patch-1",
                vertices: (SIMD3<Float>(0,0,0), SIMD3<Float>(1,0,0), SIMD3<Float>(0,1,0)),
                normal: SIMD3<Float>(0,0,1),
                areaSqM: 0.5
            ),
            ScanTriangle(
                patchId: "patch-2",
                vertices: (SIMD3<Float>(0,0,0), SIMD3<Float>(1,0,0), SIMD3<Float>(0,1,0)),
                normal: SIMD3<Float>(0,0,1),
                areaSqM: 0.5
            ),
            ScanTriangle(
                patchId: "patch-3",
                vertices: (SIMD3<Float>(0,0,0), SIMD3<Float>(1,0,0), SIMD3<Float>(0,1,0)),
                normal: SIMD3<Float>(0,0,1),
                areaSqM: 0.5
            )
        ]
        let medianArea: Float = 0.5
        
        let widths = calculator.calculate(
            displayValues: displayValues,
            triangles: triangles,
            medianArea: medianArea
        )
        
        XCTAssertEqual(widths.count, triangles.count, "Should return width for each triangle")
        
        // Verify widths are in valid range
        for width in widths {
            XCTAssertGreaterThanOrEqual(width, Float(ScanGuidanceConstants.borderMinWidthPx))
            XCTAssertLessThanOrEqual(width, Float(ScanGuidanceConstants.borderMaxWidthPx))
        }
    }
    
    func testAreaFactorClamping() {
        let calculator = AdaptiveBorderCalculator()
        
        // Test with very small area (should be clamped to 0.5)
        let widthSmall = calculator.calculate(display: 0.5, areaSqM: 0.001, medianArea: 0.5)
        
        // Test with very large area (should be clamped to 2.0)
        let widthLarge = calculator.calculate(display: 0.5, areaSqM: 10.0, medianArea: 0.5)
        
        // Both should be valid
        XCTAssertGreaterThanOrEqual(widthSmall, Float(ScanGuidanceConstants.borderMinWidthPx))
        XCTAssertLessThanOrEqual(widthSmall, Float(ScanGuidanceConstants.borderMaxWidthPx))
        XCTAssertGreaterThanOrEqual(widthLarge, Float(ScanGuidanceConstants.borderMinWidthPx))
        XCTAssertLessThanOrEqual(widthLarge, Float(ScanGuidanceConstants.borderMaxWidthPx))
    }
}
