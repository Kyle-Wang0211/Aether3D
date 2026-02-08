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
    
    /// **Rule ID:** PR6_GRID_STATE_007
    /// PR6 Extension: Dimensional snapshots (v3.0)
    public let dimensionalSnapshots: [String: DimensionalScoreSet]?
    
    /// PR6 Extension: Coverage percentage (v3.0)
    public let coveragePercentage: Double?
    
    /// PR6 Extension: State machine state (v3.0)
    public let stateMachineState: ColorState?
    
    /// PR6 Extension: PIZ region count (v3.0)
    public let pizRegionCount: Int?
    
    public static let currentSchemaVersion = "3.0"  // PR6: Bumped to v3.0
    
    /// Minimum compatible schema version
    public static let minCompatibleVersion = "2.0"
    
    public init(
        patches: [String: PatchEntrySnapshot],
        gateDisplay: Double,
        softDisplay: Double,
        lastTotalDisplay: Double,
        exportedAtMs: Int64,
        schemaVersion: String = Self.currentSchemaVersion,
        dimensionalSnapshots: [String: DimensionalScoreSet]? = nil,
        coveragePercentage: Double? = nil,
        stateMachineState: ColorState? = nil,
        pizRegionCount: Int? = nil
    ) {
        self.patches = patches
        self.gateDisplay = gateDisplay
        self.softDisplay = softDisplay
        self.lastTotalDisplay = lastTotalDisplay
        self.schemaVersion = schemaVersion
        self.exportedAtMs = exportedAtMs
        self.dimensionalSnapshots = dimensionalSnapshots
        self.coveragePercentage = coveragePercentage
        self.stateMachineState = stateMachineState
        self.pizRegionCount = pizRegionCount
    }
    
    /// **Rule ID:** PR6_GRID_STATE_008
    /// Backward compatible decoding: v2.x loads with dimensional fields == nil
    enum CodingKeys: String, CodingKey {
        case patches
        case gateDisplay
        case softDisplay
        case lastTotalDisplay
        case schemaVersion
        case exportedAtMs
        case dimensionalSnapshots
        case coveragePercentage
        case stateMachineState
        case pizRegionCount
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.patches = try container.decode([String: PatchEntrySnapshot].self, forKey: .patches)
        self.gateDisplay = try container.decode(Double.self, forKey: .gateDisplay)
        self.softDisplay = try container.decode(Double.self, forKey: .softDisplay)
        self.lastTotalDisplay = try container.decode(Double.self, forKey: .lastTotalDisplay)
        self.schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
        self.exportedAtMs = try container.decode(Int64.self, forKey: .exportedAtMs)
        
        // PR6 v3.0 fields (optional for backward compatibility)
        self.dimensionalSnapshots = try container.decodeIfPresent([String: DimensionalScoreSet].self, forKey: .dimensionalSnapshots)
        self.coveragePercentage = try container.decodeIfPresent(Double.self, forKey: .coveragePercentage)
        self.stateMachineState = try container.decodeIfPresent(ColorState.self, forKey: .stateMachineState)
        self.pizRegionCount = try container.decodeIfPresent(Int.self, forKey: .pizRegionCount)
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(patches, forKey: .patches)
        try container.encode(gateDisplay, forKey: .gateDisplay)
        try container.encode(softDisplay, forKey: .softDisplay)
        try container.encode(lastTotalDisplay, forKey: .lastTotalDisplay)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(exportedAtMs, forKey: .exportedAtMs)
        
        // PR6 v3.0 fields
        try container.encodeIfPresent(dimensionalSnapshots, forKey: .dimensionalSnapshots)
        try container.encodeIfPresent(coveragePercentage, forKey: .coveragePercentage)
        try container.encodeIfPresent(stateMachineState, forKey: .stateMachineState)
        try container.encodeIfPresent(pizRegionCount, forKey: .pizRegionCount)
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
