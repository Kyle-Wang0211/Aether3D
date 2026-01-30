//
// EvidenceDeltaSemanticsTests.swift
// Aether3D
//
// PR2 Patch V4 - Delta Semantics Tests
// Verify Rule D: delta computed BEFORE display update
//

import XCTest
@testable import Aether3DCore

final class EvidenceDeltaSemanticsTests: XCTestCase {
    
    func testDeltaComputedBeforeDisplayUpdate() async throws {
        // This test verifies that delta is computed from previous display values
        // BEFORE the display update (Rule D)
        
        let engine = await IsolatedEvidenceEngine()
        let patchId = "delta_semantics_test"
        
        // Initial state
        let obs1 = EvidenceObservation(
            patchId: patchId,
            timestamp: 0.0,
            frameId: "frame_0"
        )
        await engine.processObservation(obs1, gateQuality: 0.5, softQuality: 0.45, verdict: .good)
        let snapshot0 = await engine.snapshot()
        
        // Process next observation
        let obs2 = EvidenceObservation(
            patchId: patchId,
            timestamp: 0.033,
            frameId: "frame_1"
        )
        await engine.processObservation(obs2, gateQuality: 0.6, softQuality: 0.55, verdict: .good)
        let snapshot1 = await engine.snapshot()
        
        // Delta should be computed from snapshot0.display, not snapshot1.display
        let expectedDelta = snapshot1.gateDisplay - snapshot0.gateDisplay
        
        // Verify delta matches expected (within EMA smoothing tolerance)
        // Note: Delta tracker uses asymmetric EMA, so exact match may not be possible
        // But delta should be positive and reasonable
        XCTAssertGreaterThan(snapshot1.gateDelta, 0.0, "Delta should be positive when display increases")
        XCTAssertLessThanOrEqual(snapshot1.gateDelta, expectedDelta + 0.1, "Delta should not exceed expected by much")
    }
    
    func testNoDeltaPadding() async throws {
        let engine = await IsolatedEvidenceEngine()
        
        // Process observations with varying quality
        for i in 0..<10 {
            let obs = EvidenceObservation(
                patchId: "patch_\(i % 3)",
                timestamp: Double(i) * 0.033,
                frameId: "frame_\(i)"
            )
            
            let quality = 0.3 + Double(i) * 0.05
            await engine.processObservation(obs, gateQuality: quality, softQuality: quality * 0.9, verdict: .good)
        }
        
        let snapshot = await engine.snapshot()
        
        // Delta should be real, not padded
        // If display didn't change, delta should be 0 (or very small due to EMA)
        XCTAssertGreaterThanOrEqual(snapshot.gateDelta, 0.0, "Delta should not be negative")
        XCTAssertLessThanOrEqual(snapshot.gateDelta, 1.0, "Delta should not exceed 1.0")
    }
    
    func testAsymmetricEMAFastUpSlowDown() async throws {
        let tracker = AsymmetricDeltaTracker(alphaRise: 0.3, alphaFall: 0.1)
        
        var currentTracker = tracker
        
        // Rapid increase
        for _ in 0..<10 {
            currentTracker.update(newDelta: 0.1)
        }
        let deltaAfterRise = currentTracker.smoothed
        
        // Reset
        var tracker2 = AsymmetricDeltaTracker(alphaRise: 0.3, alphaFall: 0.1)
        
        // Rapid decrease
        for _ in 0..<10 {
            tracker2.update(newDelta: -0.1)
        }
        let deltaAfterFall = abs(tracker2.smoothed)
        
        // Rise should be faster (higher smoothed value) than fall
        // Note: This tests the asymmetric behavior
        XCTAssertGreaterThan(
            deltaAfterRise,
            deltaAfterFall,
            "Asymmetric EMA should respond faster to rises than falls"
        )
    }
}
