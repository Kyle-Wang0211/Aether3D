//
// SSOTVersion.swift
// Aether3D
//
// Single Source of Truth versioning and schema management.
//

import Foundation

/// Current SSOT implementation version.
/// Increment on breaking changes to SSOT structure or semantics.
public enum SSOTVersion {
    /// Current SSOT version: 1.0.0
    public static let current = "1.0.0"
    
    /// Schema version for serialization formats.
    /// Increment when JSON/encoding structures change.
    public static let schemaVersion = "1.0.0"
    
    /// Whitebox freeze threshold: SSOT must be frozen before external release.
    /// Format: "YYYY-MM-DD"
    public static let whiteboxFreezeThreshold = "2025-01-01"
}

