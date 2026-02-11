// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// DimensionalEvidenceTests.swift
// Aether3D
//
// PR6 Evidence Grid System - Dimensional Evidence Tests
//

import XCTest
@testable import Aether3DCore

final class DimensionalEvidenceTests: XCTestCase {
    
    func testAllScoresClampedToZeroOne() {
        // Test that @ClampedEvidence enforces [0, 1] bounds
        var scores = DimensionalScoreSet()
        
        // Try to set values outside [0, 1]
        scores.dim1_viewGain = -0.5  // Should clamp to 0.0
        scores.dim2_geometryGain = 1.5  // Should clamp to 1.0
        
        XCTAssertEqual(scores.dim1_viewGain, 0.0, accuracy: 0.01, "@ClampedEvidence should clamp negative values to 0")
        XCTAssertEqual(scores.dim2_geometryGain, 1.0, accuracy: 0.01, "@ClampedEvidence should clamp values > 1.0 to 1.0")
        
        // Test valid range
        scores.dim3_depthQuality = 0.5
        XCTAssertEqual(scores.dim3_depthQuality, 0.5, accuracy: 0.01)
    }
    
    func testDimensionalComputerFromRawMetrics() {
        let computer = DimensionalComputer()
        
        // Create test inputs
        let gateGainFunctions = GateGainFunctionsOutput(
            viewGain: 0.7,
            geometryGain: 0.6,
            basicGain: 0.5
        )
        
        let coverageTracker = GateCoverageTrackerOutput(coverageScore: 0.3)
        let viewDiversityTracker = ViewDiversityTrackerOutput(diversityScore: 0.8)
        
        // Compute scores
        let scores = computer.compute(
            gateGainFunctions: gateGainFunctions,
            gateCoverageTracker: coverageTracker,
            viewDiversityTracker: viewDiversityTracker,
            observationErrorType: nil,
            depthData: nil,
            semanticData: nil,
            resolutionData: nil,
            provenanceHash: nil
        )
        
        // Verify scores are computed
        XCTAssertGreaterThanOrEqual(scores.dim1_viewGain, 0.0)
        XCTAssertLessThanOrEqual(scores.dim1_viewGain, 1.0)
        XCTAssertEqual(scores.dim1_viewGain, 0.7, accuracy: 0.01)
        
        // Verify softAggregate is computed
        XCTAssertGreaterThanOrEqual(scores.softAggregate, 0.0)
        XCTAssertLessThanOrEqual(scores.softAggregate, 1.0)
    }
}
