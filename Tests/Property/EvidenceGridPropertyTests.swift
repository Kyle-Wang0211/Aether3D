//
// EvidenceGridPropertyTests.swift
// Aether3D
//
// PR6 Evidence Grid System - Evidence Grid Property-Based Tests
//

import XCTest
@testable import Aether3DCore

@EvidenceActor
final class EvidenceGridPropertyTests: XCTestCase {
    
    func testRandomInsertDeterministic() async {
        // Insert 50 random cells, re-run with same sequence, verify same iteration order
        let grid1 = EvidenceGrid(cellSize: LengthQ(scaleId: .geomId, quanta: 1), maxCells: 1000)
        let grid2 = EvidenceGrid(cellSize: LengthQ(scaleId: .geomId, quanta: 1), maxCells: 1000)
        
        // Generate deterministic random sequence (seed-based)
        var randomPositions: [EvidenceVector3] = []
        for i in 0..<50 {
            // Deterministic "random" positions
            let x = Double(i * 7).truncatingRemainder(dividingBy: 100.0)
            let y = Double(i * 11).truncatingRemainder(dividingBy: 100.0)
            let z = Double(i * 13).truncatingRemainder(dividingBy: 100.0)
            randomPositions.append(EvidenceVector3(x: x, y: y, z: z))
        }
        
        // Insert into grid1
        var batch1 = EvidenceGrid.EvidenceGridDeltaBatch()
        for (i, pos) in randomPositions.enumerated() {
            let mortonCode = grid1.quantizer.mortonCode(from: pos)
            let key = SpatialKey(mortonCode: mortonCode, level: .L3)
            let cell = GridCell(
                patchId: "patch-\(i)",
                quantizedPosition: grid1.quantizer.quantize(pos),
                dimScores: DimensionalScoreSet(),
                dsMass: DSMassFunction.vacuous,
                level: .L3,
                directionalMask: 0,
                lastUpdatedMillis: MonotonicClock.nowMs()
            )
            batch1.add(EvidenceGrid.GridCellUpdate.insert(key: key, cell: cell))
        }
        await grid1.apply(batch1)
        
        // Insert into grid2 (same sequence)
        var batch2 = EvidenceGrid.EvidenceGridDeltaBatch()
        for (i, pos) in randomPositions.enumerated() {
            let mortonCode = grid2.quantizer.mortonCode(from: pos)
            let key = SpatialKey(mortonCode: mortonCode, level: .L3)
            let cell = GridCell(
                patchId: "patch-\(i)",
                quantizedPosition: grid2.quantizer.quantize(pos),
                dimScores: DimensionalScoreSet(),
                dsMass: DSMassFunction.vacuous,
                level: .L3,
                directionalMask: 0,
                lastUpdatedMillis: MonotonicClock.nowMs()
            )
            batch2.add(EvidenceGrid.GridCellUpdate.insert(key: key, cell: cell))
        }
        await grid2.apply(batch2)
        
        // Verify same iteration order
        let cells1 = await grid1.allActiveCells()
        let cells2 = await grid2.allActiveCells()
        
        XCTAssertEqual(cells1.count, cells2.count)
        for (c1, c2) in zip(cells1, cells2) {
            XCTAssertEqual(c1.patchId, c2.patchId, "Iteration order must be deterministic")
        }
    }
    
    func testMortonRoundTripIdentity() async {
        let quantizer = SpatialQuantizer(cellSize: LengthQ(scaleId: .geomId, quanta: 1))
        
        // Test 100 random positions
        for i in 0..<100 {
            // Deterministic "random" position
            let x = Double(i * 7).truncatingRemainder(dividingBy: 1000.0)
            let y = Double(i * 11).truncatingRemainder(dividingBy: 1000.0)
            let z = Double(i * 13).truncatingRemainder(dividingBy: 1000.0)
            let worldPos = EvidenceVector3(x: x, y: y, z: z)
            
            // Quantize → morton → decode → should match quantized
            let quantizedPos = quantizer.quantize(worldPos)
            let mortonCode = quantizer.mortonCode(x: quantizedPos.x, y: quantizedPos.y, z: quantizedPos.z)
            let decodedPos = quantizer.decodeMortonCode(mortonCode)
            
            XCTAssertEqual(decodedPos.x, quantizedPos.x, "Morton round-trip must preserve x")
            XCTAssertEqual(decodedPos.y, quantizedPos.y, "Morton round-trip must preserve y")
            XCTAssertEqual(decodedPos.z, quantizedPos.z, "Morton round-trip must preserve z")
        }
    }
}
