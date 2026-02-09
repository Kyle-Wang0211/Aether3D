//
//  ACI.swift
//  Aether3D
//
//  PR#8: Immutable Bundle Format - Aether Content Identifier
//

import Foundation

/// Aether Content Identifier — self-describing, version-aware, algorithm-agile.
///
/// INV-B14: Self-describing content identifiers (V6)
///
/// Format: "aci:<version>:<algorithm>:<digest>"
/// Example: "aci:1:sha256:ba7816bf..."
///
/// Parse: split on ":", validate version=1, dispatch algorithm.
/// Future: version 2 may add additional fields without breaking v1 parsers.
public struct ACI: Codable, Sendable, Equatable, CustomStringConvertible {
    /// Version number (always 1 for now)
    public let version: UInt8
    
    /// Algorithm identifier ("sha256", "sha3-256", "dual")
    public let algorithm: String
    
    /// Digest string (hex for single, "sha256=...,sha3-256=..." for dual)
    public let digest: String
    
    /// String representation: "aci:<version>:<algorithm>:<digest>"
    public var description: String {
        return "aci:\(version):\(algorithm):\(digest)"
    }
    
    /// Parse ACI from string format.
    ///
    /// - Parameter s: ACI string ("aci:<version>:<algorithm>:<digest>")
    /// - Returns: Parsed ACI
    /// - Throws: BundleError.invalidDigestFormat if format is invalid
    public static func parse(_ s: String) throws -> ACI {
        let components = s.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
        guard components.count == 4,
              components[0] == "aci",
              let version = UInt8(components[1]),
              version == 1 else {
            throw BundleError.invalidDigestFormat("Invalid ACI format: \(s)")
        }
        
        let algorithm = String(components[2])
        guard ["sha256", "sha3-256", "dual"].contains(algorithm) else {
            throw BundleError.invalidDigestFormat("Unknown algorithm: \(algorithm)")
        }
        
        let digest = String(components[3])
        
        // Validate digest format based on algorithm
        if algorithm == "sha256" || algorithm == "sha3-256" {
            try _validateSHA256(digest)
        } else if algorithm == "dual" {
            // Dual format: "sha256=<hex>,sha3-256=<hex>"
            let parts = digest.split(separator: ",")
            guard parts.count == 2 else {
                throw BundleError.invalidDigestFormat("Dual digest must have two parts")
            }
            // Basic validation - could be more strict
        }
        
        return ACI(version: version, algorithm: algorithm, digest: digest)
    }
    
    /// Create ACI from SHA-256 hex string.
    ///
    /// - Parameter hex: 64 lowercase hex characters
    /// - Returns: ACI with version=1, algorithm="sha256"
    public static func fromSHA256Hex(_ hex: String) -> ACI {
        return ACI(version: 1, algorithm: "sha256", digest: hex)
    }
    
    /// Create ACI from DualDigest.
    ///
    /// - Parameter dual: DualDigest instance
    /// - Returns: ACI representation
    public static func fromDualDigest(_ dual: DualDigest) -> ACI {
        if BundleConstants.DUAL_ALGORITHM_ENABLED && dual.sha3_256 != DualDigest.SHA3_PENDING {
            return ACI(version: 1, algorithm: "dual",
                       digest: "sha256=\(dual.sha256),sha3-256=\(dual.sha3_256)")
        }
        return ACI(version: 1, algorithm: "sha256", digest: dual.sha256)
    }
}
