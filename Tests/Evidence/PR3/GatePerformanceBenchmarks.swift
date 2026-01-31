//
// GatePerformanceBenchmarks.swift
// Aether3D
//
// PR3 - Gate Performance Benchmarks
//

import XCTest
import Foundation
@testable import Aether3DCore

/// Cross-platform high-resolution timer for performance measurement
private func benchmarkTime() -> Double {
    #if canImport(Darwin)
    // macOS/iOS: Use CFAbsoluteTimeGetCurrent for highest precision
    return CFAbsoluteTimeGetCurrent()
    #else
    // Linux: Use Date for cross-platform compatibility
    return Date().timeIntervalSinceReferenceDate
    #endif
}

final class GatePerformanceBenchmarks: XCTestCase {

    func testSigmoidPerformance() {
        #if DEBUG
        // Skip performance tests in DEBUG mode - compiler optimizations disabled
        print("Performance tests skipped in DEBUG mode")
        #else
        let iterations = 100_000

        // Stable sigmoid baseline
        let stableStart = benchmarkTime()
        for i in 0..<iterations {
            _ = StableLogistic.sigmoid(Double(i % 16) - 8.0)
        }
        let stableTime = benchmarkTime() - stableStart

        // LUT sigmoid
        let lutStart = benchmarkTime()
        for i in 0..<iterations {
            _ = LUTSigmoidGuarded.sigmoid(Double(i % 16) - 8.0)
        }
        let lutTime = benchmarkTime() - lutStart

        print("Sigmoid performance (\(iterations) iterations):")
        print("  Stable: \(stableTime * 1000)ms")
        print("  LUT: \(lutTime * 1000)ms (\(stableTime / lutTime)x faster)")

        // REQUIREMENT: LUT must be at least 2x faster
        if lutTime > 0 {
            XCTAssertGreaterThan(stableTime / lutTime, 2.0, "LUT should be 2x+ faster")
        }
        #endif
    }

    func testFullGateComputationPerformance() {
        let patches = 1000
        let iterations = 60  // 60 frames

        // Create test data
        var inputs: [(direction: EvidenceVector3, reprojRmsPx: Double, edgeRmsPx: Double, sharpness: Double, overexposureRatio: Double, underexposureRatio: Double)] = []
        for _ in 0..<patches {
            inputs.append((
                EvidenceVector3(
                    x: Double.random(in: -1...1),
                    y: Double.random(in: -1...1),
                    z: Double.random(in: -1...1)
                ).normalized(),
                Double.random(in: 0...2),
                Double.random(in: 0...1),
                Double.random(in: 0...100),
                Double.random(in: 0...1),
                Double.random(in: 0...1)
            ))
        }

        let computer = GateQualityComputer()

        let start = benchmarkTime()

        for iteration in 0..<iterations {
            for (index, input) in inputs.enumerated() {
                _ = computer.computeGateQuality(
                    patchId: "patch\(index)",
                    direction: input.direction,
                    reprojRmsPx: input.reprojRmsPx,
                    edgeRmsPx: input.edgeRmsPx,
                    sharpness: input.sharpness,
                    overexposureRatio: input.overexposureRatio,
                    underexposureRatio: input.underexposureRatio,
                    frameIndex: iteration * patches + index
                )
            }
        }

        let totalTime = benchmarkTime() - start
        let perFrameTime = totalTime / Double(iterations)
        let perPatchTime = perFrameTime / Double(patches)

        print("Gate computation performance:")
        print("  Total time: \(totalTime * 1000)ms for \(iterations) frames")
        print("  Per frame: \(perFrameTime * 1000)ms (\(patches) patches)")
        print("  Per patch: \(perPatchTime * 1_000_000)µs")

        #if DEBUG
        // In DEBUG mode, just verify it completes (no performance requirement)
        print("Performance assertion skipped in DEBUG mode")
        #else
        // REQUIREMENT: Per frame must be < 2ms (12% of 16.67ms frame budget)
        XCTAssertLessThan(perFrameTime * 1000, 2.0, "Gate computation must be < 2ms per frame")
        #endif
    }
}
