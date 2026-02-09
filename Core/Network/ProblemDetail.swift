// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// ProblemDetail.swift
// Aether3D
//
// RFC 9457 Problem Details for HTTP APIs
// 符合 PR3-02: RFC 9457 Problem Details
//

import Foundation

/// Problem Detail (RFC 9457)
///
/// Structured error response per RFC 9457.
/// 符合 PR3-02: RFC 9457 Problem Details
public struct ProblemDetail: Codable, Sendable, Equatable {
    /// Problem type URI (e.g., "https://api.aether3d.com/problems/invalid-request")
    public let type: String
    
    /// Short, human-readable summary
    public let title: String
    
    /// HTTP status code
    public let status: Int
    
    /// Human-readable explanation
    public let detail: String?
    
    /// Instance URI (specific occurrence)
    public let instance: String?
    
    /// Additional problem-specific properties
    public let extensions: [String: String]?
    
    public init(
        type: String,
        title: String,
        status: Int,
        detail: String? = nil,
        instance: String? = nil,
        extensions: [String: String]? = nil
    ) {
        self.type = type
        self.title = title
        self.status = status
        self.detail = detail
        self.instance = instance
        self.extensions = extensions
    }
    
    /// Create problem detail from API error
    /// 
    /// - Parameters:
    ///   - error: API error
    ///   - statusCode: HTTP status code
    ///   - instance: Instance URI
    /// - Returns: Problem detail
    public static func fromAPIError(_ error: APIError, statusCode: Int, instance: String? = nil) -> ProblemDetail {
        let type = "https://api.aether3d.com/problems/\(error.code.rawValue.lowercased())"
        let title = error.message
        
        var extensions: [String: String]? = nil
        if let details = error.details {
            extensions = [:]
            for (key, value) in details {
                extensions?[key] = String(describing: value)
            }
        }
        
        return ProblemDetail(
            type: type,
            title: title,
            status: statusCode,
            detail: error.message,
            instance: instance,
            extensions: extensions
        )
    }
}

/// Problem Type Constants
public enum ProblemType: String {
    case invalidRequest = "https://api.aether3d.com/problems/invalid-request"
    case authFailed = "https://api.aether3d.com/problems/auth-failed"
    case resourceNotFound = "https://api.aether3d.com/problems/resource-not-found"
    case stateConflict = "https://api.aether3d.com/problems/state-conflict"
    case payloadTooLarge = "https://api.aether3d.com/problems/payload-too-large"
    case rateLimited = "https://api.aether3d.com/problems/rate-limited"
    case internalError = "https://api.aether3d.com/problems/internal-error"
}
