//
// TSAError.swift
// Aether3D
//
// Phase 1: Time Anchoring - RFC 3161 TSA Error Types
//

import Foundation

/// Errors for RFC 3161 Time-Stamp Protocol operations
///
/// **Fail-closed:** All errors are explicit, no generic catch-all
public enum TSAError: Error, Sendable {
    /// Invalid hash length (must be 32 bytes for SHA-256)
    case invalidHashLength(expected: Int, actual: Int)
    
    /// HTTP error from TSA server
    case httpError(statusCode: Int, responseBody: Data?)
    
    /// TSA rejected the request (status field in response)
    case tsaRejected(status: Int, statusString: String?)
    
    /// Invalid response format (malformed ASN.1 DER)
    case invalidResponse(reason: String)
    
    /// Signature verification failed
    case verificationFailed(reason: String)
    
    /// Network timeout
    case timeout
    
    /// ASN.1 encoding/decoding error
    case asn1Error(reason: String)
}
