// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// EvidenceGridConcurrencyTests.swift
// Aether3D
//
// PR6 Evidence Grid System - Concurrency Tests
//

import XCTest
@testable import Aether3DCore

@EvidenceActor
final class EvidenceGridConcurrencyTests: XCTestCase {
    
    func testSnapshotConsistency() async {
        let grid = EvidenceGrid(cellSize: LengthQ(scaleId: .geomId, quanta: 1), maxCells: 1000)
        
        // Insert initial cells
        var batch1 = EvidenceGrid.EvidenceGridDeltaBatch()
        for i in 0..<50 {
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
            batch1.add(EvidenceGrid.GridCellUpdate.insert(key: key, cell: cell))
        }
        await grid.apply(batch1)
        
        // Take snapshot
        let snapshot1 = await grid.allActiveCells()
        let count1 = snapshot1.count
        
        // Apply batch
        var batch2 = EvidenceGrid.EvidenceGridDeltaBatch()
        for i in 50..<60 {
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
            batch2.add(EvidenceGrid.GridCellUpdate.insert(key: key, cell: cell))
        }
        await grid.apply(batch2)
        
        // Take another snapshot
        let snapshot2 = await grid.allActiveCells()
        let count2 = snapshot2.count
        
        // Both snapshots should be internally consistent
        XCTAssertEqual(count1, 50, "First snapshot should have 50 cells")
        XCTAssertEqual(count2, 60, "Second snapshot should have 60 cells")
    }
}
