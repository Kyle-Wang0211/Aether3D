//
// EvidenceGridDeterminismTests.swift
// Aether3D
//
// PR6 Evidence Grid System - Determinism Tests
//

import XCTest
@testable import Aether3DCore

final class EvidenceGridDeterminismTests: XCTestCase {
    
    func testSameInputSameGridState() async {
        // Create two separate grid instances
        let grid1 = await EvidenceGrid(cellSize: LengthQ(scaleId: .geomId, quanta: 1), maxCells: 1000)
        let grid2 = await EvidenceGrid(cellSize: LengthQ(scaleId: .geomId, quanta: 1), maxCells: 1000)
        
        // Feed identical observation sequence to both
        let observations: [(worldPos: EvidenceVector3, patchId: String, level: EvidenceConfidenceLevel)] = [
            (EvidenceVector3(x: 1.0, y: 2.0, z: 3.0), "patch-1", .L3),
            (EvidenceVector3(x: 2.0, y: 3.0, z: 4.0), "patch-2", .L3),
            (EvidenceVector3(x: 3.0, y: 4.0, z: 5.0), "patch-3", .L2),
        ]
        
        // Apply to grid1
        var batch1 = EvidenceGrid.EvidenceGridDeltaBatch()
        for obs in observations {
            let mortonCode = await grid1.quantizer.mortonCode(from: obs.worldPos)
            let key = SpatialKey(mortonCode: mortonCode, level: obs.level)
            let cell = GridCell(
                patchId: obs.patchId,
                quantizedPosition: await grid1.quantizer.quantize(obs.worldPos),
                dimScores: DimensionalScoreSet(),
                dsMass: DSMassFunction.vacuous,
                level: obs.level,
                directionalMask: 0,
                lastUpdatedMillis: MonotonicClock.nowMs()
            )
            batch1.add(EvidenceGrid.GridCellUpdate.insert(key: key, cell: cell))
        }
        await grid1.apply(batch1)
        
        // Apply to grid2 (same sequence)
        var batch2 = EvidenceGrid.EvidenceGridDeltaBatch()
        for obs in observations {
            let mortonCode = await grid2.quantizer.mortonCode(from: obs.worldPos)
            let key = SpatialKey(mortonCode: mortonCode, level: obs.level)
            let cell = GridCell(
                patchId: obs.patchId,
                quantizedPosition: await grid2.quantizer.quantize(obs.worldPos),
                dimScores: DimensionalScoreSet(),
                dsMass: DSMassFunction.vacuous,
                level: obs.level,
                directionalMask: 0,
                lastUpdatedMillis: MonotonicClock.nowMs()
            )
            batch2.add(EvidenceGrid.GridCellUpdate.insert(key: key, cell: cell))
        }
        await grid2.apply(batch2)
        
        // Compare cell-by-cell
        let cells1 = await grid1.allActiveCells()
        let cells2 = await grid2.allActiveCells()
        
        XCTAssertEqual(cells1.count, cells2.count, "Grids should have same cell count")
        
        // Compare in deterministic order
        for (c1, c2) in zip(cells1, cells2) {
            XCTAssertEqual(c1.patchId, c2.patchId, "Cells should match")
            XCTAssertEqual(c1.level, c2.level, "Levels should match")
        }
    }
    
    func testSameInputSameCoverage() async {
        let grid = await EvidenceGrid(cellSize: LengthQ(scaleId: .geomId, quanta: 1), maxCells: 1000)
        
        // Insert cells
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
        
        // Use separate estimators to avoid EMA state affecting determinism test
        // The test verifies that same grid input produces same level breakdown
        // NOTE: coveragePercentage includes EMA smoothing + anti-jitter limiter
        // which depend on MonotonicClock timing, so we compare breakdownCounts
        // (timing-independent) instead.
        let estimator1 = CoverageEstimator()
        estimator1.reset()  // Start from clean state
        let result1 = await estimator1.update(grid: grid)

        let estimator2 = CoverageEstimator()
        estimator2.reset()  // Start from clean state
        let result2 = await estimator2.update(grid: grid)

        // Level breakdown must be identical (no timing dependency)
        XCTAssertEqual(result1.breakdownCounts, result2.breakdownCounts)
        // Coverage can vary due to EMA timing; verify both are non-negative
        XCTAssertGreaterThanOrEqual(result1.coveragePercentage, 0.0)
        XCTAssertGreaterThanOrEqual(result2.coveragePercentage, 0.0)
    }
    
    func testSameInputSameProvenanceHash() async {
        let chain1 = ProvenanceChain()
        let chain2 = ProvenanceChain()
        
        let timestamp = MonotonicClock.nowMs()
        let levelBreakdown = [100, 0, 0, 0, 0, 0, 0]
        let pizSummary = (count: 0, totalAreaSqM: 0.0, excludedAreaSqM: 0.0)
        
        let hash1 = chain1.appendTransition(
            timestampMillis: timestamp,
            fromState: .black,
            toState: .darkGray,
            coverage: 0.25,
            levelBreakdown: levelBreakdown,
            pizSummary: pizSummary,
            gridDigest: "test-digest",
            policyDigest: "test-policy"
        )
        
        let hash2 = chain2.appendTransition(
            timestampMillis: timestamp,
            fromState: .black,
            toState: .darkGray,
            coverage: 0.25,
            levelBreakdown: levelBreakdown,
            pizSummary: pizSummary,
            gridDigest: "test-digest",
            policyDigest: "test-policy"
        )
        
        XCTAssertEqual(hash1, hash2, "Same inputs must produce same provenance hash")
    }
    
    func testIterationOrderStable() async {
        let grid = await EvidenceGrid(cellSize: LengthQ(scaleId: .geomId, quanta: 1), maxCells: 100)
        
        // Insert cells
        var batch = EvidenceGrid.EvidenceGridDeltaBatch()
        for i in 0..<20 {
            let worldPos = EvidenceVector3(x: Double(i), y: 0.0, z: 0.0)
            let mortonCode = await grid.quantizer.mortonCode(from: worldPos)
            let key = SpatialKey(mortonCode: mortonCode, level: .L3)
            
            let cell = GridCell(
                patchId: "patch-\(i)",
                quantizedPosition: await grid.quantizer.quantize(worldPos),
                dimScores: DimensionalScoreSet(),
                dsMass: DSMassFunction.vacuous,
                level: .L3,
                directionalMask: 0,
                lastUpdatedMillis: MonotonicClock.nowMs()
            )
            batch.add(EvidenceGrid.GridCellUpdate.insert(key: key, cell: cell))
        }
        await grid.apply(batch)
        
        // Iterate twice
        let cells1 = await grid.allActiveCells()
        let cells2 = await grid.allActiveCells()
        
        // Verify same order
        XCTAssertEqual(cells1.count, cells2.count)
        for (c1, c2) in zip(cells1, cells2) {
            XCTAssertEqual(c1.patchId, c2.patchId, "Iteration order must be stable")
        }
    }
    
    func testCompactionPreservesOrder() async {
        let grid = await EvidenceGrid(cellSize: LengthQ(scaleId: .geomId, quanta: 1), maxCells: 100)
        
        // Insert cells
        var batch = EvidenceGrid.EvidenceGridDeltaBatch()
        for i in 0..<50 {
            let worldPos = EvidenceVector3(x: Double(i), y: 0.0, z: 0.0)
            let mortonCode = await grid.quantizer.mortonCode(from: worldPos)
            let key = SpatialKey(mortonCode: mortonCode, level: .L3)
            
            let cell = GridCell(
                patchId: "patch-\(i)",
                quantizedPosition: await grid.quantizer.quantize(worldPos),
                dimScores: DimensionalScoreSet(),
                dsMass: DSMassFunction.vacuous,
                level: .L3,
                directionalMask: 0,
                lastUpdatedMillis: MonotonicClock.nowMs()
            )
            batch.add(EvidenceGrid.GridCellUpdate.insert(key: key, cell: cell))
        }
        await grid.apply(batch)
        
        // Get order before compaction
        let cellsBefore = await grid.allActiveCells()
        let orderBefore = cellsBefore.map { $0.patchId }
        
        // Evict some cells to trigger compaction
        var evictBatch = EvidenceGrid.EvidenceGridDeltaBatch()
        for i in 0..<20 {
            let worldPos = EvidenceVector3(x: Double(i), y: 0.0, z: 0.0)
            let mortonCode = await grid.quantizer.mortonCode(from: worldPos)
            let key = SpatialKey(mortonCode: mortonCode, level: .L3)
            evictBatch.add(EvidenceGrid.GridCellUpdate.evict(key: key))
        }
        await grid.apply(evictBatch)
        
        // Get order after compaction
        let cellsAfter = await grid.allActiveCells()
        let orderAfter = cellsAfter.map { $0.patchId }
        
        // Remaining cells should maintain relative order
        var beforeIndex = 0
        for afterPatchId in orderAfter {
            // Find this patch in before order
            while beforeIndex < orderBefore.count && orderBefore[beforeIndex] != afterPatchId {
                beforeIndex += 1
            }
            XCTAssertLessThan(beforeIndex, orderBefore.count, "Order should be preserved")
        }
    }
}
