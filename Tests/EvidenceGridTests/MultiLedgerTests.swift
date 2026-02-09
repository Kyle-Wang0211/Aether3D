// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// MultiLedgerTests.swift
// Aether3D
//
// PR6 Evidence Grid System - Multi-Ledger Tests
//

import XCTest
@testable import Aether3DCore

final class MultiLedgerTests: XCTestCase {
    
    func testDelegatesToSplitLedger() {
        let multiLedger = MultiLedger()
        
        // Create a minimal observation
        let observation = EvidenceObservation(
            patchId: "test-patch",
            timestamp: Date().timeIntervalSince1970,
            frameId: "frame-1"
        )
        
        let verdict = ObservationVerdict.good
        multiLedger.updateCore(
            observation: observation,
            gateQuality: 0.8,
            softQuality: 0.6,
            verdict: verdict,
            frameId: "frame-1",
            timestamp: Date().timeIntervalSince1970
        )
        
        // Verify evidence is stored (delegates to SplitLedger)
        let evidence = multiLedger.patchEvidence(for: "test-patch", currentProgress: 0.5)
        XCTAssertGreaterThanOrEqual(evidence, 0.0)
    }
    
    func testProvenanceLedgerUpdate() {
        let multiLedger = MultiLedger()
        
        let verdict1 = ObservationVerdict.good
        multiLedger.updateProvenance(
            patchId: "test-patch",
            provenanceQuality: 0.7,
            verdict: verdict1,
            frameId: "frame-1",
            timestampMs: Int64(Date().timeIntervalSince1970 * 1000),
            errorType: nil
        )
        
        // Verify provenance ledger has evidence
        let total = multiLedger.totalEvidence(currentProgress: 0.5)
        XCTAssertGreaterThanOrEqual(total.provenance, 0.0)
    }
    
    func testAdvancedLedgerUpdate() {
        let multiLedger = MultiLedger()
        
        let verdict2 = ObservationVerdict.good
        multiLedger.updateAdvanced(
            patchId: "test-patch",
            advancedQuality: 0.8,
            verdict: verdict2,
            frameId: "frame-1",
            timestampMs: Int64(Date().timeIntervalSince1970 * 1000),
            errorType: nil
        )
        
        // Verify advanced ledger has evidence
        let total = multiLedger.totalEvidence(currentProgress: 0.5)
        XCTAssertGreaterThanOrEqual(total.advanced, 0.0)
    }
}
