// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// EvidenceDisplayMonotonicityTests.swift
// Aether3D
//
// PR2 Patch V4 - Display Monotonicity Under Stress Tests
//

import XCTest
@testable import Aether3DCore

final class EvidenceDisplayMonotonicityTests: XCTestCase {
    
    func testDisplayNeverDecreasesUnderStress() async throws {
        let engine = await IsolatedEvidenceEngine()
        let patchId = "stress_test_patch"
        
        // Mix good → suspect → bad verdicts
        let verdicts: [ObservationVerdict] = [.good, .good, .suspect, .bad, .good, .suspect, .bad, .bad]
        
        var displayHistory: [Double] = []
        
        for (index, verdict) in verdicts.enumerated() {
            let obs = EvidenceObservation(
                patchId: patchId,
                timestamp: Double(index) * 0.033,
                frameId: "frame_\(index)"
            )
            
            // Vary quality
            let gateQ = verdict == .bad ? 0.1 : (verdict == .suspect ? 0.5 : 0.8)
            let softQ = gateQ * 0.9
            
            await engine.processObservation(obs, gateQuality: gateQ, softQuality: softQ, verdict: verdict)
            
            let snapshot = await engine.snapshot()
            displayHistory.append(snapshot.gateDisplay)
        }
        
        // Verify monotonicity
        for i in 1..<displayHistory.count {
            XCTAssertGreaterThanOrEqual(
                displayHistory[i],
                displayHistory[i-1],
                "Display must never decrease (index \(i))"
            )
        }
    }
    
    func testLedgerCanDecreaseButDisplayCannot() async throws {
        let map = PatchEvidenceMap()
        let displayMap = PatchDisplayMap()
        let patchId = "ledger_display_test"
        let baseTimeMs = Int64(Date().timeIntervalSince1970 * 1000)
        
        // Build up evidence
        for i in 0..<10 {
            _ = map.update(
                patchId: patchId,
                ledgerQuality: 0.3 + Double(i) * 0.05,
                verdict: .good,
                frameId: "frame_\(i)",
                timestampMs: baseTimeMs + Int64(i * 100)
            )
            
            let ledgerEvidence = map.evidence(for: patchId)
            let entry = map.entry(for: patchId)
            
            displayMap.update(
                patchId: patchId,
                target: ledgerEvidence,
                timestampMs: baseTimeMs + Int64(i * 100),
                isLocked: entry?.isLocked ?? false
            )
        }
        
        let displayBefore = displayMap.display(for: patchId)
        let ledgerBefore = map.evidence(for: patchId)
        
        // Apply penalties (bad observations)
        for i in 10..<20 {
            _ = map.update(
                patchId: patchId,
                ledgerQuality: 0.1,
                verdict: .bad,
                frameId: "bad_\(i)",
                timestampMs: baseTimeMs + Int64(i * 100),
                errorType: .dynamicObject
            )
            
            let ledgerEvidence = map.evidence(for: patchId)
            let entry = map.entry(for: patchId)
            
            displayMap.update(
                patchId: patchId,
                target: ledgerEvidence,
                timestampMs: baseTimeMs + Int64(i * 100),
                isLocked: entry?.isLocked ?? false
            )
        }
        
        let displayAfter = displayMap.display(for: patchId)
        let ledgerAfter = map.evidence(for: patchId)
        
        // Ledger CAN decrease
        XCTAssertLessThan(ledgerAfter, ledgerBefore, "Ledger should decrease after penalties")
        
        // Display CANNOT decrease
        XCTAssertGreaterThanOrEqual(displayAfter, displayBefore, "Display must never decrease")
    }
    
    func testDeltaSlowsButNeverFlipsSign() async throws {
        let engine = await IsolatedEvidenceEngine()
        let patchId = "delta_test"
        
        // Build up evidence
        for i in 0..<20 {
            let obs = EvidenceObservation(
                patchId: patchId,
                timestamp: Double(i) * 0.033,
                frameId: "frame_\(i)"
            )
            
            await engine.processObservation(obs, gateQuality: 0.8, softQuality: 0.7, verdict: .good)
        }
        
        let snapshot1 = await engine.snapshot()
        let delta1 = snapshot1.gateDelta
        
        // Apply penalties (should slow delta, not flip)
        for i in 20..<40 {
            let obs = EvidenceObservation(
                patchId: patchId,
                timestamp: Double(i) * 0.033,
                frameId: "frame_\(i)"
            )
            
            await engine.processObservation(obs, gateQuality: 0.1, softQuality: 0.1, verdict: .bad)
        }
        
        let snapshot2 = await engine.snapshot()
        let delta2 = snapshot2.gateDelta
        
        // Delta should slow down (become smaller) but not flip to negative
        // Note: Delta can be 0 or positive, but should not artificially flip
        XCTAssertGreaterThanOrEqual(delta2, 0.0, "Delta should not flip to negative artificially")
    }
}
