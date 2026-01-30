//
// EvidenceState.swift
// Aether3D
//
// PR2 Patch V4 - Evidence State (Codable Serialization)
// Cross-platform compatible state representation
//

import Foundation

/// Patch evidence entry snapshot
public struct PatchEntrySnapshot: Codable, Sendable {
    /// Current evidence value [0, 1]
    public let evidence: Double
    
    /// Last update timestamp (milliseconds)
    public let lastUpdateMs: Int64
    
    /// Observation count (for weight calculation)
    public let observationCount: Int
    
    /// Best observation frame ID
    public let bestFrameId: String?
    
    /// Total error count (for analytics)
    public let errorCount: Int
    
    /// Consecutive error streak (for penalty calculation)
    public let errorStreak: Int
    
    /// Last good (non-error) update timestamp (milliseconds, optional)
    public let lastGoodUpdateMs: Int64?
    
    public init(
        evidence: Double,
        lastUpdateMs: Int64,
        observationCount: Int,
        bestFrameId: String?,
        errorCount: Int,
        errorStreak: Int,
        lastGoodUpdateMs: Int64?
    ) {
        self.evidence = evidence
        self.lastUpdateMs = lastUpdateMs
        self.observationCount = observationCount
        self.bestFrameId = bestFrameId
        self.errorCount = errorCount
        self.errorStreak = errorStreak
        self.lastGoodUpdateMs = lastGoodUpdateMs
    }
}

/// Codable state for cross-platform serialization
public struct EvidenceState: Codable, Sendable {
    
    /// All patch snapshots
    public let patches: [String: PatchEntrySnapshot]
    
    /// Gate display evidence (global, monotonic)
    public let gateDisplay: Double
    
    /// Soft display evidence (global, monotonic)
    public let softDisplay: Double
    
    /// Last computed total display (for dynamic weights)
    public let lastTotalDisplay: Double
    
    /// Schema version for forward compatibility
    public let schemaVersion: String
    
    /// Export timestamp (milliseconds)
    public let exportedAtMs: Int64
    
    public static let currentSchemaVersion = "2.1"
    
    /// Minimum compatible schema version
    public static let minCompatibleVersion = "2.0"
    
    public init(
        patches: [String: PatchEntrySnapshot],
        gateDisplay: Double,
        softDisplay: Double,
        lastTotalDisplay: Double,
        exportedAtMs: Int64,
        schemaVersion: String = Self.currentSchemaVersion
    ) {
        self.patches = patches
        self.gateDisplay = gateDisplay
        self.softDisplay = softDisplay
        self.lastTotalDisplay = lastTotalDisplay
        self.schemaVersion = schemaVersion
        self.exportedAtMs = exportedAtMs
    }
    
    /// Check if version is compatible
    public static func isCompatible(version: String) -> Bool {
        // Simple semver comparison (major.minor)
        let current = currentSchemaVersion.split(separator: ".").compactMap { Int($0) }
        let check = version.split(separator: ".").compactMap { Int($0) }
        
        guard current.count >= 2, check.count >= 2 else { return false }
        
        // Same major version = compatible
        return check[0] == current[0]
    }
}

/// Extension to convert EvidenceState to CanonicalJSONValue
extension EvidenceState {
    /// Convert to canonical JSON value
    func toCanonicalJSON() throws -> CanonicalJSONValue {
        // Convert patches dictionary to ordered list
        let sortedPatchKeys = patches.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        let patchPairs = try sortedPatchKeys.map { key in
            let snapshot = patches[key]!
            let patchValue: CanonicalJSONValue = .object([
                ("evidence", .number(QuantizationPolicy.formatQuantized(snapshot.evidence))),
                ("lastUpdateMs", .int(snapshot.lastUpdateMs)),
                ("observationCount", .int(Int64(snapshot.observationCount))),
                ("bestFrameId", snapshot.bestFrameId.map { .string($0) } ?? .null),
                ("errorCount", .int(Int64(snapshot.errorCount))),
                ("errorStreak", .int(Int64(snapshot.errorStreak))),
                ("lastGoodUpdateMs", snapshot.lastGoodUpdateMs.map { .int($0) } ?? .null),
            ])
            return (key, patchValue)
        }
        
        return .object([
            ("patches", .object(patchPairs)),
            ("gateDisplay", .number(QuantizationPolicy.formatQuantized(gateDisplay))),
            ("softDisplay", .number(QuantizationPolicy.formatQuantized(softDisplay))),
            ("lastTotalDisplay", .number(QuantizationPolicy.formatQuantized(lastTotalDisplay))),
            ("schemaVersion", .string(schemaVersion)),
            ("exportedAtMs", .int(exportedAtMs)),
        ])
    }
}
