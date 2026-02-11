// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  AuditRecord.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Milestone 1
//  AuditRecord - audit record structure for white commit
//

import Foundation

/// AuditRecord - audit record for white commit
/// Contains: ruleIds, metricSnapshot, decisionPathDigest, thresholdVersion, buildGitSha
public struct AuditRecord: Codable {
    public let ruleIds: [RuleId]
    public let metricSnapshot: MetricSnapshotMinimal
    public let decisionPathDigest: String
    public let thresholdVersion: String
    public let buildGitSha: String
    
    public init(
        ruleIds: [RuleId],
        metricSnapshot: MetricSnapshotMinimal,
        decisionPathDigest: String,
        thresholdVersion: String,
        buildGitSha: String
    ) {
        self.ruleIds = ruleIds
        self.metricSnapshot = metricSnapshot
        self.decisionPathDigest = decisionPathDigest
        self.thresholdVersion = thresholdVersion
        self.buildGitSha = buildGitSha
    }
    
    /// Serialize to canonical JSON bytes
    /// Uses CanonicalJSON encoder (SSOT)
    public func toCanonicalJSONBytes() throws -> Data {
        let jsonString = try CanonicalJSON.encode(self)
        guard let data = jsonString.data(using: .utf8) else {
            throw EncodingError.invalidValue(jsonString, EncodingError.Context(codingPath: [], debugDescription: "Failed to convert JSON string to UTF-8"))
        }
        return data
    }
    
    /// Compute audit SHA256 hash
    public func computeSHA256() throws -> String {
        let bytes = try toCanonicalJSONBytes()
        return SHA256Utility.sha256(bytes)
    }
}

