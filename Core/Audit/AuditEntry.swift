// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

// AuditEntry.swift
// PR#8.5 / v0.0.1
//  PR#8.5 / v0.0.1

import Foundation

/// 审计日志条目
///
/// Contains 4 legacy fields (back-compat only, not validated by PR#8.5 validator)
/// and 14 PR#8.5 contract fields (validated by TraceValidator).
///
/// - Note: PR#8.5 API must not read legacy fields: eventType, detailsJson, detailsSchemaVersion.
///   Use pr85EventType, paramsSummary, and entryType instead.
public struct AuditEntry: Codable, Sendable, Equatable {
    
    // === PR#8 EXISTING fields (backward compatibility, not validated by PR#8.5) ===
    
    /// Entry timestamp (wall clock at emit time).
    public let timestamp: Date
    
    /// Legacy event type string (backward compatibility only).
    /// PR#8.5 code must use pr85EventType instead.
    public let eventType: String
    
    /// Legacy details JSON (backward compatibility only).
    /// PR#8.5 code must use paramsSummary instead.
    public let detailsJson: String?
    
    /// Legacy details schema version (backward compatibility only).
    public let detailsSchemaVersion: String
    
    // === PR#8.5 NEW contract fields (validated by TraceValidator) ===
    
    /// Schema version. MUST be 1 for v0.0.1.
    public let schemaVersion: Int
    
    /// Event type enum (PR#8.5 contract field).
    /// Encodes to JSON key "eventType".
    public let pr85EventType: AuditEventType
    
    /// Entry type string. MUST equal pr85EventType.rawValue.
    public let entryType: String
    
    /// Action type (only for action_step events).
    public let actionType: AuditActionType?
    
    /// Trace ID (64 lowercase hex chars).
    public let traceId: String
    
    /// Scene ID (64 lowercase hex chars).
    public let sceneId: String
    
    /// Event ID ("{traceId}:{eventIndex}").
    public let eventId: String
    
    /// Policy hash (64 lowercase hex chars).
    public let policyHash: String
    
    /// Pipeline version string (non-empty, no |, no control chars).
    public let pipelineVersion: String
    
    /// Input descriptors for this event (non-optional array).
    public let inputs: [InputDescriptor]
    
    /// Debug parameters summary (only start may be non-empty).
    public let paramsSummary: [String: String]
    
    /// Completion metrics (only for trace_end/trace_fail).
    public let metrics: TraceMetrics?
    
    /// Artifact reference (only for trace_end with artifact).
    public let artifactRef: String?
    
    /// Build metadata (required, non-optional).
    public let buildMeta: BuildMeta
    
    // MARK: - CodingKeys
    
    private enum CodingKeys: String, CodingKey {
        case timestamp
        case legacyEventType = "legacyEventType"  // legacy eventType maps to "legacyEventType" in JSON
        case detailsJson
        case detailsSchemaVersion
        case schemaVersion
        case eventType  // pr85EventType maps to "eventType" in JSON
        case entryType
        case actionType
        case traceId
        case sceneId
        case eventId
        case policyHash
        case pipelineVersion
        case inputs
        case paramsSummary
        case metrics
        case artifactRef
        case buildMeta
    }
    
    // MARK: - Initializers
    
    /// Backward compatibility initializer with defaults.
    ///
    /// WARNING: Entries constructed via defaults are expected to fail validator.
    /// This exists ONLY for PR#8 callsite compatibility.
    /// New code using PR#8.5 fields MUST provide all required values.
    public init(
        timestamp: Date,
        eventType: String,
        detailsJson: String? = nil,
        detailsSchemaVersion: String = "1.0",
        schemaVersion: Int = 1,
        pr85EventType: AuditEventType = .traceStart,
        entryType: String = "",
        actionType: AuditActionType? = nil,
        traceId: String = "",
        sceneId: String = "",
        eventId: String = "",
        policyHash: String = "",
        pipelineVersion: String = "",
        inputs: [InputDescriptor] = [],
        paramsSummary: [String: String] = [:],
        metrics: TraceMetrics? = nil,
        artifactRef: String? = nil,
        buildMeta: BuildMeta = BuildMeta.unknown
    ) {
        self.timestamp = timestamp
        self.eventType = eventType
        self.detailsJson = detailsJson
        self.detailsSchemaVersion = detailsSchemaVersion
        self.schemaVersion = schemaVersion
        self.pr85EventType = pr85EventType
        self.entryType = entryType
        self.actionType = actionType
        self.traceId = traceId
        self.sceneId = sceneId
        self.eventId = eventId
        self.policyHash = policyHash
        self.pipelineVersion = pipelineVersion
        self.inputs = inputs
        self.paramsSummary = paramsSummary
        self.metrics = metrics
        self.artifactRef = artifactRef
        self.buildMeta = buildMeta
    }
    
    // MARK: - Codable Implementation
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(eventType, forKey: .legacyEventType)
        try container.encodeIfPresent(detailsJson, forKey: .detailsJson)
        try container.encode(detailsSchemaVersion, forKey: .detailsSchemaVersion)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(pr85EventType, forKey: .eventType)
        try container.encode(entryType, forKey: .entryType)
        try container.encodeIfPresent(actionType, forKey: .actionType)
        try container.encode(traceId, forKey: .traceId)
        try container.encode(sceneId, forKey: .sceneId)
        try container.encode(eventId, forKey: .eventId)
        try container.encode(policyHash, forKey: .policyHash)
        try container.encode(pipelineVersion, forKey: .pipelineVersion)
        try container.encode(inputs, forKey: .inputs)
        try container.encode(paramsSummary, forKey: .paramsSummary)
        try container.encodeIfPresent(metrics, forKey: .metrics)
        try container.encodeIfPresent(artifactRef, forKey: .artifactRef)
        try container.encode(buildMeta, forKey: .buildMeta)
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        eventType = try container.decode(String.self, forKey: .legacyEventType)
        detailsJson = try container.decodeIfPresent(String.self, forKey: .detailsJson)
        detailsSchemaVersion = try container.decode(String.self, forKey: .detailsSchemaVersion)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        pr85EventType = try container.decode(AuditEventType.self, forKey: .eventType)
        entryType = try container.decode(String.self, forKey: .entryType)
        actionType = try container.decodeIfPresent(AuditActionType.self, forKey: .actionType)
        traceId = try container.decode(String.self, forKey: .traceId)
        sceneId = try container.decode(String.self, forKey: .sceneId)
        eventId = try container.decode(String.self, forKey: .eventId)
        policyHash = try container.decode(String.self, forKey: .policyHash)
        pipelineVersion = try container.decode(String.self, forKey: .pipelineVersion)
        inputs = try container.decode([InputDescriptor].self, forKey: .inputs)
        paramsSummary = try container.decode([String: String].self, forKey: .paramsSummary)
        metrics = try container.decodeIfPresent(TraceMetrics.self, forKey: .metrics)
        artifactRef = try container.decodeIfPresent(String.self, forKey: .artifactRef)
        buildMeta = try container.decode(BuildMeta.self, forKey: .buildMeta)
    }
}

