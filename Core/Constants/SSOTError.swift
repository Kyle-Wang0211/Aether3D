// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// SSOTError.swift
// Aether3D
//
// Primary error type for SSOT system.
//

import Foundation

/// Whitelist of allowed context keys for SSOTError.
private let allowedContextKeys: Set<String> = [
    "ssotId",
    "value",
    "min",
    "max",
    "threshold",
    "spec",
    "file",
    "line",
    "function"
]

/// SSOT error with structured context.
public struct SSOTError: Error {
    /// The error code
    public let code: SSOTErrorCode
    
    /// Timestamp (uses TimeProvider)
    public let timestamp: Date
    
    /// Filtered context (only whitelisted keys)
    public let context: [String: String]
    
    public init(
        code: SSOTErrorCode,
        timestamp: Date? = nil,
        context: [String: String] = [:]
    ) {
        self.code = code
        self.timestamp = timestamp ?? currentTime()
        
        // Filter context to whitelist
        var filtered: [String: String] = [:]
        for (key, value) in context {
            if allowedContextKeys.contains(key) {
                filtered[key] = value
            }
        }
        self.context = filtered
    }
    
    /// User-facing error message
    public var userMessage: String {
        return code.defaultUserMessage
    }
    
    /// Developer-facing error message
    public var developerMessage: String {
        var msg = "\(code.stableName) (\(code.domain.id):\(code.code)): \(code.developerHint)"
        if !context.isEmpty {
            msg += "\nContext: \(context)"
        }
        return msg
    }
}

extension SSOTError: CustomStringConvertible {
    public var description: String {
        return developerMessage
    }
}

