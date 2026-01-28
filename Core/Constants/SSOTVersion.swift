//
// SSOTVersion.swift
// Aether3D
//
// PR#1 Ultra-Granular Capture - Schema Versioning (Integer Domain)
//
// P4: Schema versioning must be integer-domain and single-sourced
//

import Foundation

/// Current SSOT implementation version.
/// Increment on breaking changes to SSOT structure or semantics.
public enum SSOTVersion {
    /// Current SSOT version: 1.0.0
    public static let current = "1.0.0"
    
    /// Schema version ID (UInt16) - single source of truth
    /// Increment when JSON/encoding structures change.
    /// **Rule:** All policy tables must reference this value
    public static let schemaVersionId: UInt16 = 1
    
    /// Legacy schema version string (for backward compatibility)
    /// **Deprecated:** Use schemaVersionId instead
    @available(*, deprecated, message: "Use schemaVersionId instead")
    public static let schemaVersion = "1.0.0"
    
    /// Whitebox freeze threshold: SSOT must be frozen before external release.
    /// Format: "YYYY-MM-DD"
    public static let whiteboxFreezeThreshold = "2025-01-01"
    
    // MARK: - Frozen Hashes (for CI verification)
    
    /// Frozen profile case order hash
    /// **DO NOT MODIFY** - any change requires governance (RFC)
    public static let FROZEN_PROFILE_CASE_ORDER_HASH = CaptureProfile.FROZEN_PROFILE_CASE_ORDER_HASH
    
    // MARK: - Golden Policy Digests
    
    /// Load golden policy digests from file
    /// **H3:** Uses filesystem path, not Bundle.module
    public static func loadGoldenPolicyDigests(repoRoot: String) throws -> [String: String] {
        let goldenPath = "\(repoRoot)/Tests/Golden/policy_digests.json"
        let url = URL(fileURLWithPath: goldenPath)
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let digests = json?["policyDigests"] as? [String: String] else {
            throw SSOTVersionError.invalidGoldenFileFormat
        }
        return digests
    }
    
    /// Load field set hashes from golden file
    public static func loadFieldSetHashes(repoRoot: String) throws -> [String: String] {
        let goldenPath = "\(repoRoot)/Tests/Golden/policy_digests.json"
        let url = URL(fileURLWithPath: goldenPath)
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let hashes = json?["fieldSetHashes"] as? [String: String] else {
            throw SSOTVersionError.invalidGoldenFileFormat
        }
        return hashes
    }
    
    /// Load envelope digest from golden file
    public static func loadEnvelopeDigest(repoRoot: String) throws -> String {
        let goldenPath = "\(repoRoot)/Tests/Golden/policy_digests.json"
        let url = URL(fileURLWithPath: goldenPath)
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let digest = json?["envelopeDigest"] as? String else {
            throw SSOTVersionError.invalidGoldenFileFormat
        }
        return digest
    }
}

// MARK: - Errors

public enum SSOTVersionError: Error {
    case invalidGoldenFileFormat
    
    public var localizedDescription: String {
        switch self {
        case .invalidGoldenFileFormat:
            return "SSOTVersion: Invalid golden file format"
        }
    }
}
