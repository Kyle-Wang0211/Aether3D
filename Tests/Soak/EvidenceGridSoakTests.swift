//
// EvidenceGridSoakTests.swift
// Aether3D
//
// PR6 Evidence Grid System - Soak Tests
//

import XCTest
@testable import Aether3DCore

@EvidenceActor
final class EvidenceGridSoakTests: XCTestCase {
    
    func testLongSessionBoundedCellCount() async {
        let grid = EvidenceGrid(cellSize: LengthQ(scaleId: .geomId, quanta: 1), maxCells: 50000)
        
        // Simulate 10,000 frames
        for frame in 0..<10000 {
            var batch = EvidenceGrid.EvidenceGridDeltaBatch()
            
            // Add some cells each frame
            for i in 0..<10 {
                let worldPos = EvidenceVector3(
                    x: Double((frame * 10 + i) % 1000),
                    y: Double((frame * 10 + i) / 1000),
                    z: 0.0
                )
                let mortonCode = grid.quantizer.mortonCode(from: worldPos)
                let key = SpatialKey(mortonCode: mortonCode, level: .L3)
                
                let cell = GridCell(
                    patchId: "frame-\(frame)-cell-\(i)",
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
            
            // Verify cell count stays within MAX_CELLS
            let allCells = await grid.allActiveCells()
            XCTAssertLessThanOrEqual(allCells.count, 50000, 
                                    "Cell count must stay within MAX_CELLS at frame \(frame)")
        }
    }
}
