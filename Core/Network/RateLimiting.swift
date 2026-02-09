// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// RateLimiting.swift
// Aether3D
//
// Rate Limiting Headers - IETF draft standard headers
// 符合 PR3-04: Rate Limiting Headers
//

import Foundation

/// Rate Limit Headers
///
/// Standard rate limit headers per IETF draft.
/// 符合 PR3-04: Rate Limiting Headers
public struct RateLimitHeaders: Sendable, Equatable {
    /// Rate limit window (seconds)
    public let limit: Int
    
    /// Remaining requests in current window
    public let remaining: Int
    
    /// Reset time (Unix timestamp)
    public let reset: Int
    
    /// Retry-After header (seconds to wait before retry)
    public let retryAfter: Int?
    
    public init(limit: Int, remaining: Int, reset: Int, retryAfter: Int? = nil) {
        self.limit = limit
        self.remaining = remaining
        self.reset = reset
        self.retryAfter = retryAfter
    }
    
    /// Convert to HTTP headers dictionary
    /// 
    /// - Returns: Dictionary of HTTP headers
    public func toHeaders() -> [String: String] {
        var headers: [String: String] = [:]
        headers["X-RateLimit-Limit"] = String(limit)
        headers["X-RateLimit-Remaining"] = String(remaining)
        headers["X-RateLimit-Reset"] = String(reset)
        
        if let retryAfter = retryAfter {
            headers["Retry-After"] = String(retryAfter)
        }
        
        return headers
    }
    
    /// Parse from HTTP response headers
    /// 
    /// - Parameter headers: HTTP response headers
    /// - Returns: Rate limit headers if present
    public static func fromHeaders(_ headers: [String: String]) -> RateLimitHeaders? {
        guard let limitStr = headers["X-RateLimit-Limit"],
              let limit = Int(limitStr),
              let remainingStr = headers["X-RateLimit-Remaining"],
              let remaining = Int(remainingStr),
              let resetStr = headers["X-RateLimit-Reset"],
              let reset = Int(resetStr) else {
            return nil
        }
        
        let retryAfter = headers["Retry-After"].flatMap { Int($0) }
        
        return RateLimitHeaders(limit: limit, remaining: remaining, reset: reset, retryAfter: retryAfter)
    }
}

/// Rate Limit Manager
///
/// Manages rate limiting for API requests.
public actor RateLimitManager {
    
    // MARK: - State
    
    /// Rate limit windows by endpoint
    private var windows: [String: RateLimitWindow] = [:]
    
    // MARK: - Configuration
    
    /// Default rate limits
    public struct DefaultLimits {
        public static let uploadsPerMinute = 10
        public static let jobsPerMinute = 30
        public static let artifactsPerMinute = 60
    }
    
    // MARK: - Rate Limit Checking
    
    /// Check if request is allowed
    /// 
    /// - Parameters:
    ///   - endpoint: API endpoint
    ///   - limit: Rate limit (requests per window)
    ///   - windowSeconds: Window size in seconds
    /// - Returns: Rate limit headers and whether request is allowed
    public func checkRateLimit(endpoint: String, limit: Int, windowSeconds: Int = 60) -> (allowed: Bool, headers: RateLimitHeaders) {
        let now = Int(Date().timeIntervalSince1970)
        let windowKey = "\(endpoint):\(windowSeconds)"
        
        // Get or create window
        var window = windows[windowKey] ?? RateLimitWindow(limit: limit, windowSeconds: windowSeconds)
        
        // Check if window expired
        if now >= window.resetTime {
            window = RateLimitWindow(limit: limit, windowSeconds: windowSeconds)
        }
        
        // Check if limit exceeded
        let allowed = window.count < limit
        
        // Increment count if allowed
        if allowed {
            window.count += 1
        }
        
        windows[windowKey] = window
        
        // Create headers
        let headers = RateLimitHeaders(
            limit: limit,
            remaining: max(0, limit - window.count),
            reset: window.resetTime,
            retryAfter: allowed ? nil : (window.resetTime - now)
        )
        
        return (allowed: allowed, headers: headers)
    }
}

/// Rate Limit Window
private struct RateLimitWindow {
    var count: Int
    let limit: Int
    let windowSeconds: Int
    let resetTime: Int
    
    init(limit: Int, windowSeconds: Int) {
        self.count = 0
        self.limit = limit
        self.windowSeconds = windowSeconds
        let now = Int(Date().timeIntervalSince1970)
        self.resetTime = now + windowSeconds
    }
}
