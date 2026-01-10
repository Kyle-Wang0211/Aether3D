// AuditActionType.swift
// PR#8.5 / v0.0.1

import Foundation

/// Action types for audit trace.
///
/// v0.0.1 defines exactly ONE action type.
/// Adding types requires schemaVersion bump.
///
/// - Note: NO @unknown default. Exhaustive switching required.
public enum AuditActionType: String, Codable, Sendable, Equatable {
    case generateArtifact = "generate_artifact"
}

