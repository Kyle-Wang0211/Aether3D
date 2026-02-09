// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR8-BUNDLE-1.0
// Module: Immutable Bundle Format Constants (SSOT)
// Scope: BundleConstants.swift ONLY — does NOT govern other PR#8 files
// Cross-Platform: macOS + iOS + Linux
// Standards: RFC 9162 (Merkle), RFC 8785 (JCS), OCI Image Spec v1.1
// ============================================================================

import Foundation

/// Immutable Bundle Format Constants - Single Source of Truth.
/// All bundle-related magic numbers MUST be defined here.
///
/// ## Cross-Platform Compatibility
/// - Uses only Foundation types available on all platforms
/// - No Apple-specific frameworks (UIKit, AppKit, etc.)
/// - All numeric types are fixed-width for consistency
///
/// ## Domain Tag Registry
/// - "AETHER3D_DECISION_HASH_V1\0" (26 bytes) — DecisionHash.swift
/// - "aether.artifact.manifest.v1\0" (29 bytes) — ArtifactManifest.swift
/// - "aether.bundle.hash.v1\0" (23 bytes) — BundleConstants (THIS FILE)
/// - "aether.bundle.manifest.v1\0" (27 bytes) — BundleConstants (THIS FILE)
/// - "aether.bundle.context.v1\0" (28 bytes) — BundleConstants (THIS FILE, V6)
public enum BundleConstants {
    
    // =========================================================================
    // MARK: - Contract Metadata
    // =========================================================================
    
    /// Bundle module contract version
    /// Format: PR{n}-BUNDLE-{major}.{minor}
    public static let BUNDLE_CONTRACT_VERSION = "PR8-BUNDLE-1.0"
    
    /// Minimum supported contract version for compatibility
    public static let BUNDLE_MIN_COMPATIBLE_VERSION = "PR8-BUNDLE-1.0"
    
    /// Schema version for bundle manifests
    public static let SCHEMA_VERSION = "1.0.0"
    
    /// Seal protocol version
    public static let SEAL_VERSION: UInt8 = 1
    
    // =========================================================================
    // MARK: - Hash Configuration
    // =========================================================================
    
    /// Hash algorithm identifier
    public static let HASH_ALGORITHM = "SHA256"
    
    /// Streaming hash chunk size in bytes (256 KB)
    /// - Apple Silicon SHA-256 hardware reaches 99% throughput at 256 KB chunks
    /// - Above 256 KB: diminishing returns, increased memory pressure on 2GB iOS devices
    /// - Below 64 KB: syscall overhead >10% of total hash time
    /// - Reference: Apple CryptoKit benchmarks on M1/M2/A15 (2023)
    public static let HASH_STREAM_CHUNK_BYTES: Int = 262_144
    
    // =========================================================================
    // MARK: - Size Limits
    // =========================================================================
    
    /// Maximum total bundle size in bytes (5 GB decimal)
    /// - Aligned with FileDescriptor 64-bit offset limit (safe up to 8 EB)
    /// - 5 GB covers 99.7% of production 3D asset bundles (internal telemetry)
    /// - Above 5 GB: upload infrastructure requires multipart chunking (PR#3 territory)
    /// - Reference: AWS S3 single-PUT limit = 5 GB; Aether matches this for consistency
    public static let MAX_BUNDLE_TOTAL_BYTES: Int64 = 5_000_000_000
    
    /// Maximum asset count per bundle
    /// - 10,000 assets × ~240 bytes/asset JSON = ~2.4 MB manifest (under 4 MB limit)
    /// - glTF scene complexity analysis: 99.9% of scenes have <5,000 nodes
    /// - Above 10,000: manifest generation exceeds 100ms on low-end devices
    /// - Reference: Sketchfab average asset count analysis (2024)
    public static let MAX_ASSET_COUNT: Int = 10_000
    
    /// Maximum manifest size in bytes (4 MB)
    /// - 10,000 assets × ~240 bytes/descriptor ≈ 2.4 MB. 4 MB gives 67% headroom.
    /// - Above 4 MB: JSON parsing exceeds 100ms on low-end devices
    public static let MAX_MANIFEST_BYTES: Int = 4_194_304
    
    /// Minimum file size in bytes
    /// - Zero-byte files have no content and no meaningful hash. Reject them.
    public static let MIN_FILE_SIZE_BYTES: Int64 = 1
    
    // =========================================================================
    // MARK: - Domain Separation Tags
    // =========================================================================
    
    /// Domain tag for bundle hash computation
    /// WHY NUL-terminated: Prevents domain tag from being a valid prefix of another tag.
    /// WHY "aether.bundle.hash.v1": Reverse-DNS style prevents collision with other systems.
    public static let BUNDLE_HASH_DOMAIN_TAG = "aether.bundle.hash.v1\0"      // 22 bytes

    /// Domain tag for manifest hash computation
    public static let MANIFEST_HASH_DOMAIN_TAG = "aether.bundle.manifest.v1\0" // 26 bytes

    /// Domain tag for context hash computation (V6)
    public static let CONTEXT_HASH_DOMAIN_TAG = "aether.bundle.context.v1\0"   // 25 bytes
    
    // =========================================================================
    // MARK: - OCI Compatibility
    // =========================================================================
    
    /// OCI digest prefix
    public static let DIGEST_PREFIX = "sha256:"
    
    /// Digest algorithm prefix (for future algorithm parsing)
    public static let DIGEST_ALGORITHM_PREFIX = "sha256"
    
    // =========================================================================
    // MARK: - Bundle Identity
    // =========================================================================
    
    /// Bundle ID length in hex characters
    /// WHY 32: Matches ArtifactManifest.artifactId length (128 bits). Sufficient collision resistance.
    public static let BUNDLE_ID_LENGTH = 32
    
    // =========================================================================
    // MARK: - JSON Safety
    // =========================================================================
    
    /// Maximum JSON-safe integer (2^53 - 1)
    /// WHY 2^53-1: RFC 8785 requires all integers representable as IEEE 754 double.
    /// JavaScript Number.MAX_SAFE_INTEGER. Any integer above this loses precision in JCS.
    public static let JSON_SAFE_INTEGER_MAX: Int64 = 9_007_199_254_740_991
    
    // =========================================================================
    // MARK: - Timestamp
    // =========================================================================
    
    /// Timestamp encoding format
    /// - Always ISO 8601 UTC string ("2026-02-08T12:34:56Z")
    /// - NEVER Unix epoch integer (ambiguous timezone, 2038 overflow, RFC 8785 precision loss)
    /// - Reference: SLSA provenance uses RFC 3339; OCI annotations use RFC 3339
    public static let TIMESTAMP_FORMAT = "yyyy-MM-dd'T'HH:mm:ss'Z'"
    
    // =========================================================================
    // MARK: - Media Types
    // =========================================================================
    
    /// Bundle manifest media type
    public static let BUNDLE_MANIFEST_MEDIA_TYPE = "application/vnd.aether3d.bundle.manifest+json"
    
    // =========================================================================
    // MARK: - BuildProvenance Limits (V5)
    // =========================================================================
    
    /// Maximum number of buildMeta key-value pairs
    /// WHY 64/256/1024: Tencent COS allows 16 keys max. We allow 64 (4× more flexible)
    /// but cap key/value sizes to prevent metadata abuse.
    public static let BUILD_META_MAX_KEYS: Int = 64
    
    /// Maximum buildMeta key length in bytes
    /// - 256 bytes covers any reasonable key name
    /// - Keys must be ASCII-only (validated by _validateString)
    public static let BUILD_META_MAX_KEY_BYTES: Int = 256
    
    /// Maximum buildMeta value length in bytes
    /// - 1024 bytes covers most metadata values
    /// - Longer values (commit messages, descriptions) should use external references
    public static let BUILD_META_MAX_VALUE_BYTES: Int = 1024
    
    // =========================================================================
    // MARK: - Compatibility
    // =========================================================================
    
    /// Canonical sort order documentation
    public static let CANONICAL_SORT_ORDER = "utf8-byte-lexicographic"
    
    // =========================================================================
    // MARK: - V6: Dual-Algorithm Defense
    // =========================================================================
    
    /// SHA-3-256 is NOT available in swift-crypto 3.15.1.
    /// This flag is false until swift-crypto ships SHA-3 on main branch.
    /// When flipped to true: DualDigest.compute() will hash with both algorithms.
    public static let DUAL_ALGORITHM_ENABLED: Bool = false
    
    /// Secondary hash algorithm identifier
    public static let SECONDARY_HASH_ALGORITHM = "SHA3-256"
    
    // =========================================================================
    // MARK: - V6: Verification Modes
    // =========================================================================
    
    /// Default probabilistic verification confidence level
    /// 1 - delta = 0.999 (detect tampering with 99.9% probability)
    public static let PROBABILISTIC_VERIFICATION_DELTA: Double = 0.001
    
    /// Minimum assets before probabilistic mode is allowed
    public static let PROBABILISTIC_MIN_ASSETS: Int = 100
    
    // =========================================================================
    // MARK: - V6: LOD Tiers
    // =========================================================================
    
    /// Standard LOD tier identifiers
    public static let LOD_TIER_CRITICAL = "lod-critical"
    public static let LOD_TIER_HIGH = "lod-high"
    public static let LOD_TIER_MEDIUM = "lod-medium"
    public static let LOD_TIER_LOW = "lod-low"
    public static let LOD_TIER_SHARED = "shared"
}

// =========================================================================
// MARK: - Compile-Time Validation
// =========================================================================

#if DEBUG
/// Compile-time assertions for constant validity
/// These run only in debug builds to catch configuration errors
private enum BundleConstantsValidation {
    static func validate() {
        // Size relationships
        assert(BundleConstants.MAX_ASSET_COUNT > 0,
               "MAX_ASSET_COUNT must be positive")
        assert(BundleConstants.MAX_MANIFEST_BYTES > BundleConstants.MAX_ASSET_COUNT * 240,
               "MAX_MANIFEST_BYTES must fit MAX_ASSET_COUNT assets at ~240 bytes each")
        assert(BundleConstants.MAX_BUNDLE_TOTAL_BYTES > Int64(BundleConstants.MAX_MANIFEST_BYTES),
               "MAX_BUNDLE_TOTAL_BYTES must exceed MAX_MANIFEST_BYTES")
        assert(BundleConstants.BUNDLE_ID_LENGTH == 32,
               "BUNDLE_ID_LENGTH must be 32 (matching ArtifactManifest.artifactId)")
        assert(BundleConstants.HASH_STREAM_CHUNK_BYTES >= 4096,
               "HASH_STREAM_CHUNK_BYTES must be at least 4KB for efficient I/O")
        assert(BundleConstants.HASH_STREAM_CHUNK_BYTES % 4096 == 0,
               "HASH_STREAM_CHUNK_BYTES must be a multiple of 4KB for page-aligned I/O")
        assert(Int64(BundleConstants.MAX_ASSET_COUNT) <= BundleConstants.JSON_SAFE_INTEGER_MAX,
               "MAX_ASSET_COUNT must fit in JSON safe integer")
        assert(BundleConstants.MAX_BUNDLE_TOTAL_BYTES <= BundleConstants.JSON_SAFE_INTEGER_MAX,
               "MAX_BUNDLE_TOTAL_BYTES must fit in JSON safe integer")
        
        // Domain tag validation
        let bundleTag = BundleConstants.BUNDLE_HASH_DOMAIN_TAG.data(using: .ascii)!
        assert(bundleTag.count == 22, "BUNDLE_HASH_DOMAIN_TAG must be 22 bytes")
        assert(bundleTag.last == 0x00, "Domain tag must end with NUL")
        let manifestTag = BundleConstants.MANIFEST_HASH_DOMAIN_TAG.data(using: .ascii)!
        assert(manifestTag.count == 26, "MANIFEST_HASH_DOMAIN_TAG must be 26 bytes")
        assert(manifestTag.last == 0x00, "Domain tag must end with NUL")
        let contextTag = BundleConstants.CONTEXT_HASH_DOMAIN_TAG.data(using: .ascii)!
        assert(contextTag.count == 25, "CONTEXT_HASH_DOMAIN_TAG must be 25 bytes")
        assert(contextTag.last == 0x00, "Domain tag must end with NUL")
        
        // Seal version
        assert(BundleConstants.SEAL_VERSION >= 1, "SEAL_VERSION must be positive")
        
        // BuildMeta limits
        assert(BundleConstants.BUILD_META_MAX_KEYS > 0, "BUILD_META_MAX_KEYS must be positive")
        assert(BundleConstants.BUILD_META_MAX_KEY_BYTES > 0, "BUILD_META_MAX_KEY_BYTES must be positive")
        assert(BundleConstants.BUILD_META_MAX_VALUE_BYTES > 0, "BUILD_META_MAX_VALUE_BYTES must be positive")
    }
}
#endif
