//
// main.swift
// EvidenceGridCanonicalOutput
//
// PR6 Evidence Grid System - Canonical Output Generator
//
// Generates canonical JSON output from fixed golden observations
//

import Foundation
import Aether3DCore

@main
struct EvidenceGridCanonicalOutput {
    static func main() async {
        // Create fixed set of golden observations (hardcoded, deterministic)
        let observations: [(worldPos: EvidenceVector3, patchId: String, level: EvidenceConfidenceLevel)] = [
            (EvidenceVector3(x: 1.0, y: 2.0, z: 3.0), "patch-1", .L3),
            (EvidenceVector3(x: 2.0, y: 3.0, z: 4.0), "patch-2", .L3),
            (EvidenceVector3(x: 3.0, y: 4.0, z: 5.0), "patch-3", .L2),
            (EvidenceVector3(x: 4.0, y: 5.0, z: 6.0), "patch-4", .L4),
            (EvidenceVector3(x: 5.0, y: 6.0, z: 7.0), "patch-5", .L3),
            (EvidenceVector3(x: 6.0, y: 7.0, z: 8.0), "patch-6", .L5),
            (EvidenceVector3(x: 7.0, y: 8.0, z: 9.0), "patch-7", .L3),
            (EvidenceVector3(x: 8.0, y: 9.0, z: 10.0), "patch-8", .L4),
            (EvidenceVector3(x: 9.0, y: 10.0, z: 11.0), "patch-9", .L3),
            (EvidenceVector3(x: 10.0, y: 11.0, z: 12.0), "patch-10", .L5),
        ]
        
        // Create grid and process observations
        let grid = await EvidenceGrid(cellSize: LengthQ(scaleId: .geomId, quanta: 1), maxCells: 1000)
        let estimator = CoverageEstimator()
        let stateMachine = EvidenceStateMachine()
        let chain = ProvenanceChain()
        
        struct Result: Codable {
            let patchId: String
            let coverage: Double
            let state: String
            let provenanceHash: String
        }
        
        var results: [Result] = []
        
        // Use fixed timestamps for cross-platform determinism
        var fixedTimestamp: Int64 = 1000000

        for obs in observations {
            var batch = EvidenceGrid.EvidenceGridDeltaBatch()
            let mortonCode = await grid.quantizer.mortonCode(from: obs.worldPos)
            let key = SpatialKey(mortonCode: mortonCode, level: obs.level)

            let cell = GridCell(
                patchId: obs.patchId,
                quantizedPosition: await grid.quantizer.quantize(obs.worldPos),
                dimScores: DimensionalScoreSet(),
                dsMass: DSMassFunction.vacuous,
                level: obs.level,
                directionalMask: 0,
                lastUpdatedMillis: fixedTimestamp
            )
            batch.add(EvidenceGrid.GridCellUpdate.insert(key: key, cell: cell))
            await grid.apply(batch)

            // Compute coverage
            let coverageResult = await estimator.update(grid: grid)

            // Evaluate state
            let state = stateMachine.evaluate(coverage: coverageResult)

            // Append to provenance chain with fixed timestamp
            let hash = chain.appendTransition(
                timestampMillis: fixedTimestamp,
                fromState: stateMachine.getCurrentState(),
                toState: state,
                coverage: coverageResult.coveragePercentage,
                levelBreakdown: coverageResult.breakdownCounts,
                pizSummary: (count: 0, totalAreaSqM: 0.0, excludedAreaSqM: 0.0),
                gridDigest: "test-digest",
                policyDigest: "test-policy"
            )

            fixedTimestamp += 1000
            
            results.append(Result(
                patchId: obs.patchId,
                coverage: coverageResult.coveragePercentage,
                state: state.rawValue,
                provenanceHash: hash
            ))
        }
        
        // Output canonical JSON to stdout
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let jsonData = try encoder.encode(results)
            if let jsonString = String(data: jsonData, encoding: .utf8) {
                print(jsonString)
            }
        } catch {
            FileHandle.standardError.write(Data("Error encoding JSON: \(error)".utf8))
            exit(1)
        }
    }
}
