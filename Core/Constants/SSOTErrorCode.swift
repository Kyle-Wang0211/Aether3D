// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// SSOTErrorCode.swift
// Aether3D
//
// Structured error code definition.
//

import Foundation

/// Error severity level.
public enum ErrorSeverity: String, Codable, CaseIterable {
    case low
    case medium
    case high
    case critical
}

/// Retry policy for errors.
public enum RetryPolicy: String, Codable, CaseIterable {
    case none
    case immediate
    case exponentialBackoff
    case manual
}

/// Structured error code with metadata.
public struct SSOTErrorCode: Codable, Equatable, Hashable {
    /// Error domain
    public let domain: ErrorDomain
    
    /// Numeric error code
    public let code: Int
    
    /// Stable name (e.g., "SSOT_INVALID_SPEC")
    public let stableName: String
    
    /// Severity level
    public let severity: ErrorSeverity
    
    /// Retry policy
    public let retry: RetryPolicy
    
    /// Default user-facing message
    public let defaultUserMessage: String
    
    /// Developer hint for debugging
    public let developerHint: String
    
    public init(
        domain: ErrorDomain,
        code: Int,
        stableName: String,
        severity: ErrorSeverity,
        retry: RetryPolicy,
        defaultUserMessage: String,
        developerHint: String
    ) {
        self.domain = domain
        self.code = code
        self.stableName = stableName
        self.severity = severity
        self.retry = retry
        self.defaultUserMessage = defaultUserMessage
        self.developerHint = developerHint
    }
    
    /// Validate internal consistency.
    public func validate() -> [String] {
        var errors: [String] = []
        
        // Format checks
        if stableName.isEmpty {
            errors.append("stableName is empty")
        }
        
        if stableName.count > 64 {
            errors.append("stableName exceeds 64 characters: \(stableName)")
        }
        
        if !stableName.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
            errors.append("stableName contains invalid characters: \(stableName)")
        }
        
        // Prefix check
        if !stableName.hasPrefix(domain.stableNamePrefix) {
            errors.append("stableName '\(stableName)' does not start with domain prefix '\(domain.stableNamePrefix)'")
        }
        
        // Range check
        if !domain.codeRange.contains(code) {
            errors.append("code \(code) not in domain range \(domain.codeRange)")
        }
        
        // Message checks
        if defaultUserMessage.isEmpty {
            errors.append("defaultUserMessage is empty")
        }
        
        return errors
    }
}

