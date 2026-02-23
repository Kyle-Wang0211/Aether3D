// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// EvidenceReplayEngine.swift
// Aether3D
//
// PR2 Patch V4 - Evidence Replay Engine
// Deterministic replay for forensics and testing
//

import Foundation

/// Observation log entry for replay
public struct ObservationLogEntry: Codable, Sendable {
    public let observation: EvidenceObservation
    public let gateQuality: Double
    public let softQuality: Double
    public let verdict: ObservationVerdict
    public let timestampMs: Int64
    
    public init(
        observation: EvidenceObservation,
        gateQuality: Double,
        softQuality: Double,
        verdict: ObservationVerdict,
        timestampMs: Int64
    ) {
        self.observation = observation
        self.gateQuality = gateQuality
        self.softQuality = softQuality
        self.verdict = verdict
        self.timestampMs = timestampMs
    }
}

/// Evidence replay engine
/// 
/// Capabilities:
/// - Load EvidenceState + Observation log
/// - Replay deterministically
/// - Compare snapshots
public final class EvidenceReplayEngine {
    
    /// Replay observations and return final state
    ///
    /// - Parameters:
    ///   - initialState: Initial EvidenceState (optional, defaults to empty)
    ///   - logEntries: Observation log entries in chronological order
    /// - Returns: Final EvidenceState after replay
    public static func replay(
        initialState: EvidenceState? = nil,
        logEntries: [ObservationLogEntry]
    ) async throws -> EvidenceState {
        let engine = await IsolatedEvidenceEngine()
        
        // Load initial state if provided
        if let initialState = initialState {
            let initialStateData = try TrueDeterministicJSONEncoder.encodeEvidenceState(initialState)
            try await engine.loadStateJSON(initialStateData)
        }
        
        // Replay all observations
        for entry in logEntries {
            await engine.processObservation(
                entry.observation,
                gateQuality: entry.gateQuality,
                softQuality: entry.softQuality,
                verdict: entry.verdict
            )
        }
        
        // Export final state
        let finalTimestampMs = logEntries.last?.timestampMs ?? Int64(Date().timeIntervalSince1970 * 1000)
        let finalStateData = try await engine.exportStateJSON(timestampMs: finalTimestampMs)
        return try JSONDecoder().decode(EvidenceState.self, from: finalStateData)
    }
    
    /// Compare two EvidenceState snapshots
    ///
    /// - Parameters:
    ///   - expected: Expected state
    ///   - actual: Actual state
    /// - Returns: Array of difference descriptions
    public static func compareSnapshots(
        expected: EvidenceState,
        actual: EvidenceState
    ) -> [String] {
        var differences: [String] = []
        
        // Compare displays
        if abs(expected.gateDisplay - actual.gateDisplay) > 1e-6 {
            differences.append("gateDisplay: expected \(expected.gateDisplay), got \(actual.gateDisplay)")
        }
        if abs(expected.softDisplay - actual.softDisplay) > 1e-6 {
            differences.append("softDisplay: expected \(expected.softDisplay), got \(actual.softDisplay)")
        }
        if abs(expected.lastTotalDisplay - actual.lastTotalDisplay) > 1e-6 {
            differences.append("lastTotalDisplay: expected \(expected.lastTotalDisplay), got \(actual.lastTotalDisplay)")
        }
        
        // Compare patches
        let expectedPatchIds = Set(expected.patches.keys)
        let actualPatchIds = Set(actual.patches.keys)
        
        if expectedPatchIds != actualPatchIds {
            let missing = expectedPatchIds.subtracting(actualPatchIds)
            let extra = actualPatchIds.subtracting(expectedPatchIds)
            if !missing.isEmpty {
                differences.append("Missing patches: \(missing.joined(separator: ", "))")
            }
            if !extra.isEmpty {
                differences.append("Extra patches: \(extra.joined(separator: ", "))")
            }
        }
        
        // Compare patch evidence values
        for patchId in expectedPatchIds.intersection(actualPatchIds) {
            let expectedPatch = expected.patches[patchId]!
            let actualPatch = actual.patches[patchId]!
            
            if abs(expectedPatch.evidence - actualPatch.evidence) > 1e-6 {
                differences.append("Patch \(patchId) evidence: expected \(expectedPatch.evidence), got \(actualPatch.evidence)")
            }
        }
        
        return differences
    }
}

/// Evidence snapshot diff utility
public enum EvidenceSnapshotDiff {
    
    /// Generate compact diff string
    public static func diff(
        expected: Data,
        actual: Data
    ) -> String {
        if expected == actual {
            return "No differences (byte-identical)"
        }
        
        // Try to decode and compare
        if let expectedState = try? JSONDecoder().decode(EvidenceState.self, from: expected),
           let actualState = try? JSONDecoder().decode(EvidenceState.self, from: actual) {
            let differences = EvidenceReplayEngine.compareSnapshots(expected: expectedState, actual: actualState)
            
            if differences.isEmpty {
                return "States differ but within tolerance"
            }
            
            return differences.joined(separator: "\n")
        }
        
        // Fallback: byte-level diff
        return "Byte-level difference: expected \(expected.count) bytes, got \(actual.count) bytes"
    }
}
