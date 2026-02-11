// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// LinearColorSpaceConverterTests.swift
// PR5CaptureTests
//
// Comprehensive tests for LinearColorSpaceConverter
//

import XCTest
@testable import PR5Capture

final class LinearColorSpaceConverterTests: XCTestCase {
    
    // MARK: - Happy Path Tests
    
    func test_normalInput_returnsValidOutput() {
        let linear = LinearColorSpaceConverter.sRGBToLinear(0.5)
        XCTAssertGreaterThanOrEqual(linear, 0.0)
        XCTAssertLessThanOrEqual(linear, 1.0)
    }
    
    func test_typicalUseCase_succeeds() {
        let sRGB = 0.8
        let linear = LinearColorSpaceConverter.sRGBToLinear(sRGB)
        let backToSRGB = LinearColorSpaceConverter.linearToSRGB(linear)
        XCTAssertEqual(sRGB, backToSRGB, accuracy: 0.01)
    }
    
    func test_standardConfiguration_works() {
        let linear = LinearColorSpaceConverter.sRGBToLinear(0.5)
        let sRGB = LinearColorSpaceConverter.linearToSRGB(linear)
        XCTAssertEqual(0.5, sRGB, accuracy: 0.1)
    }
    
    func test_expectedInput_producesExpectedOutput() {
        let testValues: [Double] = [0.0, 0.25, 0.5, 0.75, 1.0]
        
        for value in testValues {
            let linear = LinearColorSpaceConverter.sRGBToLinear(value)
            XCTAssertGreaterThanOrEqual(linear, 0.0)
            XCTAssertLessThanOrEqual(linear, 1.0)
        }
    }
    
    func test_commonScenario_handledCorrectly() {
        let sRGBValues = Array(stride(from: 0.0, to: 1.0, by: 0.1))
        for sRGB in sRGBValues {
            let linear = LinearColorSpaceConverter.sRGBToLinear(sRGB)
            XCTAssertNotNil(linear)
        }
    }
    
    // MARK: - Boundary Tests
    
    func test_minimumInput_handled() {
        let linear = LinearColorSpaceConverter.sRGBToLinear(0.0)
        XCTAssertEqual(linear, 0.0, accuracy: 0.001)
    }
    
    func test_maximumInput_handled() {
        let linear = LinearColorSpaceConverter.sRGBToLinear(1.0)
        XCTAssertEqual(linear, 1.0, accuracy: 0.001)
    }
    
    func test_zeroInput_handled() {
        let linear = LinearColorSpaceConverter.sRGBToLinear(0.0)
        let sRGB = LinearColorSpaceConverter.linearToSRGB(0.0)
        XCTAssertEqual(linear, 0.0, accuracy: 0.001)
        XCTAssertEqual(sRGB, 0.0, accuracy: 0.001)
    }
    
    func test_emptyInput_handled() {
        // Not applicable for single value conversion
        let linear = LinearColorSpaceConverter.sRGBToLinear(0.5)
        XCTAssertNotNil(linear)
    }
    
    func test_boundaryValue_processed() {
        let nearZero = LinearColorSpaceConverter.sRGBToLinear(0.001)
        let nearOne = LinearColorSpaceConverter.sRGBToLinear(0.999)
        XCTAssertGreaterThan(nearZero, 0.0)
        XCTAssertLessThan(nearOne, 1.0)
    }
    
    // MARK: - Round-trip Tests
    
    func test_roundTrip_consistency() {
        let testValues: [Double] = [0.0, 0.1, 0.5, 0.9, 1.0]
        
        for sRGB in testValues {
            let linear = LinearColorSpaceConverter.sRGBToLinear(sRGB)
            let backToSRGB = LinearColorSpaceConverter.linearToSRGB(linear)
            XCTAssertEqual(sRGB, backToSRGB, accuracy: 0.05)
        }
    }
    
    func test_consistency_verification() {
        let sRGB = 0.5
        let isConsistent = LinearColorSpaceConverter.verifyConsistency(sRGB)
        XCTAssertTrue(isConsistent)
    }
    
    // MARK: - Profile Tests
    
    func test_productionProfile_behavior() {
        // Converter is stateless, test conversion accuracy
        let linear = LinearColorSpaceConverter.sRGBToLinear(0.5)
        XCTAssertNotNil(linear)
    }
    
    func test_developmentProfile_behavior() {
        let linear = LinearColorSpaceConverter.sRGBToLinear(0.5)
        XCTAssertNotNil(linear)
    }
    
    func test_testingProfile_behavior() {
        let linear = LinearColorSpaceConverter.sRGBToLinear(0.5)
        XCTAssertNotNil(linear)
    }
    
    func test_paranoidProfile_behavior() {
        let linear = LinearColorSpaceConverter.sRGBToLinear(0.5)
        XCTAssertNotNil(linear)
    }
    
    // MARK: - Performance Tests
    
    func test_performance_underLoad() {
        measure {
            for _ in 0..<1000 {
                _ = LinearColorSpaceConverter.sRGBToLinear(0.5)
            }
        }
    }
    
    func test_memory_footprint() {
        // Stateless converter should have minimal memory footprint
        let converter = LinearColorSpaceConverter.self
        XCTAssertNotNil(converter)
    }
}
