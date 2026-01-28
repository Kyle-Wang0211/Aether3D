//
// AuditEventType.swift
// Aether3D
//
// PR#1 SSOT Foundation v1.1.1 - Audit Event Type Enumeration (E1)
//
// This enum defines all audit event types for record lifecycle tracking.
// APPEND_ONLY_CLOSED_SET: may only append cases at the end, never delete/rename/reorder.
//

import Foundation

/// Record lifecycle event type enumeration (APPEND_ONLY_CLOSED_SET).
///
/// **Rule ID:** E1, B3
/// **Status:** IMMUTABLE
///
/// **Note:** This is distinct from Core/Audit/AuditEventType (PR#8.5) which handles audit trace events.
/// This enum handles record lifecycle events (created, invalidated, superseded, etc.).
///
/// **Governance:**
/// - Only legal change: append new cases to the end
/// - Any reorder/rename/delete must fail CI
/// - Each case must record firstIntroducedInFoundationVersion
public enum RecordLifecycleEventType: String, Codable, CaseIterable {
    /// Record created
    /// firstIntroducedInFoundationVersion: "1.1.1"
    case CREATED = "CREATED"
    
    /// Record invalidated
    /// firstIntroducedInFoundationVersion: "1.1.1"
    case INVALIDATED = "INVALIDATED"
    
    /// Record superseded by newer version
    /// firstIntroducedInFoundationVersion: "1.1.1"
    case SUPERSEDED = "SUPERSEDED"
    
    /// Record recomputed
    /// firstIntroducedInFoundationVersion: "1.1.1"
    case RECOMPUTED = "RECOMPUTED"
    
    /// Record migrated across epochs
    /// firstIntroducedInFoundationVersion: "1.1.1"
    case MIGRATED = "MIGRATED"
    
    /// Record redacted (privacy/legal)
    /// firstIntroducedInFoundationVersion: "1.1.1"
    case REDACTED = "REDACTED"
    
    // MARK: - Schema Metadata
    
    /// Schema identifier for logging/audit
    /// **Rule ID:** B3
    public static let schemaId = "RecordLifecycleEventType_v1.1.1"
    
    /// Frozen case order hash (B3)
    /// **Rule ID:** B3
    /// **Status:** IMMUTABLE
    ///
    /// Computed from: case names (in declared order) joined with \n, SHA-256 hashed.
    /// Format: "caseName=rawValue\ncaseName=rawValue\n..."
    ///
    /// **WARNING:** Any change to this hash will fail CI.
    /// Only legal change: append new cases to the end and update this hash.
    public static let frozenCaseOrderHash = "4c52b6e638ae72736db203d53b1ca97f9146fd59c306bb9f3d72fb0d741757fe"
}
