//
// EvidenceEndToEndDeterminismTests.swift
// Aether3D
//
// PR2 Patch V4 - End-to-End Determinism Tests
// Verify byte-identical output across multiple runs
//

import XCTest
@testable import Aether3DCore

final class EvidenceEndToEndDeterminismTests: XCTestCase {
    
    /// Test that identical input produces byte-identical output across 100 runs
    func testDeterministicEndToEnd() async throws {
        let sequence = TestDataGenerator.generateObservationSequence(count: 50, patchCount: 5)
        
        var outputs: Set<Data> = []
        
        // Fixed timestamp for determinism
        let fixedTimestampMs: Int64 = 1000000000000
        
        // Run 100 times
        for iteration in 0..<100 {
            let engine = await IsolatedEvidenceEngine()
            
            // Process all observations in exact same order
            for (obs, gateQ, softQ, verdict) in sequence {
                await engine.processObservation(
                    obs,
                    gateQuality: gateQ,
                    softQuality: softQ,
                    verdict: verdict
                )
            }
            
            // Export state with fixed timestamp
            let exported = try await engine.exportStateJSON(timestampMs: fixedTimestampMs)
            outputs.insert(exported)
            
            if iteration == 0 {
                // First iteration: verify it's valid JSON
                let state = try JSONDecoder().decode(EvidenceState.self, from: exported)
                XCTAssertGreaterThan(state.patches.count, 0, "Should have patches")
            }
            
            // Early exit if we detect non-determinism
            if outputs.count > 1 && iteration > 10 {
                XCTFail("Non-determinism detected after \(iteration) iterations. Found \(outputs.count) unique outputs.")
                return
            }
        }
        
        // All outputs must be identical
        XCTAssertEqual(
            outputs.count,
            1,
            "EvidenceState export MUST be byte-identical across 100 runs. Found \(outputs.count) unique outputs."
        )
    }
    
    /// Test that replay produces identical results
    func testReplayDeterminism() async throws {
        let sequence = TestDataGenerator.generateObservationSequence(count: 30, patchCount: 3)
        
        // First run
        let engine1 = await IsolatedEvidenceEngine()
        for (obs, gateQ, softQ, verdict) in sequence {
            await engine1.processObservation(obs, gateQuality: gateQ, softQuality: softQ, verdict: verdict)
        }
        let snapshot1 = await engine1.snapshot()
        let export1 = try await engine1.exportStateJSON()
        
        // Second run (replay)
        let engine2 = await IsolatedEvidenceEngine()
        for (obs, gateQ, softQ, verdict) in sequence {
            await engine2.processObservation(obs, gateQuality: gateQ, softQuality: softQ, verdict: verdict)
        }
        let snapshot2 = await engine2.snapshot()
        let export2 = try await engine2.exportStateJSON()
        
        // Exports must be byte-identical
        XCTAssertEqual(export1, export2, "Replay must produce identical export")
        
        // Snapshots must match
        XCTAssertEqual(snapshot1.gateDisplay, snapshot2.gateDisplay, accuracy: 1e-9)
        XCTAssertEqual(snapshot1.softDisplay, snapshot2.softDisplay, accuracy: 1e-9)
        XCTAssertEqual(snapshot1.totalEvidence, snapshot2.totalEvidence, accuracy: 1e-9)
    }
}
