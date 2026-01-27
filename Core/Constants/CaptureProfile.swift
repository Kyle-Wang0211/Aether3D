//
// CaptureProfile.swift
// Aether3D
//
// PR#1 Ultra-Granular Capture - Capture Profile (Closed Set)
//
// P2: CaptureProfile as closed, append-only enum with stable integer IDs
//

import Foundation

// MARK: - Capture Profile

/// Capture profile (closed set, append-only)
/// Each profile defines capture quality and resolution policies
public enum CaptureProfile: UInt8, Codable, CaseIterable {
    case standard = 1
    case smallObjectMacro = 2
    case largeScene = 3
    // Future: proMacro = 4 (reserved, only enable if achievable by consumer workflows)
    
    /// Stable integer ID (for hashing/digest)
    public var profileId: UInt8 {
        return rawValue
    }
    
    /// Human-readable name
    public var name: String {
        switch self {
        case .standard:
            return "standard"
        case .smallObjectMacro:
            return "smallObjectMacro"
        case .largeScene:
            return "largeScene"
        }
    }
    
    /// Documentation
    public var documentation: String {
        switch self {
        case .standard:
            return "Standard capture profile for typical objects and scenes"
        case .smallObjectMacro:
            return "Small object macro profile supporting sub-millimeter detail capture"
        case .largeScene:
            return "Large scene profile for room-scale or outdoor environments"
        }
    }
    
    // MARK: - Frozen Case Order Hash
    
    /// Frozen case order hash for CI verification
    /// Computed from: case names, sorted alphabetically, joined by \n, SHA-256
    /// **DO NOT MODIFY** - any change requires governance (RFC)
    /// Hash of: "largeScene\nsmallObjectMacro\nstandard" (sorted alphabetically)
    public static let FROZEN_PROFILE_CASE_ORDER_HASH = "d8c137a1360a781cbc7b7f65f7a82766b6384cec892680800d6de19e98b3c78b"
    
    // MARK: - Digest Input
    
    /// Digest input structure (for canonical digest)
    public struct DigestInput: Codable {
        public let profileId: UInt8
        public let name: String
        public let schemaVersionId: UInt16
        
        public init(profileId: UInt8, name: String, schemaVersionId: UInt16) {
            self.profileId = profileId
            self.name = name
            self.schemaVersionId = schemaVersionId
        }
    }
    
    /// Get digest input (for canonical digest computation)
    public func digestInput(schemaVersionId: UInt16) -> DigestInput {
        return DigestInput(profileId: profileId, name: name, schemaVersionId: schemaVersionId)
    }
}
