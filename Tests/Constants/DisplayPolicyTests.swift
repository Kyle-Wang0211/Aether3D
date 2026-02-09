// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// DisplayPolicyTests.swift
// Aether3D
//
// Tests for DisplayPolicy (separation of algorithm vs display resolution)
//

import XCTest
@testable import Aether3DCore

final class DisplayPolicyTests: XCTestCase {
    
    // MARK: - Policy Existence Tests
    
    func testUserFacingGranularityExists() {
        let policy = DisplayPolicy.userFacingGranularity
        XCTAssertFalse(policy.allowedAggregationLevels.isEmpty)
        XCTAssertFalse(policy.allowedDrillDownLevels.isEmpty)
        XCTAssertGreaterThan(policy.targetDisplayPixelDensityPerVisualCell, 0)
    }
    
    // MARK: - Aggregation Level Tests
    
    func testAggregationLevelsAreCoarse() {
        let policy = DisplayPolicy.userFacingGranularity
        
        // Aggregation levels should be >= 5mm (coarse enough for display)
        for levelDigest in policy.allowedAggregationLevels {
            guard let scale = LengthScale(rawValue: levelDigest.scaleId) else {
                XCTFail("Invalid scaleId: \(levelDigest.scaleId)")
                continue
            }
            let level = LengthQ(scaleId: scale, quanta: levelDigest.quanta)
            XCTAssertGreaterThanOrEqual(level, LengthQ(scaleId: .geomId, quanta: 5),
                                       "Aggregation levels must be >= 5mm")
        }
    }
    
    func testDrillDownLevelsAreStillAggregated() {
        let policy = DisplayPolicy.userFacingGranularity
        
        // Drill-down levels should still be aggregated (>= 2mm)
        for levelDigest in policy.allowedDrillDownLevels {
            guard let scale = LengthScale(rawValue: levelDigest.scaleId) else {
                XCTFail("Invalid scaleId: \(levelDigest.scaleId)")
                continue
            }
            let level = LengthQ(scaleId: scale, quanta: levelDigest.quanta)
            XCTAssertGreaterThanOrEqual(level, LengthQ(scaleId: .geomId, quanta: 2),
                                       "Drill-down levels must be >= 2mm (still aggregated)")
        }
    }
    
    // MARK: - Display Rules Tests
    
    func testWireframeDebugOnly() {
        XCTAssertTrue(DisplayPolicy.wireframeDebugOnly,
                     "Wireframe must be debug-only")
    }
    
    func testRequireAggregation() {
        XCTAssertTrue(DisplayPolicy.requireAggregation,
                     "Must require aggregation")
    }
    
    // MARK: - Schema Version Tests
    
    func testSchemaVersionIdMatches() {
        let policy = DisplayPolicy.userFacingGranularity
        XCTAssertEqual(policy.schemaVersionId, SSOTVersion.schemaVersionId)
    }
    
    // MARK: - Digest Input Tests
    
    func testDigestInput() throws {
        let digestInput = DisplayPolicy.digestInput(schemaVersionId: SSOTVersion.schemaVersionId)
        XCTAssertEqual(digestInput.schemaVersionId, SSOTVersion.schemaVersionId)
        XCTAssertEqual(digestInput.wireframeDebugOnly, DisplayPolicy.wireframeDebugOnly)
        XCTAssertEqual(digestInput.requireAggregation, DisplayPolicy.requireAggregation)
    }
    
    func testDigestInputDeterministic() throws {
        let digest1 = try CanonicalDigest.computeDigest(
            DisplayPolicy.digestInput(schemaVersionId: SSOTVersion.schemaVersionId)
        )
        let digest2 = try CanonicalDigest.computeDigest(
            DisplayPolicy.digestInput(schemaVersionId: SSOTVersion.schemaVersionId)
        )
        XCTAssertEqual(digest1, digest2, "Digest must be deterministic")
    }
}
