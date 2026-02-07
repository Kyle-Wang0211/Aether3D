//
// RoughtimeError.swift
// Aether3D
//
// Phase 1: Time Anchoring - Roughtime Protocol Error Types
//

import Foundation

/// Errors for IETF Roughtime protocol operations
///
/// **Fail-closed:** All errors are explicit
public enum RoughtimeError: Error, Sendable {
    /// Invalid server public key format
    case invalidPublicKey
    
    /// Signature verification failed
    case signatureVerificationFailed
    
    /// Invalid response format
    case invalidResponse(reason: String)
    
    /// Network error (UDP)
    case networkError(underlying: Error)
    
    /// Timeout waiting for response
    case timeout
    
    /// Response radius too large (uncertainty too high)
    case radiusTooLarge(radius: UInt32)
}
