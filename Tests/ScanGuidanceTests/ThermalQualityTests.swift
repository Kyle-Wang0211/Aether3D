//
// ThermalQualityTests.swift
// Aether3D
//
// Thermal Quality Adapter Tests — unified point cloud + OIR pipeline
// Core-only tests (compile and run in SwiftPM)
//

import XCTest
@testable import Aether3DCore

final class ThermalQualityTests: XCTestCase {

    func testTierTargetFPS() {
        XCTAssertEqual(ThermalQualityAdapter.RenderTier.nominal.targetFPS, 60)
        XCTAssertEqual(ThermalQualityAdapter.RenderTier.fair.targetFPS, 60)
        XCTAssertEqual(ThermalQualityAdapter.RenderTier.serious.targetFPS, 30)
        XCTAssertEqual(ThermalQualityAdapter.RenderTier.critical.targetFPS, 24)
    }

    func testTierHapticFlag() {
        XCTAssertTrue(ThermalQualityAdapter.RenderTier.nominal.enableHaptics)
        XCTAssertTrue(ThermalQualityAdapter.RenderTier.fair.enableHaptics)
        XCTAssertTrue(ThermalQualityAdapter.RenderTier.serious.enableHaptics)
        XCTAssertFalse(ThermalQualityAdapter.RenderTier.critical.enableHaptics)
    }

    func testTierTrainingRate() {
        XCTAssertEqual(ThermalQualityAdapter.RenderTier.nominal.trainingRate, 1.0)
        XCTAssertEqual(ThermalQualityAdapter.RenderTier.critical.trainingRate, 0.0)
        XCTAssertGreaterThan(
            ThermalQualityAdapter.RenderTier.fair.trainingRate,
            ThermalQualityAdapter.RenderTier.serious.trainingRate
        )
    }

    func testForceRenderTier() {
        let adapter = ThermalQualityAdapter()
        for tier in ThermalQualityAdapter.RenderTier.allCases {
            adapter.forceRenderTier(tier)
            XCTAssertEqual(adapter.currentTier, tier)
        }
    }

    func testFrameTimingUpdate() {
        let adapter = ThermalQualityAdapter()
        let initialTier = adapter.currentTier

        // Simulate frame timing that exceeds budget
        let targetMs = 1000.0 / Double(initialTier.targetFPS)
        let overshootMs = targetMs * 1.2 + 1.0  // 1.2 = frameBudgetOvershootRatio

        // Add many samples that exceed threshold
        for _ in 0..<30 {  // 30 = frameBudgetWindowFrames
            adapter.updateFrameTiming(gpuDurationMs: overshootMs)
        }

        // Verify the logic runs without crashing
    }

    #if os(iOS) || os(macOS)
    func testThermalStateUpdate() {
        let adapter = ThermalQualityAdapter()
        adapter.updateThermalState(.nominal)
        adapter.updateThermalState(.fair)
        adapter.updateThermalState(.serious)
        adapter.updateThermalState(.critical)

        adapter.forceRenderTier(.critical)
        XCTAssertEqual(adapter.currentTier, .critical)
    }
    #endif
}
