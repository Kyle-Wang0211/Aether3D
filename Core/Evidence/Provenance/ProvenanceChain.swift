// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// ProvenanceChain.swift
// Aether3D
//
// PR6 Evidence Grid System - Provenance Chain
// SHA-256 hash chain for state transitions with canonical serialization
//

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// **Rule ID:** PR6_GRID_PROVENANCE_001
/// Provenance Chain: maintains SHA-256 hash chain for state transitions
public final class ProvenanceChain: @unchecked Sendable {
    
    /// Chain entries
    private var entries: [ProvenanceEntry] = []
    
    /// Last hash (for chain continuation)
    private var lastHash: String = ""
    
    public init() {}
    
    /// **Rule ID:** PR6_GRID_PROVENANCE_002
    /// Append transition to chain
    ///
    /// - Parameters:
    ///   - timestampMillis: Timestamp in milliseconds
    ///   - fromState: Source ColorState
    ///   - toState: Target ColorState
    ///   - coverage: Coverage percentage [0, 1]
    ///   - levelBreakdown: Level breakdown counts [L0..L6]
    ///   - pizSummary: PIZ summary (count, totalArea, excludedArea)
    ///   - gridDigest: Grid digest (rolling hash of stable key list)
    ///   - policyDigest: Policy digest (hash of all SSOT constants)
    /// - Returns: New hash
    public func appendTransition(
        timestampMillis: Int64,
        fromState: ColorState,
        toState: ColorState,
        coverage: Double,
        levelBreakdown: [Int],
        pizSummary: (count: Int, totalAreaSqM: Double, excludedAreaSqM: Double),
        gridDigest: String,
        policyDigest: String
    ) -> String {
        // Compute coverage quantized (basis points)
        let coverageQuantized = Int32(coverage * 10000)
        
        // Compute level breakdown digest
        let levelBreakdownDigest = computeLevelBreakdownDigest(levelBreakdown)
        
        // Compute PIZ summary digest
        let pizSummaryDigest = computePIZSummaryDigest(pizSummary)
        
        // **Rule ID:** PR6_GRID_PROVENANCE_003
        // Canonical serialization (MUST-FIX F + L + W)
        // Field order: timestampMillis|fromState|toState|coverageQuantized|levelBreakdownDigest|pizSummaryDigest|gridDigest|policyDigest|prevHash
        let canonicalString = [
            String(timestampMillis),                    // Int64 → decimal ASCII
            fromState.rawValue,                         // ColorState rawValue string (deterministic)
            toState.rawValue,                           // ColorState rawValue string (deterministic)
            String(coverageQuantized),                  // Int32 → decimal ASCII
            levelBreakdownDigest,                       // String → UTF-8
            pizSummaryDigest,                          // String → UTF-8
            gridDigest,                                // String → UTF-8
            policyDigest,                              // String → UTF-8
            lastHash                                   // lowercase hex ASCII
        ].joined(separator: "|")
        
        // Compute SHA-256 hash
        let data = canonicalString.data(using: .utf8)!
        let hash = SHA256.hash(data: data)
        let hashString = hash.compactMap { String(format: "%02x", $0) }.joined()
        
        // Create entry
        let entry = ProvenanceEntry(
            timestampMillis: timestampMillis,
            fromState: fromState,
            toState: toState,
            coverageQuantized: coverageQuantized,
            levelBreakdownDigest: levelBreakdownDigest,
            pizSummaryDigest: pizSummaryDigest,
            gridDigest: gridDigest,
            policyDigest: policyDigest,
            prevHash: lastHash,
            hash: hashString
        )
        
        entries.append(entry)
        lastHash = hashString
        
        return hashString
    }
    
    /// **Rule ID:** PR6_GRID_PROVENANCE_004
    /// Verify chain integrity
    ///
    /// - Returns: true if chain is valid, false if tampered
    public func verifyChain() -> Bool {
        var prevHash = ""
        
        for entry in entries {
            // Recompute canonical string
            let canonicalString = [
                String(entry.timestampMillis),
                entry.fromState.rawValue,
                entry.toState.rawValue,
                String(entry.coverageQuantized),
                entry.levelBreakdownDigest,
                entry.pizSummaryDigest,
                entry.gridDigest,
                entry.policyDigest,
                prevHash
            ].joined(separator: "|")
            
            // Recompute hash
            let data = canonicalString.data(using: .utf8)!
            let hash = SHA256.hash(data: data)
            let hashString = hash.compactMap { String(format: "%02x", $0) }.joined()
            
            // Verify
            if hashString != entry.hash {
                return false  // Tampered
            }
            
            prevHash = hashString
        }
        
        return true
    }
    
    /// **Rule ID:** PR6_GRID_PROVENANCE_005
    /// Export C2PA assertions skeleton (stub for future signing)
    ///
    /// - Returns: C2PA assertion structure (Data)
    public func exportAssertionsSkeleton() -> Data {
        // Stub: return empty data for now
        // Future: implement C2PA assertion structure
        return Data()
    }
    
    // MARK: - Helper Methods
    
    /// Compute level breakdown digest
    private func computeLevelBreakdownDigest(_ breakdown: [Int]) -> String {
        // Canonical serialization: "L0=count\nL1=count\n..."
        let canonical = breakdown.enumerated().map { index, count in
            "L\(index)=\(count)"
        }.joined(separator: "\n")
        
        let data = canonical.data(using: .utf8)!
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
    
    /// Compute PIZ summary digest
    private func computePIZSummaryDigest(_ summary: (count: Int, totalAreaSqM: Double, excludedAreaSqM: Double)) -> String {
        // Canonical serialization: "count=value\ntotalAreaSqM=value\nexcludedAreaSqM=value"
        let canonical = [
            "count=\(summary.count)",
            "totalAreaSqM=\(summary.totalAreaSqM)",
            "excludedAreaSqM=\(summary.excludedAreaSqM)"
        ].joined(separator: "\n")
        
        let data = canonical.data(using: .utf8)!
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
    
    /// Reset chain
    public func reset() {
        entries.removeAll()
        lastHash = ""
    }
}

/// **Rule ID:** PR6_GRID_PROVENANCE_006
/// Provenance entry: single transition record
public struct ProvenanceEntry: Codable, Sendable {
    public let timestampMillis: Int64
    public let fromState: ColorState
    public let toState: ColorState
    public let coverageQuantized: Int32
    public let levelBreakdownDigest: String
    public let pizSummaryDigest: String
    public let gridDigest: String
    public let policyDigest: String
    public let prevHash: String
    public let hash: String
    
    public init(
        timestampMillis: Int64,
        fromState: ColorState,
        toState: ColorState,
        coverageQuantized: Int32,
        levelBreakdownDigest: String,
        pizSummaryDigest: String,
        gridDigest: String,
        policyDigest: String,
        prevHash: String,
        hash: String
    ) {
        self.timestampMillis = timestampMillis
        self.fromState = fromState
        self.toState = toState
        self.coverageQuantized = coverageQuantized
        self.levelBreakdownDigest = levelBreakdownDigest
        self.pizSummaryDigest = pizSummaryDigest
        self.gridDigest = gridDigest
        self.policyDigest = policyDigest
        self.prevHash = prevHash
        self.hash = hash
    }
}
