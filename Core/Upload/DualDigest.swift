//
//  DualDigest.swift
//  Aether3D
//
//  PR#8: Immutable Bundle Format - Dual-Algorithm Digest
//

import Foundation

#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif

/// Dual-algorithm integrity hash (SHA-256 + SHA-3-256).
///
/// INV-B13: Dual-algorithm diversity defense (V6)
///
/// **V7 STATUS**: SHA-3-256 is NOT available in swift-crypto 3.15.1.
/// The sha3_256 field stores "pending-sha3-migration" until swift-crypto
/// ships SHA-3 on main branch. Only sha256 is verified in v1.0.0.
///
/// When BundleConstants.DUAL_ALGORITHM_ENABLED is flipped to true,
/// both algorithms will be computed and verified.
public struct DualDigest: Codable, Sendable, Equatable {
    /// SHA-256 digest (64 hex chars, always computed)
    public let sha256: String
    
    /// SHA-3-256 digest (64 hex chars) OR "pending-sha3-migration"
    public let sha3_256: String
    
    /// Placeholder value for SHA-3-256 when not available
    public static let SHA3_PENDING = "pending-sha3-migration"
    
    /// Compute dual digest from data.
    ///
    /// **V7**: Only SHA-256 is computed. SHA-3-256 is set to placeholder.
    /// When BundleConstants.DUAL_ALGORITHM_ENABLED is true, both will be computed.
    ///
    /// - Parameter data: Data to hash
    /// - Returns: DualDigest with SHA-256 computed and SHA-3 placeholder
    public static func compute(data: Data) -> DualDigest {
        let sha256hex = _hexLowercase(Array(_SHA256.hash(data: data)))
        
        if BundleConstants.DUAL_ALGORITHM_ENABLED { fatalError("SHA-3-256 not yet available in swift-crypto") }
        
        return DualDigest(sha256: sha256hex, sha3_256: SHA3_PENDING)
    }
    
    /// Verify digest against data using timing-safe comparison.
    ///
    /// **V7**: Only verifies SHA-256 if SHA-3 is placeholder.
    /// When DUAL_ALGORITHM_ENABLED is true, verifies both.
    ///
    /// - Parameter data: Data to verify against
    /// - Returns: true if digest matches (SHA-256 always, SHA-3 if enabled)
    public func verify(against data: Data) -> Bool {
        let computed = DualDigest.compute(data: data)
        let sha256Match = HashCalculator.timingSafeEqualHex(sha256, computed.sha256)
        
        if BundleConstants.DUAL_ALGORITHM_ENABLED {
            let sha3Match = HashCalculator.timingSafeEqualHex(sha3_256, computed.sha3_256)
            return sha256Match && sha3Match
        }
        
        return sha256Match
    }
}
