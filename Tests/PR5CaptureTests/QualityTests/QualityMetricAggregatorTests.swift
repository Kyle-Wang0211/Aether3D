// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// QualityMetricAggregatorTests.swift
// PR5CaptureTests
//
// Tests for QualityMetricAggregator
//

import XCTest
@testable import PR5Capture

@MainActor
final class QualityMetricAggregatorTests: XCTestCase {
    
    var aggregator: QualityMetricAggregator!
    var config: ExtremeProfile!
    
    override func setUp() async throws {
        config = ExtremeProfile(profile: .standard)
        aggregator = QualityMetricAggregator(config: config)
    }
    
    override func tearDown() async throws {
        aggregator = nil
        config = nil
    }
    
    func testAggregateMetrics() async {
        let metrics = [
            "sharpness": 0.8,
            "exposure": 0.7,
            "contrast": 0.75
        ]
        
        let result = await aggregator.aggregateMetrics(metrics)
        XCTAssertGreaterThan(result.score, 0.0)
        XCTAssertLessThanOrEqual(result.score, 1.0)
    }
    
    func testWeightedAggregation() async {
        await aggregator.setWeight(for: "sharpness", weight: 1.0)
        await aggregator.setWeight(for: "exposure", weight: 0.0)
        
        let metrics = [
            "sharpness": 0.9,
            "exposure": 0.1
        ]
        
        let result = await aggregator.aggregateMetrics(metrics)
        // Should be close to sharpness value since it has full weight
        XCTAssertGreaterThan(result.score, 0.8)
    }
}
