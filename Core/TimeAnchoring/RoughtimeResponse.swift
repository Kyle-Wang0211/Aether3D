//
// RoughtimeResponse.swift
// Aether3D
//
// Phase 1: Time Anchoring - Roughtime Protocol Response
//
// **Standard:** IETF Roughtime (draft-ietf-ntp-roughtime-10)
//

import Foundation

/// Roughtime protocol response
///
/// **Standard:** IETF Roughtime
/// **Transport:** UDP
///
/// **Invariants:**
/// - INV-C4: Ed25519 signature verification
/// - INV-C2: All numeric encoding is Big-Endian
public struct RoughtimeResponse: Codable, Sendable {
    /// Midpoint time (nanoseconds since Unix epoch)
    public let midpointTimeNs: UInt64
    
    /// Radius (uncertainty bound in nanoseconds)
    public let radiusNs: UInt32
    
    /// Nonce used in request (must match)
    public let nonce: Data
    
    /// Ed25519 signature over response
    public let signature: Data
    
    /// Server public key (for verification)
    public let serverPublicKey: Data
    
    /// Time interval: [midpointTimeNs - radiusNs, midpointTimeNs + radiusNs]
    public var timeInterval: (lower: UInt64, upper: UInt64) {
        let lower = midpointTimeNs >= radiusNs ? midpointTimeNs - UInt64(radiusNs) : 0
        let upper = midpointTimeNs + UInt64(radiusNs)
        return (lower: lower, upper: upper)
    }
}
