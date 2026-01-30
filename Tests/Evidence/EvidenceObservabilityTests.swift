//
// EvidenceObservabilityTests.swift
// Aether3D
//
// PR2 Patch V4 - Evidence Observability Tests
//

import XCTest
@testable import Aether3DCore

final class EvidenceObservabilityTests: XCTestCase {
    
    func testAdmissionDecisionEventStructure() throws {
        let event = AdmissionDecisionEvent(
            timestampMs: 1000000,
            patchId: "test_patch",
            allowed: true,
            qualityScale: 0.75,
            reasons: ["allowed"]
        )
        
        XCTAssertEqual(event.eventType, "admission_decision")
        XCTAssertEqual(event.timestampMs, 1000000)
        XCTAssertEqual(event.patchId, "test_patch")
        XCTAssertEqual(event.allowed, true)
        XCTAssertEqual(event.qualityScale, 0.75)
        XCTAssertEqual(event.reasons, ["allowed"])
        
        // Verify Codable
        let encoder = JSONEncoder()
        let data = try encoder.encode(event)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(AdmissionDecisionEvent.self, from: data)
        
        XCTAssertEqual(decoded.eventType, event.eventType)
        XCTAssertEqual(decoded.timestampMs, event.timestampMs)
    }
    
    func testLedgerUpdateEventStructure() throws {
        let event = LedgerUpdateEvent(
            timestampMs: 1000000,
            patchId: "test_patch",
            previousEvidence: 0.5,
            newEvidence: 0.6,
            verdict: "good",
            isLocked: false
        )
        
        XCTAssertEqual(event.eventType, "ledger_update")
        XCTAssertNotNil(event.patchId)
        XCTAssertGreaterThanOrEqual(event.newEvidence, event.previousEvidence)
    }
    
    func testDisplayUpdateEventStructure() throws {
        let event = DisplayUpdateEvent(
            timestampMs: 1000000,
            patchId: "test_patch",
            previousDisplay: 0.4,
            newDisplay: 0.5,
            delta: 0.1
        )
        
        XCTAssertEqual(event.eventType, "display_update")
        XCTAssertEqual(event.delta, event.newDisplay - event.previousDisplay, accuracy: 1e-9)
    }
    
    func testEventsContainNoPII() throws {
        // Verify events don't contain PII or non-deterministic data
        let events: [any EvidenceEvent] = [
            AdmissionDecisionEvent(
                timestampMs: 1000000,
                patchId: "patch_123",
                allowed: true,
                qualityScale: 0.8,
                reasons: ["allowed"]
            ),
            LedgerUpdateEvent(
                timestampMs: 1000000,
                patchId: "patch_123",
                previousEvidence: 0.5,
                newEvidence: 0.6,
                verdict: "good",
                isLocked: false
            )
        ]
        
        for event in events {
            // Verify patchId is deterministic (not user data)
            if let patchId = event.patchId {
                XCTAssertFalse(patchId.contains("@"), "Event should not contain email")
                XCTAssertFalse(patchId.contains(" "), "Event should not contain spaces (potential PII)")
            }
            
            // Verify timestamp is deterministic (Int64 ms, not Date())
            XCTAssertGreaterThan(event.timestampMs, 0)
            XCTAssertLessThan(event.timestampMs, Int64.max)
        }
    }
    
    func testEventsAreComplete() throws {
        let event = AggregatorUpdateEvent(
            timestampMs: 1000000,
            patchId: "test",
            totalEvidence: 0.5,
            patchCount: 10,
            bucketCount: 3
        )
        
        // All fields should be populated
        XCTAssertEqual(event.eventType, "aggregator_update")
        XCTAssertNotNil(event.patchId)
        XCTAssertGreaterThanOrEqual(event.totalEvidence, 0.0)
        XCTAssertGreaterThanOrEqual(event.patchCount, 0)
        XCTAssertGreaterThanOrEqual(event.bucketCount, 0)
    }
}
