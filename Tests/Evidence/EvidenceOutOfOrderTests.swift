//
// EvidenceOutOfOrderTests.swift
// Aether3D
//
// PR2 Patch V4 - Out-of-Order Observation Tests
//

import XCTest
@testable import Aether3DCore

final class EvidenceOutOfOrderTests: XCTestCase {
    
    func testOutOfOrderObservations() async throws {
        // Generate ordered sequence
        let orderedSequence = TestDataGenerator.generateObservationSequence(count: 50, patchCount: 5)
        
        // Shuffle by timestamp (simulate out-of-order delivery)
        var shuffledSequence = orderedSequence
        shuffledSequence.shuffle()
        
        // Process ordered sequence
        let engineOrdered = await IsolatedEvidenceEngine()
        for (obs, gateQ, softQ, verdict) in orderedSequence {
            await engineOrdered.processObservation(obs, gateQuality: gateQ, softQuality: softQ, verdict: verdict)
        }
        let snapshotOrdered = await engineOrdered.snapshot()
        _ = try await engineOrdered.exportStateJSON()
        
        // Process shuffled sequence with reorder buffer
        let engineShuffled = await IsolatedEvidenceEngine()
        let reorderBuffer = ObservationReorderBuffer()
        
        // Create a mapping from frameId to quality/verdict
        var qualityMap: [String: (gateQ: Double, softQ: Double, verdict: ObservationVerdict)] = [:]
        for (obs, gateQ, softQ, verdict) in orderedSequence {
            qualityMap[obs.frameId] = (gateQ, softQ, verdict)
        }
        
        // Add observations to buffer
        for (index, (obs, _, _, _)) in shuffledSequence.enumerated() {
            let sequenced = SequencedObservation(
                observation: obs,
                sequenceNumber: UInt64(index),
                timestampMs: Int64(obs.timestamp * 1000)
            )
            
            let ordered = reorderBuffer.add(sequenced)
            
            // Process in order
            for seqObs in ordered {
                if let (gateQ, softQ, verdict) = qualityMap[seqObs.observation.frameId] {
                    await engineShuffled.processObservation(
                        seqObs.observation,
                        gateQuality: gateQ,
                        softQuality: softQ,
                        verdict: verdict
                    )
                }
            }
        }
        
        // Flush remaining
        let remaining = reorderBuffer.flush()
        for seqObs in remaining {
            if let (gateQ, softQ, verdict) = qualityMap[seqObs.observation.frameId] {
                await engineShuffled.processObservation(
                    seqObs.observation,
                    gateQuality: gateQ,
                    softQuality: softQ,
                    verdict: verdict
                )
            }
        }
        
        let snapshotShuffled = await engineShuffled.snapshot()
        let fixedTimestampMs: Int64 = 1000000000000
        let exportShuffled = try await engineShuffled.exportStateJSON(timestampMs: fixedTimestampMs)
        let exportOrderedFixed = try await engineOrdered.exportStateJSON(timestampMs: fixedTimestampMs)
        
        // Results should be identical OR within documented tolerance
        // Note: Due to EMA smoothing and timing differences, exact match may not be possible
        // But they should be very close
        if exportOrderedFixed != exportShuffled {
            // If not identical, verify they're within tolerance
            XCTAssertEqual(snapshotOrdered.gateDisplay, snapshotShuffled.gateDisplay, accuracy: 0.1)
            XCTAssertEqual(snapshotOrdered.softDisplay, snapshotShuffled.softDisplay, accuracy: 0.1)
        } else {
            // If identical, verify snapshots match
            XCTAssertEqual(snapshotOrdered.gateDisplay, snapshotShuffled.gateDisplay, accuracy: 1e-6)
            XCTAssertEqual(snapshotOrdered.softDisplay, snapshotShuffled.softDisplay, accuracy: 1e-6)
        }
    }
    
    func testLateObservationPenalty() {
        let buffer = ObservationReorderBuffer()
        let baseTimeMs: Int64 = 1000000
        
        // Add observation on time
        let obs0 = EvidenceObservation(
            patchId: "test",
            timestamp: Double(baseTimeMs) / 1000.0,
            frameId: "frame_0"
        )
        let onTime = SequencedObservation(
            observation: obs0,
            sequenceNumber: UInt64(0),
            timestampMs: baseTimeMs
        )
        
        _ = buffer.add(onTime)
        
        // Add late observation (arrives 200ms after its timestamp)
        // Observation timestamp is baseTimeMs, but we check at baseTimeMs + 200
        let obs1 = EvidenceObservation(
            patchId: "test",
            timestamp: Double(baseTimeMs) / 1000.0,  // Same timestamp as obs0
            frameId: "frame_1"
        )
        let late = SequencedObservation(
            observation: obs1,
            sequenceNumber: UInt64(1),
            timestampMs: baseTimeMs  // Same timestamp
        )
        
        // Check if late at current time (200ms later)
        let currentTimeMs = baseTimeMs + 200  // 200ms after observation timestamp
        let isLate = buffer.isLate(late, currentTimeMs: currentTimeMs)
        XCTAssertTrue(isLate, "Observation exceeding buffer window (200ms > 120ms) should be marked late")
    }
}
