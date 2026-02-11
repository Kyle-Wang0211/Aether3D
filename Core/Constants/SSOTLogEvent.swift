// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// SSOTLogEvent.swift
// Aether3D
//
// Structured log events for SSOT system.
//

import Foundation

/// Log event type
public enum SSOTLogEventType: String, Codable {
    case violation
    case clamp
    case warning
    case error
}

/// Structured log event for SSOT system
public struct SSOTLogEvent: Codable {
    /// Event type
    public let type: SSOTLogEventType
    
    /// Timestamp (ISO8601 string)
    public let timestamp: String
    
    /// SSOT ID (if applicable)
    public let ssotId: String?
    
    /// Event message
    public let message: String
    
    /// Additional context
    public let context: [String: String]
    
    public init(
        type: SSOTLogEventType,
        timestamp: Date? = nil,
        ssotId: String? = nil,
        message: String,
        context: [String: String] = [:]
    ) {
        self.type = type
        let ts = timestamp ?? currentTime()
        self.timestamp = ISO8601DateFormatter().string(from: ts)
        self.ssotId = ssotId
        self.message = message
        self.context = context
    }
}

