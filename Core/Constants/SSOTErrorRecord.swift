//
// SSOTErrorRecord.swift
// Aether3D
//
// Serializable error record (without Date for determinism).
//

import Foundation

/// Serializable error record (deterministic, no Date).
public struct SSOTErrorRecord: Codable, Equatable {
    /// Error code domain ID
    public let domainId: String
    
    /// Error code
    public let code: Int
    
    /// Stable name
    public let stableName: String
    
    /// ISO8601 timestamp string
    public let timestamp: String
    
    /// Filtered context
    public let context: [String: String]
    
    public init(from error: SSOTError) {
        self.domainId = error.code.domain.id
        self.code = error.code.code
        self.stableName = error.code.stableName
        self.timestamp = ISO8601DateFormatter().string(from: error.timestamp)
        self.context = error.context
    }
    
    public init(
        domainId: String,
        code: Int,
        stableName: String,
        timestamp: String,
        context: [String: String]
    ) {
        self.domainId = domainId
        self.code = code
        self.stableName = stableName
        self.timestamp = timestamp
        self.context = context
    }
}

