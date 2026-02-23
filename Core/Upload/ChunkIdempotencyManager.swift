// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR9-IDEMPOTENCY-1.0
// Module: Upload Infrastructure - Chunk Idempotency Manager
// Cross-Platform: macOS + Linux (pure Foundation)

import Foundation

// _SHA256 typealias defined in CryptoHelpers.swift

/// Chunk-level idempotency extending existing IdempotencyHandler.
///
/// **Purpose**: Chunk-level idempotency extending existing IdempotencyHandler.
/// Per-chunk keys, persistent cache, replay protection.
///
/// **Key Features**:
/// - Per-chunk idempotency keys (SHA-256 of chunk data + session ID + chunk index)
/// - Persistent cache (survives app restarts)
/// - Replay protection (24h TTL)
public actor ChunkIdempotencyManager {
    
    // MARK: - State
    
    private var cache: [String: IdempotencyCacheEntry] = [:]
    private let cacheTTL = UploadConstants.IDEMPOTENCY_KEY_MAX_AGE
    private let baseIdempotencyHandler: IdempotencyHandler
    
    // MARK: - Initialization
    
    /// Initialize chunk idempotency manager.
    ///
    /// - Parameter baseHandler: Base idempotency handler
    public init(baseHandler: IdempotencyHandler) {
        self.baseIdempotencyHandler = baseHandler
    }
    
    // MARK: - Chunk Idempotency
    
    /// Generate idempotency key for chunk.
    ///
    /// - Parameters:
    ///   - sessionId: Upload session ID
    ///   - chunkIndex: Chunk index
    ///   - chunkHash: SHA-256 hash of chunk data
    /// - Returns: Idempotency key
    public func generateChunkKey(
        sessionId: String,
        chunkIndex: Int,
        chunkHash: String
    ) -> String {
        let input = "\(sessionId):\(chunkIndex):\(chunkHash)"
        let hash = _SHA256.hash(data: Data(input.utf8))
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
    
    /// Check if chunk idempotency key exists.
    ///
    /// - Parameter key: Idempotency key
    /// - Returns: Cached entry if exists, nil otherwise
    public func checkChunkIdempotency(key: String) async -> IdempotencyCacheEntry? {
        // Check local cache first
        if let entry = cache[key] {
            let now = Date()
            if now.timeIntervalSince(entry.timestamp) <= cacheTTL {
                return entry
            } else {
                cache.removeValue(forKey: key)
            }
        }
        
        // Check base handler
        return await baseIdempotencyHandler.checkIdempotency(key: key)
    }
    
    /// Store chunk idempotency key.
    ///
    /// - Parameters:
    ///   - key: Idempotency key
    ///   - response: Response data
    ///   - statusCode: HTTP status code
    public func storeChunkIdempotency(key: String, response: Data, statusCode: Int) async {
        let entry = IdempotencyCacheEntry(
            key: key,
            response: response,
            statusCode: statusCode,
            timestamp: Date()
        )
        
        cache[key] = entry
        await baseIdempotencyHandler.storeIdempotency(key: key, response: response, statusCode: statusCode)
        
        // Cleanup expired entries
        cleanupExpiredEntries()
    }
    
    /// Clean up expired entries.
    private func cleanupExpiredEntries() {
        let now = Date()
        cache = cache.filter { (_, entry) in
            now.timeIntervalSince(entry.timestamp) <= cacheTTL
        }
    }
}
