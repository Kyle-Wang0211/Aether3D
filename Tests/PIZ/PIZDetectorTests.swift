// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// PIZDetectorTests.swift
// Aether3D
//
// PR1 PIZ Detection - Detector Tests
//
// Tests for deterministic detection, synthetic regions, ordering, and region IDs.
// **Rule ID:** PIZ_GLOBAL_REGION_001, PIZ_REGION_ORDER_002, PIZ_REGION_ID_001

import XCTest
@testable import Aether3DCore

final class PIZDetectorTests: XCTestCase {
    
    /// Test synthetic region created when global trigger fires but no local regions.
    /// **Rule ID:** PIZ_GLOBAL_REGION_001
    func testSyntheticRegionForGlobalTrigger() {
        let detector = PIZDetector()
        
        // Create heatmap with global coverage < 0.75 but no local regions
        // All cells have coverage 0.3 (< COVERED_CELL_MIN = 0.5)
        var heatmap = Array(repeating: Array(repeating: 0.3, count: 32), count: 32)
        
        let report = detector.detect(
            heatmap: heatmap,
            assetId: "test",
            outputProfile: .fullExplainability
        )
        
        XCTAssertTrue(report.globalTrigger)
        XCTAssertEqual(report.localTriggerCount, 1) // Synthetic region added
        
        if let regions = report.regions, !regions.isEmpty {
            let syntheticRegion = regions[0]
            XCTAssertEqual(syntheticRegion.pixelCount, PIZThresholds.TOTAL_GRID_CELLS)
            XCTAssertEqual(syntheticRegion.areaRatio, 1.0, accuracy: 1e-10)
            XCTAssertEqual(syntheticRegion.bbox.minRow, 0)
            XCTAssertEqual(syntheticRegion.bbox.maxRow, 31)
            XCTAssertEqual(syntheticRegion.bbox.minCol, 0)
            XCTAssertEqual(syntheticRegion.bbox.maxCol, 31)
        } else {
            XCTFail("Synthetic region should be present")
        }
    }
    
    /// Test deterministic region ordering (bbox-based, not discovery order).
    /// **Rule ID:** PIZ_REGION_ORDER_002
    func testDeterministicRegionOrdering() {
        let detector = PIZDetector()
        
        // Create heatmap with two regions that would swap if discovery-order used
        var heatmap = Array(repeating: Array(repeating: 0.8, count: 32), count: 32)
        
        // Region 1: top-left (rows 0-7, cols 0-7) - 64 pixels, areaRatio = 64/1024 = 0.0625 > 0.05
        for row in 0..<8 {
            for col in 0..<8 {
                heatmap[row][col] = 0.2 // coverage < COVERED_CELL_MIN (0.5)
            }
        }
        
        // Region 2: bottom-right (rows 24-31, cols 24-31) - 64 pixels, areaRatio = 64/1024 = 0.0625 > 0.05
        for row in 24..<32 {
            for col in 24..<32 {
                heatmap[row][col] = 0.2 // coverage < COVERED_CELL_MIN (0.5)
            }
        }
        
        let report = detector.detect(
            heatmap: heatmap,
            assetId: "test",
            outputProfile: .fullExplainability
        )
        
        guard let regions = report.regions, regions.count >= 2 else {
            XCTFail("Expected at least 2 regions")
            return
        }
        
        // Verify ordering: region 1 (minRow=0) should come before region 2 (minRow=26)
        let region1 = regions[0]
        let region2 = regions[1]
        
        XCTAssertLessThanOrEqual(region1.bbox.minRow, region2.bbox.minRow)
        
        // If minRow equal, minCol should determine order
        if region1.bbox.minRow == region2.bbox.minRow {
            XCTAssertLessThanOrEqual(region1.bbox.minCol, region2.bbox.minCol)
        }
    }
    
    /// Test deterministic region ID generation.
    /// **Rule ID:** PIZ_REGION_ID_001
    func testDeterministicRegionID() {
        let detector = PIZDetector()
        
        // Create identical heatmap twice
        var heatmap = Array(repeating: Array(repeating: 0.8, count: 32), count: 32)
        for row in 0..<10 {
            for col in 0..<10 {
                heatmap[row][col] = 0.2
            }
        }
        
        let report1 = detector.detect(
            heatmap: heatmap,
            assetId: "test1",
            outputProfile: .fullExplainability
        )
        
        let report2 = detector.detect(
            heatmap: heatmap,
            assetId: "test2",
            outputProfile: .fullExplainability
        )
        
        guard let regions1 = report1.regions, let regions2 = report2.regions,
              !regions1.isEmpty, !regions2.isEmpty else {
            XCTFail("Expected regions")
            return
        }
        
        // Region IDs should be identical for same bbox + pixelCount
        XCTAssertEqual(regions1[0].id, regions2[0].id)
        XCTAssertTrue(regions1[0].id.hasPrefix("piz_region_"))
    }
    
    /// Test principal direction tie-breaking.
    /// **Rule ID:** PIZ_DIRECTION_TIEBREAK_001
    func testPrincipalDirectionTieBreaking() {
        let detector = PIZDetector()
        
        // Create a square region where corners are equidistant from centroid
        var heatmap = Array(repeating: Array(repeating: 0.8, count: 32), count: 32)
        for row in 10..<20 {
            for col in 10..<20 {
                heatmap[row][col] = 0.2
            }
        }
        
        let report = detector.detect(
            heatmap: heatmap,
            assetId: "test",
            outputProfile: .fullExplainability
        )
        
        guard let regions = report.regions, !regions.isEmpty else {
            XCTFail("Expected region")
            return
        }
        
        let region = regions[0]
        let direction = region.principalDirection
        
        // Principal direction should be normalized (unit length)
        let length = sqrt(direction.dx * direction.dx + direction.dy * direction.dy)
        XCTAssertEqual(length, 1.0, accuracy: 1e-10)
    }
    
    /// Test DecisionOnly profile output.
    /// **Rule ID:** PIZ_SCHEMA_PROFILE_001
    func testDecisionOnlyProfile() {
        let detector = PIZDetector()
        
        let heatmap = Array(repeating: Array(repeating: 0.5, count: 32), count: 32)
        
        let report = detector.detect(
            heatmap: heatmap,
            assetId: "test",
            outputProfile: .decisionOnly
        )
        
        XCTAssertEqual(report.outputProfile, .decisionOnly)
        XCTAssertNil(report.heatmap)
        XCTAssertNil(report.regions)
        XCTAssertNotNil(report.gateRecommendation)
        XCTAssertNotNil(report.globalTrigger)
    }
}
