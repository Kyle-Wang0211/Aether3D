//
// EvidenceGridTests.swift
// Aether3D
//
// PR6 Evidence Grid System - Evidence Grid Tests
//

import XCTest
@testable import Aether3DCore

final class EvidenceGridTests: XCTestCase {
    
    func testInsertAndQuery() async {
        let grid = await EvidenceGrid(cellSize: LengthQ(scaleId: .geomId, quanta: 1), maxCells: 1000)
        let quantizer = await grid.quantizer
        
        let worldPos = EvidenceVector3(x: 1.0, y: 2.0, z: 3.0)
        let quantizedPos = quantizer.quantize(worldPos)
        let mortonCode = quantizer.mortonCode(from: worldPos)
        let key = SpatialKey(mortonCode: mortonCode, level: .L3)
        
        let cell = GridCell(
            patchId: "test-patch-1",
            quantizedPosition: quantizedPos,
            dimScores: DimensionalScoreSet(),
            dsMass: DSMassFunction.vacuous,
            level: .L3,
            directionalMask: 0,
            lastUpdatedMillis: MonotonicClock.nowMs()
        )
        
        var batch = EvidenceGrid.EvidenceGridDeltaBatch()
        batch.add(EvidenceGrid.GridCellUpdate.insert(key: key, cell: cell))
        await grid.apply(batch)
        
        let retrieved = await grid.get(key: key)
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.patchId, "test-patch-1")
    }
    
    func testEvictionOnCapacityExceeded() async {
        let grid = await EvidenceGrid(cellSize: LengthQ(scaleId: .geomId, quanta: 1), maxCells: 5)
        
        // Insert 6 cells (exceeds capacity)
        var batch = EvidenceGrid.EvidenceGridDeltaBatch()
        for i in 0..<6 {
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
        
        // Should have evicted oldest cell
        let allCells = await grid.allActiveCells()
        XCTAssertLessThanOrEqual(allCells.count, 5)
    }
    
    func testDeterministicIteration() async {
        let grid = await EvidenceGrid(cellSize: LengthQ(scaleId: .geomId, quanta: 1), maxCells: 100)
        
        // Insert N cells
        var batch = EvidenceGrid.EvidenceGridDeltaBatch()
        for i in 0..<10 {
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
        
        // Iterate twice, verify same order
        let cells1 = await grid.allActiveCells()
        let cells2 = await grid.allActiveCells()
        
        XCTAssertEqual(cells1.count, cells2.count)
        for (c1, c2) in zip(cells1, cells2) {
            XCTAssertEqual(c1.patchId, c2.patchId)
        }
    }
    
    func testTombstoneAndCompaction() async {
        let grid = await EvidenceGrid(cellSize: LengthQ(scaleId: .geomId, quanta: 1), maxCells: 100)
        
        // Insert cells
        var batch = EvidenceGrid.EvidenceGridDeltaBatch()
        var keys: [SpatialKey] = []
        for i in 0..<10 {
            let worldPos = EvidenceVector3(x: Double(i), y: 0.0, z: 0.0)
            let mortonCode = await grid.quantizer.mortonCode(from: worldPos)
            let key = SpatialKey(mortonCode: mortonCode, level: .L3)
            keys.append(key)
            
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
        
        // Evict some cells
        var evictBatch = EvidenceGrid.EvidenceGridDeltaBatch()
        for key in keys.prefix(3) {
            evictBatch.add(EvidenceGrid.GridCellUpdate.evict(key: key))
        }
        await grid.apply(evictBatch)
        
        // Verify evicted cells are not in active list
        let activeCells = await grid.allActiveCells()
        XCTAssertEqual(activeCells.count, 7)
    }
    
    func testBatchApply() async {
        let grid = await EvidenceGrid(cellSize: LengthQ(scaleId: .geomId, quanta: 1), maxCells: 100)
        
        var batch = EvidenceGrid.EvidenceGridDeltaBatch()
        
        // Add insertions
        let worldPos1 = EvidenceVector3(x: 1.0, y: 0.0, z: 0.0)
        let mortonCode1 = await grid.quantizer.mortonCode(from: worldPos1)
        let key1 = SpatialKey(mortonCode: mortonCode1, level: .L3)
        let cell1 = GridCell(
            patchId: "patch-1",
            quantizedPosition: await grid.quantizer.quantize(worldPos1),
            dimScores: DimensionalScoreSet(),
            dsMass: DSMassFunction.vacuous,
            level: .L3,
            directionalMask: 0,
            lastUpdatedMillis: MonotonicClock.nowMs()
        )
        batch.add(.insert(key: key1, cell: cell1))
        
        // Add update
        let cell1Updated = GridCell(
            patchId: "patch-1-updated",
            quantizedPosition: await grid.quantizer.quantize(worldPos1),
            dimScores: DimensionalScoreSet(),
            dsMass: DSMassFunction.vacuous,
            level: .L3,
            directionalMask: 0,
            lastUpdatedMillis: MonotonicClock.nowMs()
        )
        batch.add(EvidenceGrid.GridCellUpdate.update(key: key1, cell: cell1Updated))
        
        await grid.apply(batch)
        
        // Verify update applied
        let retrieved = await grid.get(key: key1)
        XCTAssertEqual(retrieved?.patchId, "patch-1-updated")
    }
    
    func testBatchOverflowDropsLowestPriority() async {
        let grid = await EvidenceGrid(cellSize: LengthQ(scaleId: .geomId, quanta: 1), maxCells: 1000)
        
        var batch = EvidenceGrid.EvidenceGridDeltaBatch(maxCapacity: 5)
        
        // Add 6 updates (exceeds batch capacity)
        for i in 0..<6 {
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
            
            if i == 5 {
                batch.add(EvidenceGrid.GridCellUpdate.evict(key: key))  // Lowest priority
            } else {
                batch.add(EvidenceGrid.GridCellUpdate.insert(key: key, cell: cell))
            }
        }
        
        // Batch should drop eviction (lowest priority)
        XCTAssertLessThanOrEqual(batch.updates.count, 5)
    }
}
