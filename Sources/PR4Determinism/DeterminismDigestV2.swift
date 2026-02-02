//
// DeterminismDigestV2.swift
// PR4Determinism
//
// PR4 V10 - Pillars 7, 29, 35: Versioned digest with field evolution
//

import Foundation

/// Determinism digest V2
///
/// V10 RULE: Digest includes version header and supports field evolution.
public enum DeterminismDigestV2 {
    
    /// Digest version
    public static let currentVersion: UInt16 = 2
    
    /// Digest structure
    public struct Digest: Codable, Equatable {
        /// Version header
        public let version: UInt16
        
        /// Frame ID
        public let frameId: UInt64
        
        /// Digest value (hash)
        public let digestValue: UInt64
        
        /// Mode (STRICT or FAST)
        public let mode: String
        
        /// Timestamp
        public let timestamp: String
        
        /// Path signature (from PathTraceV2)
        public let pathSignature: UInt64?
        
        /// Toolchain fingerprint
        public let toolchainFingerprint: DeterminismBuildContract.ToolchainFingerprint?
        
        /// Platform dependency report
        public let platformDependencies: DeterminismDependencyContract.PlatformDependencyReport?
        
        /// Overflow events
        public let overflowEvents: [OverflowDigestEntry]?
        
        public init(
            frameId: UInt64,
            digestValue: UInt64,
            mode: String,
            timestamp: String,
            pathSignature: UInt64? = nil,
            toolchainFingerprint: DeterminismBuildContract.ToolchainFingerprint? = nil,
            platformDependencies: DeterminismDependencyContract.PlatformDependencyReport? = nil,
            overflowEvents: [OverflowDigestEntry]? = nil
        ) {
            self.version = currentVersion
            self.frameId = frameId
            self.digestValue = digestValue
            self.mode = mode
            self.timestamp = timestamp
            self.pathSignature = pathSignature
            self.toolchainFingerprint = toolchainFingerprint
            self.platformDependencies = platformDependencies
            self.overflowEvents = overflowEvents
        }
    }
    
    /// Overflow digest entry
    public struct OverflowDigestEntry: Codable, Equatable {
        public let field: String
        public let tier: String
        public let count: Int
    }
    
    /// Compute digest from fields
    public static func compute(fields: [String: Int64]) -> Digest {
        // FNV-1a hash
        var hash: UInt64 = 14695981039346656037
        let prime: UInt64 = 1099511628211
        
        // Hash fields in sorted order (deterministic)
        for (key, value) in fields.sorted(by: { $0.key < $1.key }) {
            // Hash key
            for byte in key.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* prime
            }
            // Hash value
            hash ^= UInt64(bitPattern: value)
            hash = hash &* prime
        }
        
        return Digest(
            frameId: 0,  // Set by caller
            digestValue: hash,
            mode: DeterminismMode.current.rawValue,
            timestamp: ISO8601DateFormatter().string(from: Date())
        )
    }
}
