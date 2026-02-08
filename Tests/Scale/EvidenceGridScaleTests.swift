//
// EvidenceGridScaleTests.swift
// Aether3D
//
// PR6 Evidence Grid System - Scale Tests
//

import XCTest
@testable import Aether3DCore

@EvidenceActor
final class EvidenceGridScaleTests: XCTestCase {
    
    func testZeroCellsNoCrash() async {
        let grid = EvidenceGrid(cellSize: LengthQ(scaleId: .geomId, quanta: 1), maxCells: 100)
        let estimator = CoverageEstimator()
        
        // Empty grid should return 0% coverage, no crash
        let result = await estimator.update(grid: grid)
        XCTAssertEqual(result.coveragePercentage, 0.0, accuracy: 0.01)
    }
    
    func testHardCapEnforced() async {
        // Use small maxCells to test eviction
        let grid = EvidenceGrid(cellSize: LengthQ(scaleId: .geomId, quanta: 1), maxCells: 10)
        
        // Attempt to insert more than maxCells
        var batch = EvidenceGrid.EvidenceGridDeltaBatch()
        for i in 0..<20 {
            let worldPos = EvidenceVector3(x: Double(i), y: 0.0, z: 0.0)
            let mortonCode = grid.quantizer.mortonCode(from: worldPos)
            let key = SpatialKey(mortonCode: mortonCode, level: .L3)
            
            let cell = GridCell(
                patchId: "patch-\(i)",
                quantizedPosition: grid.quantizer.quantize(worldPos),
                dimScores: DimensionalScoreSet(),
                dsMass: DSMassFunction.vacuous,
                level: .L3,
                directionalMask: 0,
                lastUpdatedMillis: MonotonicClock.nowMs()
            )
            batch.add(EvidenceGrid.GridCellUpdate.insert(key: key, cell: cell))
        }
        
        await grid.apply(batch)
        
        // Should have evicted cells, no crash
        let allCells = await grid.allActiveCells()
        XCTAssertLessThanOrEqual(allCells.count, 10, "Hard cap must be enforced")
    }
}
