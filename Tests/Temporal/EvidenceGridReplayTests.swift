// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// EvidenceGridReplayTests.swift
// Aether3D
//
// PR6 Evidence Grid System - Temporal Replay Tests
//

import XCTest
@testable import Aether3DCore

@EvidenceActor
final class EvidenceGridReplayTests: XCTestCase {
    
    func testRecordReplayIdentical() async {
        // Record: create observations
        let observations: [(worldPos: EvidenceVector3, patchId: String, level: EvidenceConfidenceLevel)] = [
            (EvidenceVector3(x: 1.0, y: 2.0, z: 3.0), "patch-1", .L3),
            (EvidenceVector3(x: 2.0, y: 3.0, z: 4.0), "patch-2", .L3),
            (EvidenceVector3(x: 3.0, y: 4.0, z: 5.0), "patch-3", .L2),
            (EvidenceVector3(x: 4.0, y: 5.0, z: 6.0), "patch-4", .L4),
            (EvidenceVector3(x: 5.0, y: 6.0, z: 7.0), "patch-5", .L3),
        ]
        
        // Replay into grid1
        let grid1 = EvidenceGrid(cellSize: LengthQ(scaleId: .geomId, quanta: 1), maxCells: 1000)
        for obs in observations {
            var batch = EvidenceGrid.EvidenceGridDeltaBatch()
            let mortonCode = grid1.quantizer.mortonCode(from: obs.worldPos)
            let key = SpatialKey(mortonCode: mortonCode, level: obs.level)
            let cell = GridCell(
                patchId: obs.patchId,
                quantizedPosition: grid1.quantizer.quantize(obs.worldPos),
                dimScores: DimensionalScoreSet(),
                dsMass: DSMassFunction.vacuous,
                level: obs.level,
                directionalMask: 0,
                lastUpdatedMillis: MonotonicClock.nowMs()
            )
            batch.add(EvidenceGrid.GridCellUpdate.insert(key: key, cell: cell))
            await grid1.apply(batch)
        }
        
        // Replay same sequence into grid2
        let grid2 = EvidenceGrid(cellSize: LengthQ(scaleId: .geomId, quanta: 1), maxCells: 1000)
        for obs in observations {
            var batch = EvidenceGrid.EvidenceGridDeltaBatch()
            let mortonCode = grid2.quantizer.mortonCode(from: obs.worldPos)
            let key = SpatialKey(mortonCode: mortonCode, level: obs.level)
            let cell = GridCell(
                patchId: obs.patchId,
                quantizedPosition: grid2.quantizer.quantize(obs.worldPos),
                dimScores: DimensionalScoreSet(),
                dsMass: DSMassFunction.vacuous,
                level: obs.level,
                directionalMask: 0,
                lastUpdatedMillis: MonotonicClock.nowMs()
            )
            batch.add(EvidenceGrid.GridCellUpdate.insert(key: key, cell: cell))
            await grid2.apply(batch)
        }
        
        // Compare states
        let cells1 = await grid1.allActiveCells()
        let cells2 = await grid2.allActiveCells()
        
        XCTAssertEqual(cells1.count, cells2.count, "Replayed grids should have same cell count")
        for (c1, c2) in zip(cells1, cells2) {
            XCTAssertEqual(c1.patchId, c2.patchId, "Replayed grids should have identical state")
        }
    }
}
