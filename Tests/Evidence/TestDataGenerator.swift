//
// TestDataGenerator.swift
// Aether3D
//
// PR2 Patch V4 - Test Data Generator
// Deterministic test data generation with fixed seed
//

import Foundation
@testable import Aether3DCore

/// Deterministic test data generator
public enum TestDataGenerator {
    
    /// Fixed seed for reproducibility
    private static let fixedSeed: UInt64 = 12345
    
    /// Fixed base timestamp (milliseconds)
    private static let fixedBaseTimestampMs: Int64 = 1000000000000  // Fixed: 2001-09-09
    
    /// Generate deterministic observation sequence
    ///
    /// - Parameters:
    ///   - count: Number of observations
    ///   - patchCount: Number of unique patches
    /// - Returns: Array of (observation, gateQuality, softQuality, verdict)
    public static func generateObservationSequence(
        count: Int = 100,
        patchCount: Int = 10
    ) -> [(EvidenceObservation, Double, Double, ObservationVerdict)] {
        var sequence: [(EvidenceObservation, Double, Double, ObservationVerdict)] = []
        
        // Use fixed seed for deterministic pseudo-randomness
        var state = fixedSeed
        
        for i in 0..<count {
            let patchId = "patch_\(i % patchCount)"
            let timestamp = Double(fixedBaseTimestampMs + Int64(i * 33)) / 1000.0  // 33ms intervals
            let frameId = "frame_\(i)"
            
            // Deterministic quality based on index and patch
            let patchOffset = Double(i % patchCount) * 0.1
            let gateQuality = 0.3 + patchOffset + Double(i) / Double(count) * 0.4
            let softQuality = gateQuality * 0.9
            
            // Deterministic verdict (every 20th is suspect)
            let verdict: ObservationVerdict = (i % 20 == 19) ? .suspect : .good
            
            let observation = EvidenceObservation(
                patchId: patchId,
                timestamp: timestamp,
                frameId: frameId
            )
            
            sequence.append((observation, gateQuality, softQuality, verdict))
        }
        
        return sequence
    }
    
    /// Generate deterministic evidence state
    public static func generateEvidenceState(
        patchCount: Int = 5
    ) -> EvidenceState {
        var patches: [String: PatchEntrySnapshot] = [:]
        
        for i in 0..<patchCount {
            let patchId = "patch_\(i)"
            let evidence = 0.2 + Double(i) * 0.15
            let timestampMs = fixedBaseTimestampMs + Int64(i * 1000)
            
            patches[patchId] = PatchEntrySnapshot(
                evidence: evidence,
                lastUpdateMs: timestampMs,
                observationCount: 5 + i * 2,
                bestFrameId: "frame_\(i * 3)",
                errorCount: i % 2,
                errorStreak: 0,
                lastGoodUpdateMs: timestampMs
            )
        }
        
        return EvidenceState(
            patches: patches,
            gateDisplay: 0.5,
            softDisplay: 0.45,
            lastTotalDisplay: 0.475,
            exportedAtMs: fixedBaseTimestampMs
        )
    }
}
