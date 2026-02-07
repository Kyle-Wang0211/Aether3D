//
// BlockchainAnchorError.swift
// Aether3D
//
// Phase 1: Time Anchoring - OpenTimestamps Error Types
//

import Foundation

/// Errors for OpenTimestamps blockchain anchoring
///
/// **Fail-closed:** All errors are explicit
public enum BlockchainAnchorError: Error, Sendable {
    /// Invalid hash length (must be 32 bytes)
    case invalidHashLength
    
    /// Submission failed
    case submissionFailed(reason: String)
    
    /// Upgrade timeout (receipt not yet confirmed in blockchain)
    case upgradeTimeout
    
    /// Invalid receipt format
    case invalidReceipt(reason: String)
    
    /// Network error
    case networkError(underlying: Error)
}
