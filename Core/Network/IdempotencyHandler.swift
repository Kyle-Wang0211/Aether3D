// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// IdempotencyHandler.swift
// Aether3D
//
// Idempotency Handler - Stripe-pattern idempotency for mutation operations
// 符合 PR3-03: Idempotency-Key Header
//

import Foundation
import SharedSecurity

/// Idempotency Handler
///
/// Manages idempotency keys for mutation operations.
/// 符合 PR3-03: Idempotency-Key Header
public actor IdempotencyHandler {
    
    // MARK: - State
    
    /// Cached responses by idempotency key
    private var cache: [String: IdempotencyCacheEntry] = [:]
    
    /// Cache TTL (24 hours)
    private let cacheTTL: TimeInterval = 86400 // LINT:ALLOW
    
    // MARK: - Idempotency Checking
    
    /// Check if idempotency key has been seen
    /// 
    /// - Parameter key: Idempotency key
    /// - Returns: Cached response if key exists, nil otherwise
    public func checkIdempotency(key: String) -> IdempotencyCacheEntry? {
        guard let entry = cache[key] else {
            return nil
        }
        
        // Check if entry expired
        let now = Date()
        if now.timeIntervalSince(entry.timestamp) > cacheTTL {
            cache.removeValue(forKey: key)
            return nil
        }
        
        return entry
    }
    
    /// Store idempotency key and response
    /// 
    /// - Parameters:
    ///   - key: Idempotency key
    ///   - response: Response data
    ///   - statusCode: HTTP status code
    public func storeIdempotency(key: String, response: Data, statusCode: Int) {
        let entry = IdempotencyCacheEntry(
            key: key,
            response: response,
            statusCode: statusCode,
            timestamp: Date()
        )
        cache[key] = entry
        
        // Clean up expired entries
        cleanupExpiredEntries()
    }
    
    /// Clean up expired entries
    private func cleanupExpiredEntries() {
        let now = Date()
        cache = cache.filter { (_, entry) in
            now.timeIntervalSince(entry.timestamp) <= cacheTTL
        }
    }
}

/// Idempotency Cache Entry
public struct IdempotencyCacheEntry: Sendable {
    public let key: String
    public let response: Data
    public let statusCode: Int
    public let timestamp: Date
    
    public init(key: String, response: Data, statusCode: Int, timestamp: Date) {
        self.key = key
        self.response = response
        self.statusCode = statusCode
        self.timestamp = timestamp
    }
}

/// Idempotency Key Generator
public enum IdempotencyKeyGenerator {
    /// Generate idempotency key from request
    /// 
    /// - Parameters:
    ///   - method: HTTP method
    ///   - path: Request path
    ///   - body: Request body
    ///   - timestamp: Request timestamp (truncated to minute)
    /// - Returns: Idempotency key
    public static func generate(method: String, path: String, body: Data?, timestamp: Date) -> String {
        let timestampMinute = Int(timestamp.timeIntervalSince1970 / 60) * 60
        var input = "\(method)\(path)\(timestampMinute)"
        
        if let body = body {
            input += CryptoHasher.sha256(body)
        }
        
        return CryptoHasher.sha256(input.data(using: .utf8) ?? Data())
    }
}
