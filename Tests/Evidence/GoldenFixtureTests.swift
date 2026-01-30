//
// GoldenFixtureTests.swift
// Aether3D
//
// PR2 Patch V4 - Golden Fixture Tests
// Regression testing with committed golden files
//

import XCTest
@testable import Aether3DCore

/// Golden fixture testing for behavior lock
///
/// CONCEPT:
/// - Store "golden" (known-good) outputs in test fixtures
/// - Compare current output against golden
/// - Fail CI if mismatch detected
/// - Update golden only after explicit human review
final class GoldenFixtureTests: XCTestCase {
    
    /// Path to golden fixtures
    static let goldenFixturePath = "Tests/Evidence/Fixtures/Golden/"
    
    // MARK: - Deterministic JSON Test
    
    func testDeterministicJSON_GoldenFixture() throws {
        // Create standardized test state
        let state = GoldenFixtureTests.createStandardTestState()
        
        // Encode with deterministic encoder
        let encoded = try TrueDeterministicJSONEncoder.encodeEvidenceState(state)
        
        // Load golden fixture
        let goldenPath = URL(fileURLWithPath: Self.goldenFixturePath + "evidence_state_v2.1.json")
        
        // If golden doesn't exist, create it (first run)
        if !FileManager.default.fileExists(atPath: goldenPath.path) {
            try encoded.write(to: goldenPath)
            XCTFail("Golden fixture created. Please review and commit: \(goldenPath.path)")
            return
        }
        
        let goldenData = try Data(contentsOf: goldenPath)
        
        // Compare byte-for-byte
        XCTAssertEqual(
            encoded, goldenData,
            "Deterministic JSON output differs from golden fixture. " +
            "If this is intentional, update the golden fixture after review."
        )
    }
    
    // MARK: - Evidence Progression Test
    
    func testEvidenceProgression_GoldenFixture() async throws {
        // Create engine and process standard sequence
        let engine = await IsolatedEvidenceEngine()
        let observations = GoldenFixtureTests.createStandardObservationSequence()
        
        var snapshots: [EvidenceSnapshot] = []
        
        for (obs, gateQ, softQ, verdict) in observations {
            await engine.processObservation(
                obs,
                gateQuality: gateQ,
                softQuality: softQ,
                verdict: verdict
            )
            snapshots.append(await engine.snapshot())
        }
        
        // Load golden progression
        let goldenPath = URL(fileURLWithPath: Self.goldenFixturePath + "progression_standard.json")
        
        // If golden doesn't exist, create it
        if !FileManager.default.fileExists(atPath: goldenPath.path) {
            let encoded = try JSONEncoder().encode(snapshots)
            try encoded.write(to: goldenPath)
            XCTFail("Golden progression created. Please review and commit: \(goldenPath.path)")
            return
        }
        
        let goldenData = try Data(contentsOf: goldenPath)
        let goldenSnapshots = try JSONDecoder().decode([EvidenceSnapshot].self, from: goldenData)
        
        // Compare with tolerance
        XCTAssertEqual(snapshots.count, goldenSnapshots.count)
        
        for (i, (actual, expected)) in zip(snapshots, goldenSnapshots).enumerated() {
            XCTAssertEqual(
                actual.gateDisplay, expected.gateDisplay,
                accuracy: 0.0001,
                "Frame \(i): gateDisplay mismatch"
            )
            XCTAssertEqual(
                actual.softDisplay, expected.softDisplay,
                accuracy: 0.0001,
                "Frame \(i): softDisplay mismatch"
            )
        }
    }
    
    // MARK: - Test Data Generators
    
    static func createStandardTestState() -> EvidenceState {
        // Returns identical state every time
        // Used for deterministic JSON testing
        let patches: [String: PatchEntrySnapshot] = [
            "patch_0": PatchEntrySnapshot(
                evidence: 0.3,
                lastUpdateMs: 1000,
                observationCount: 5,
                bestFrameId: "frame_2",
                errorCount: 0,
                errorStreak: 0,
                lastGoodUpdateMs: 1000
            ),
            "patch_1": PatchEntrySnapshot(
                evidence: 0.6,
                lastUpdateMs: 2000,
                observationCount: 10,
                bestFrameId: "frame_5",
                errorCount: 1,
                errorStreak: 0,
                lastGoodUpdateMs: 2000
            ),
            "patch_2": PatchEntrySnapshot(
                evidence: 0.9,
                lastUpdateMs: 3000,
                observationCount: 20,
                bestFrameId: "frame_10",
                errorCount: 0,
                errorStreak: 0,
                lastGoodUpdateMs: 3000
            ),
        ]
        
        return EvidenceState(
            patches: patches,
            gateDisplay: 0.5,
            softDisplay: 0.45,
            lastTotalDisplay: 0.475,
            exportedAtMs: 1234567890  // Fixed timestamp for determinism
        )
    }
    
    static func createStandardObservationSequence() -> [(EvidenceObservation, Double, Double, ObservationVerdict)] {
        // Returns identical sequence every time
        // Used for progression testing
        var sequence: [(EvidenceObservation, Double, Double, ObservationVerdict)] = []
        
        for i in 0..<100 {
            let obs = EvidenceObservation(
                patchId: "patch_\(i % 10)",
                timestamp: Double(i) * 0.033,
                frameId: "frame_\(i)"
            )
            let gateQ = 0.3 + Double(i) / 200.0
            let softQ = gateQ * 0.9
            let verdict: ObservationVerdict = i % 20 == 19 ? .suspect : .good
            
            sequence.append((obs, gateQ, softQ, verdict))
        }
        
        return sequence
    }
}

// IsolatedEvidenceEngine and EvidenceSnapshot are implemented in Core/Evidence/
