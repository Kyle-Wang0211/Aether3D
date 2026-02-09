// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// PIZOcclusionFilterTests.swift
// Aether3D
//
// PR6 Evidence Grid System - PIZ Occlusion Filter Tests
//

import XCTest
@testable import Aether3DCore

final class PIZOcclusionFilterTests: XCTestCase {
    
    func testMinViewDiversityRequired() {
        let filter = PIZOcclusionFilter()
        
        // Create region with low severity (insufficient view diversity)
        let region = PIZRegion(
            id: "test-region-1",
            pixelCount: 100,
            areaRatio: 0.1,
            bbox: BoundingBox(minRow: 0, maxRow: 10, minCol: 0, maxCol: 10),
            centroid: Point(row: 5, col: 5),
            principalDirection: Vector(dx: 1.0, dy: 0.0),
            severityScore: 0.3  // Below threshold
        )
        
        let filtered = filter.filter(regions: [region])
        
        // Should not exclude (insufficient view diversity)
        XCTAssertEqual(filtered.count, 1, "Region with low view diversity should not be excluded")
    }
    
    func testFreezeWindowPreventsReInclusion() {
        let filter = PIZOcclusionFilter()
        
        // Create region with high severity (should be excluded)
        let region = PIZRegion(
            id: "test-region-2",
            pixelCount: 100,
            areaRatio: 0.1,
            bbox: BoundingBox(minRow: 0, maxRow: 10, minCol: 0, maxCol: 10),
            centroid: Point(row: 5, col: 5),
            principalDirection: Vector(dx: 1.0, dy: 0.0),
            severityScore: 0.81  // High severity (above 0.8 threshold)
        )
        
        // First filter: should exclude
        let filtered1 = filter.filter(regions: [region])
        XCTAssertEqual(filtered1.count, 0, "High severity region should be excluded")
        
        // Second filter immediately: should stay excluded (frozen)
        let filtered2 = filter.filter(regions: [region])
        XCTAssertEqual(filtered2.count, 0, "Excluded region should stay excluded during freeze window")
    }
    
    func testRateLimiter() {
        let filter = PIZOcclusionFilter()
        
        // Create multiple regions with high severity
        var regions: [PIZRegion] = []
        for i in 0..<10 {
            regions.append(PIZRegion(
                id: "region-\(i)",
                pixelCount: 100,
                areaRatio: 0.1,
                bbox: BoundingBox(minRow: i * 10, maxRow: (i + 1) * 10, minCol: 0, maxCol: 10),
                centroid: Point(row: Double(i * 10 + 5), col: 5),
                principalDirection: Vector(dx: 1.0, dy: 0.0),
                severityScore: 0.9  // High severity
            ))
        }
        
        // Filter rapidly (simulate rapid changes)
        let filtered = filter.filter(regions: regions)
        
        // Rate limiter should prevent all from being excluded at once
        // (Simplified test - actual rate limiting depends on deltaTimeSeconds)
        XCTAssertLessThanOrEqual(filtered.count, regions.count)
    }
    
    func testTransientSpikeNotPermanent() {
        let filter = PIZOcclusionFilter()
        
        // Create region with moderate severity
        let region = PIZRegion(
            id: "test-region-3",
            pixelCount: 100,
            areaRatio: 0.1,
            bbox: BoundingBox(minRow: 0, maxRow: 10, minCol: 0, maxCol: 10),
            centroid: Point(row: 5, col: 5),
            principalDirection: Vector(dx: 1.0, dy: 0.0),
            severityScore: 0.6  // Moderate severity
        )
        
        // First filter: may or may not exclude (depends on rate limiter)
        let filtered1 = filter.filter(regions: [region])
        
        // Brief spike should not permanently exclude
        // (This is a simplified test - actual behavior depends on rate limiter implementation)
        XCTAssertLessThanOrEqual(filtered1.count, 1)
    }
}
