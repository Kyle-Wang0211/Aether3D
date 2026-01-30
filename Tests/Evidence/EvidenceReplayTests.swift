//
// EvidenceReplayTests.swift
// Aether3D
//
// PR2 Patch V4 - Evidence Replay Tests
//

import XCTest
@testable import Aether3DCore

final class EvidenceReplayTests: XCTestCase {
    
    func testReplayDeterminism() async throws {
        // Generate observation log
        let sequence = TestDataGenerator.generateObservationSequence(count: 30, patchCount: 3)
        
        var logEntries: [ObservationLogEntry] = []
        for (obs, gateQ, softQ, verdict) in sequence {
            logEntries.append(ObservationLogEntry(
                observation: obs,
                gateQuality: gateQ,
                softQuality: softQ,
                verdict: verdict,
                timestampMs: Int64(obs.timestamp * 1000)
            ))
        }
        
        // Replay twice
        let state1 = try await EvidenceReplayEngine.replay(logEntries: logEntries)
        let state2 = try await EvidenceReplayEngine.replay(logEntries: logEntries)
        
        // Results should be identical
        let differences = EvidenceReplayEngine.compareSnapshots(expected: state1, actual: state2)
        XCTAssertTrue(differences.isEmpty, "Replay should be deterministic. Differences: \(differences.joined(separator: ", "))")
    }
    
    func testReplayWithInitialState() async throws {
        // Create initial state
        let initialState = TestDataGenerator.generateEvidenceState(patchCount: 2)
        
        // Generate additional observations
        let sequence = TestDataGenerator.generateObservationSequence(count: 20, patchCount: 2)
        var logEntries: [ObservationLogEntry] = []
        for (obs, gateQ, softQ, verdict) in sequence {
            logEntries.append(ObservationLogEntry(
                observation: obs,
                gateQuality: gateQ,
                softQuality: softQ,
                verdict: verdict,
                timestampMs: Int64(obs.timestamp * 1000)
            ))
        }
        
        // Replay with initial state
        let finalState = try await EvidenceReplayEngine.replay(initialState: initialState, logEntries: logEntries)
        
        // Should have more patches than initial
        XCTAssertGreaterThanOrEqual(
            finalState.patches.count,
            initialState.patches.count,
            "Final state should have at least as many patches as initial"
        )
    }
    
    func testSnapshotDiff() throws {
        let state1 = TestDataGenerator.generateEvidenceState(patchCount: 3)
        let state2 = TestDataGenerator.generateEvidenceState(patchCount: 3)
        
        let data1 = try TrueDeterministicJSONEncoder.encodeEvidenceState(state1)
        let data2 = try TrueDeterministicJSONEncoder.encodeEvidenceState(state2)
        
        let diff = EvidenceSnapshotDiff.diff(expected: data1, actual: data2)
        
        // Should produce a diff description
        XCTAssertFalse(diff.isEmpty, "Diff should not be empty for different states")
    }
}
