// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// AuditProtocols.swift
// Aether3D
//
// PR#1 SSOT Foundation v1.1 - Audit Protocols
//
// This file defines protocols for audit immutability.
//

import Foundation

/// Protocol for invalidatable records.
///
/// **Rule ID:** AUDIT_IMMUTABLE_001
/// **Status:** IMMUTABLE
public protocol Invalidatable {
    var invalidated: Bool { get }
    var invalidationRecord: InvalidationRecord? { get }
}

/// Invalidation record structure.
///
/// **Rule ID:** AUDIT_INVALIDATION_001, AUDIT_INVALIDATION_001A
/// **Status:** IMMUTABLE
public struct InvalidationRecord: Codable {
    public let invalidatedAt: String // ISO8601Timestamp
    public let source: InvalidationSource
    public let reason: String
    public let operatorId: String?
    public let reversible: Bool
    public let effect: InvalidationEffect
    public let reinstatedAt: String? // ISO8601Timestamp (v1.1.1)
    public let reinstatedBy: String? // v1.1.1
    public let reinstatementReason: String? // v1.1.1
}

/// Protocol for auditable records.
///
/// **Rule ID:** AUDIT_IMMUTABLE_001A
/// **Status:** IMMUTABLE
public protocol AuditableRecord {
    var createdAt: String { get } // ISO8601Timestamp
    var recordId: String { get }
    var schemaVersion: Int { get }
    var foundationVersion: String { get }
    var contractVersion: Int { get }
}

/// Protocol for immutable core fields.
///
/// **Rule ID:** AUDIT_IMMUTABLE_001A
/// **Status:** IMMUTABLE
///
/// ImmutableCore fields never change after creation:
/// - recordId, createdAt, schemaVersion
/// - hash inputs digests / provenance anchors
/// - original raw observation pointers/digests
public protocol ImmutableCore {
    var recordId: String { get }
    var createdAt: String { get } // ISO8601Timestamp
    var schemaVersion: Int { get }
}

/// Protocol for append-only extensions.
///
/// **Rule ID:** AUDIT_IMMUTABLE_001A
/// **Status:** IMMUTABLE
///
/// AppendOnlyExtensions fields only append; never overwrite:
/// - warnings[] (only append)
/// - derivedMetrics[] (only append entries, keyed by (metricName, metricVersion))
/// - signatures[] (only append)
public protocol AppendOnlyExtensions {
    // Implementation defines append-only arrays
    // Never overwrite entries with same (name, version) key
}
