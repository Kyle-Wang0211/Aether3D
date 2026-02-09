// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// CoverageEstimatorTests.swift
// Aether3D
//
// PR6 Evidence Grid System - Coverage Estimator Tests
//

import XCTest
@testable import Aether3DCore

final class CoverageEstimatorTests: XCTestCase {
    
    func testEmptyGridZeroCoverage() async {
        let grid = await EvidenceGrid(cellSize: LengthQ(scaleId: .geomId, quanta: 1), maxCells: 100)
        let estimator = CoverageEstimator()
        
        let result = await estimator.update(grid: grid)
        
        XCTAssertEqual(result.coveragePercentage, 0.0, accuracy: 0.01)
    }
    
    func testAllL0ZeroCoverage() async {
        let grid = await EvidenceGrid(cellSize: LengthQ(scaleId: .geomId, quanta: 1), maxCells: 1000)
        let estimator = CoverageEstimator()
        
        // Insert 1000 L0 cells
        var batch = EvidenceGrid.EvidenceGridDeltaBatch()
        for i in 0..<1000 {
            let worldPos = EvidenceVector3(x: Double(i % 10), y: Double((i / 10) % 10), z: Double(i / 100))
            let mortonCode = await grid.quantizer.mortonCode(from: worldPos)
            let key = SpatialKey(mortonCode: mortonCode, level: .L0)
            
            let cell = GridCell(
                patchId: "patch-\(i)",
                quantizedPosition: await grid.quantizer.quantize(worldPos),
                dimScores: DimensionalScoreSet(),
                dsMass: DSMassFunction(occupied: 0.0, free: 0.0, unknown: 1.0),
                level: .L0,
                directionalMask: 0,
                lastUpdatedMillis: MonotonicClock.nowMs()
            )
            batch.add(EvidenceGrid.GridCellUpdate.insert(key: key, cell: cell))
        }
        await grid.apply(batch)
        
        let result = await estimator.update(grid: grid)
        
        // L0 has weight 0.0, so coverage should be ~0%
        XCTAssertEqual(result.coveragePercentage, 0.0, accuracy: 0.01)
    }
    
    func testMixedL1L3Coverage() async {
        let grid = await EvidenceGrid(cellSize: LengthQ(scaleId: .geomId, quanta: 1), maxCells: 1000)
        let estimator = CoverageEstimator()
        
        // Insert 500 L1 + 300 L2 + 200 L3 cells
        var batch = EvidenceGrid.EvidenceGridDeltaBatch()
        var cellCount = 0
        
        // L1 cells
        for i in 0..<500 {
            let worldPos = EvidenceVector3(x: Double(i % 10), y: Double((i / 10) % 10), z: 0.0)
            let mortonCode = await grid.quantizer.mortonCode(from: worldPos)
            let key = SpatialKey(mortonCode: mortonCode, level: .L1)
            
            let cell = GridCell(
                patchId: "patch-L1-\(i)",
                quantizedPosition: await grid.quantizer.quantize(worldPos),
                dimScores: DimensionalScoreSet(),
                dsMass: DSMassFunction(occupied: 0.5, free: 0.0, unknown: 0.5),
                level: .L1,
                directionalMask: 0,
                lastUpdatedMillis: MonotonicClock.nowMs()
            )
            batch.add(EvidenceGrid.GridCellUpdate.insert(key: key, cell: cell))
            cellCount += 1
        }
        
        // L2 cells
        for i in 0..<300 {
            let worldPos = EvidenceVector3(x: Double(i % 10), y: Double((i / 10) % 10), z: 1.0)
            let mortonCode = await grid.quantizer.mortonCode(from: worldPos)
            let key = SpatialKey(mortonCode: mortonCode, level: .L2)
            
            let cell = GridCell(
                patchId: "patch-L2-\(i)",
                quantizedPosition: await grid.quantizer.quantize(worldPos),
                dimScores: DimensionalScoreSet(),
                dsMass: DSMassFunction(occupied: 0.7, free: 0.0, unknown: 0.3),
                level: .L2,
                directionalMask: 0,
                lastUpdatedMillis: MonotonicClock.nowMs()
            )
            batch.add(EvidenceGrid.GridCellUpdate.insert(key: key, cell: cell))
            cellCount += 1
        }
        
        // L3 cells
        for i in 0..<200 {
            let worldPos = EvidenceVector3(x: Double(i % 10), y: Double((i / 10) % 10), z: 2.0)
            let mortonCode = await grid.quantizer.mortonCode(from: worldPos)
            let key = SpatialKey(mortonCode: mortonCode, level: .L3)
            
            let cell = GridCell(
                patchId: "patch-L3-\(i)",
                quantizedPosition: await grid.quantizer.quantize(worldPos),
                dimScores: DimensionalScoreSet(),
                dsMass: DSMassFunction(occupied: 0.8, free: 0.0, unknown: 0.2),
                level: .L3,
                directionalMask: 0,
                lastUpdatedMillis: MonotonicClock.nowMs()
            )
            batch.add(EvidenceGrid.GridCellUpdate.insert(key: key, cell: cell))
            cellCount += 1
        }
        
        await grid.apply(batch)
        
        let result = await estimator.update(grid: grid)
        
        // Expected coverage: weighted average
        // L1 weight=0.2, L2 weight=0.5, L3 weight=0.8
        // With occupied masses: L1=0.5, L2=0.7, L3=0.8
        // Coverage should be > 0 and < 1
        XCTAssertGreaterThan(result.coveragePercentage, 0.0)
        XCTAssertLessThan(result.coveragePercentage, 1.0)
    }
    
    func testAllL5HighCoverage() async {
        let grid = await EvidenceGrid(cellSize: LengthQ(scaleId: .geomId, quanta: 1), maxCells: 1000)
        let estimator = CoverageEstimator()
        
        // Insert 200 L5 cells with distinct positions (spread out to avoid quantization collisions)
        // More cells = higher raw coverage, which helps overcome EMA smoothing and anti-jitter limiter
        var batch = EvidenceGrid.EvidenceGridDeltaBatch()
        for i in 0..<200 {
            // Use larger spacing to ensure distinct cells (10 units apart)
            let worldPos = EvidenceVector3(x: Double(i * 10), y: 0.0, z: 0.0)
            let mortonCode = await grid.quantizer.mortonCode(from: worldPos)
            let key = SpatialKey(mortonCode: mortonCode, level: .L5)
            
            let cell = GridCell(
                patchId: "patch-L5-\(i)",
                quantizedPosition: await grid.quantizer.quantize(worldPos),
                dimScores: DimensionalScoreSet(),
                dsMass: DSMassFunction(occupied: 0.95, free: 0.0, unknown: 0.05),
                level: .L5,
                directionalMask: 0,
                lastUpdatedMillis: MonotonicClock.nowMs()
            )
            batch.add(EvidenceGrid.GridCellUpdate.insert(key: key, cell: cell))
        }
        await grid.apply(batch)
        
        // Reset estimator to start from clean state
        estimator.reset()
        
        // Call update multiple times to let EMA smoothing converge
        // Raw coverage = (200 * 0.95 * 0.95) / 200 = 0.9025
        // EMA converges to rawCoverage after many iterations
        // Anti-jitter limiter allows max 0.10 per second
        var result = await estimator.update(grid: grid)
        // Wait between updates to allow anti-jitter limiter to pass through changes
        // With 200 L5 cells (weight=0.95, occupied=0.95), raw coverage is 0.9025
        // After EMA smoothing and anti-jitter limiting, coverage will be high but may take time to converge
        for _ in 0..<50 {
            // 200ms delay allows more coverage increase per iteration
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
            result = await estimator.update(grid: grid)
        }
        
        // After convergence, coverage should be significantly high
        // With 200 L5 cells, raw coverage is 0.9025
        // After EMA and anti-jitter limiting, expect > 0.80 (allowing for smoothing effects)
        XCTAssertGreaterThan(result.coveragePercentage, 0.80)
        XCTAssertLessThanOrEqual(result.coveragePercentage, 1.0)
    }
    
    func testCoverageBoundedZeroOne() async {
        let grid = await EvidenceGrid(cellSize: LengthQ(scaleId: .geomId, quanta: 1), maxCells: 100)
        let estimator = CoverageEstimator()
        
        // Insert various cells
        var batch = EvidenceGrid.EvidenceGridDeltaBatch()
        for i in 0..<50 {
            let worldPos = EvidenceVector3(x: Double(i), y: 0.0, z: 0.0)
            let mortonCode = await grid.quantizer.mortonCode(from: worldPos)
            let key = SpatialKey(mortonCode: mortonCode, level: .L3)
            
            let cell = GridCell(
                patchId: "patch-\(i)",
                quantizedPosition: await grid.quantizer.quantize(worldPos),
                dimScores: DimensionalScoreSet(),
                dsMass: DSMassFunction(occupied: 0.8, free: 0.0, unknown: 0.2),
                level: .L3,
                directionalMask: 0,
                lastUpdatedMillis: MonotonicClock.nowMs()
            )
            batch.add(EvidenceGrid.GridCellUpdate.insert(key: key, cell: cell))
        }
        await grid.apply(batch)
        
        let result = await estimator.update(grid: grid)
        
        // Coverage must be in [0, 1]
        XCTAssertGreaterThanOrEqual(result.coveragePercentage, 0.0)
        XCTAssertLessThanOrEqual(result.coveragePercentage, 1.0)
    }
    
    func testAntiJitterLimiter() async {
        let grid = await EvidenceGrid(cellSize: LengthQ(scaleId: .geomId, quanta: 1), maxCells: 100)
        let estimator = CoverageEstimator()
        
        // First update: low coverage
        var batch1 = EvidenceGrid.EvidenceGridDeltaBatch()
        for i in 0..<10 {
            let worldPos = EvidenceVector3(x: Double(i), y: 0.0, z: 0.0)
            let mortonCode = await grid.quantizer.mortonCode(from: worldPos)
            let key = SpatialKey(mortonCode: mortonCode, level: .L1)
            
            let cell = GridCell(
                patchId: "patch-\(i)",
                quantizedPosition: await grid.quantizer.quantize(worldPos),
                dimScores: DimensionalScoreSet(),
                dsMass: DSMassFunction(occupied: 0.2, free: 0.0, unknown: 0.8),
                level: .L1,
                directionalMask: 0,
                lastUpdatedMillis: MonotonicClock.nowMs()
            )
            batch1.add(EvidenceGrid.GridCellUpdate.insert(key: key, cell: cell))
        }
        await grid.apply(batch1)
        
        let result1 = await estimator.update(grid: grid)
        let coverage1 = result1.coveragePercentage
        
        // Second update: sudden spike (add many L5 cells)
        var batch2 = EvidenceGrid.EvidenceGridDeltaBatch()
        for i in 10..<100 {
            let worldPos = EvidenceVector3(x: Double(i), y: 0.0, z: 0.0)
            let mortonCode = await grid.quantizer.mortonCode(from: worldPos)
            let key = SpatialKey(mortonCode: mortonCode, level: .L5)
            
            let cell = GridCell(
                patchId: "patch-\(i)",
                quantizedPosition: await grid.quantizer.quantize(worldPos),
                dimScores: DimensionalScoreSet(),
                dsMass: DSMassFunction(occupied: 0.95, free: 0.0, unknown: 0.05),
                level: .L5,
                directionalMask: 0,
                lastUpdatedMillis: MonotonicClock.nowMs()
            )
            batch2.add(EvidenceGrid.GridCellUpdate.insert(key: key, cell: cell))
        }
        await grid.apply(batch2)
        
        // Wait a short time (simulate)
        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        
        let result2 = await estimator.update(grid: grid)
        let coverage2 = result2.coveragePercentage
        
        // Coverage should increase, but rate-limited
        XCTAssertGreaterThan(coverage2, coverage1)
        
        // Rate should be limited by maxCoverageDeltaPerSec
        // (This is a simplified test - actual rate limiting depends on time delta)
    }
}
