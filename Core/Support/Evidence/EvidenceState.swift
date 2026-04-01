// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// EvidenceState.swift
// Aether3D
//
// Minimal snapshot representation kept for whitebox closed-loop exports.
//

import Foundation

/// Patch evidence entry snapshot
public struct PatchEntrySnapshot: Codable, Sendable {
    public let evidence: Double
    public let lastUpdateMs: Int64
    public let observationCount: Int
    public let bestFrameId: String?
    public let errorCount: Int
    public let errorStreak: Int
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

/// Lightweight evidence snapshot kept only for compatibility and export.
public struct EvidenceState: Codable, Sendable {
    public let patches: [String: PatchEntrySnapshot]
    public let gateDisplay: Double
    public let softDisplay: Double
    public let lastTotalDisplay: Double
    public let schemaVersion: String
    public let exportedAtMs: Int64
    public let coveragePercentage: Double?
    public let stateMachineState: ColorState?
    public let pizRegionCount: Int?

    public static let currentSchemaVersion = "3.1"
    public static let minCompatibleVersion = "2.0"

    public init(
        patches: [String: PatchEntrySnapshot],
        gateDisplay: Double,
        softDisplay: Double,
        lastTotalDisplay: Double,
        exportedAtMs: Int64,
        schemaVersion: String = Self.currentSchemaVersion,
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
        self.coveragePercentage = coveragePercentage
        self.stateMachineState = stateMachineState
        self.pizRegionCount = pizRegionCount
    }

    enum CodingKeys: String, CodingKey {
        case patches
        case gateDisplay
        case softDisplay
        case lastTotalDisplay
        case schemaVersion
        case exportedAtMs
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
        try container.encodeIfPresent(coveragePercentage, forKey: .coveragePercentage)
        try container.encodeIfPresent(stateMachineState, forKey: .stateMachineState)
        try container.encodeIfPresent(pizRegionCount, forKey: .pizRegionCount)
    }

    public static func isCompatible(version: String) -> Bool {
        let current = currentSchemaVersion.split(separator: ".").compactMap { Int($0) }
        let check = version.split(separator: ".").compactMap { Int($0) }

        guard current.count >= 2, check.count >= 2 else { return false }
        return check[0] == current[0]
    }
}
