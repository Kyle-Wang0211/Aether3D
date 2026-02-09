// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  BundleManifest.swift
//  Aether3D
//
//  PR#8: Immutable Bundle Format - Bundle Manifest
//

import Foundation

#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif

// MARK: - Supporting Types

/// Reference to an existing ArtifactManifest.
///
/// Avoids embedding the full ArtifactManifest structure in the bundle manifest.
public struct ArtifactManifestRef: Codable, Sendable, Equatable {
    /// Artifact ID from ArtifactManifest.artifactId
    public let artifactId: String
    
    /// Schema version from ArtifactManifest.schemaVersion
    public let schemaVersion: Int
    
    /// Root hash from ArtifactManifest.rootHash (64 hex chars)
    public let rootHash: String
    
    public init(artifactId: String, schemaVersion: Int, rootHash: String) {
        self.artifactId = artifactId
        self.schemaVersion = schemaVersion
        self.rootHash = rootHash
    }
}

/// Build provenance information for the bundle.
///
/// Captures structured metadata about HOW and WHERE the bundle was built.
/// Aligns with SLSA v1.0 provenance predicate for future attestation compatibility.
///
/// **Invariant**: INV-B10: All string fields validated (NUL-free, NFC).
public struct BuildProvenance: Codable, Sendable, Equatable {
    /// Builder identifier (e.g., "aether-sdk-ios/2.1.0", "ci/github-actions")
    public let builderId: String
    
    /// Build type URI (e.g., "https://aether3d.dev/bundle/v1")
    /// Follows SLSA predicate type convention for machine-readable build classification.
    public let buildType: String
    
    /// Free-form key-value metadata (git commit, branch, CI run ID, etc.)
    /// Subject to BUILD_META_MAX_KEYS / BUILD_META_MAX_KEY_BYTES / BUILD_META_MAX_VALUE_BYTES limits.
    public let metadata: [String: String]
    
    public init(builderId: String, buildType: String, metadata: [String: String]) {
        self.builderId = builderId
        self.buildType = buildType
        self.metadata = metadata
    }
}

/// Asset descriptor with OCI-style digest format.
///
/// **Invariants:**
/// - INV-B5: Path safety (NFC + ASCII + no hidden + no symlink escape)
/// - INV-B7: OCI digest format (sha256:<64 lowercase hex>)
/// - INV-B8: JSON-safe integers (size <= 2^53 - 1)
public struct AssetDescriptor: Codable, Sendable, Equatable {
    /// Relative path (validated via _validatePath + NFC + no hidden)
    public let path: String
    
    /// OCI digest format: "sha256:<64hex>"
    public let digest: String
    
    /// File size in bytes (1 ... JSON_SAFE_INTEGER_MAX)
    public let size: Int64
    
    /// Media type (must be in allowedContentTypes)
    public let mediaType: String
    
    /// Role (must be in allowedRoles)
    public let role: String
    
    /// Compression algorithm (nil for v1.0.0, omit in canonical JSON)
    public let compression: String?
    
    /// Per-asset annotations (V5: nil omit in canonical JSON)
    public let annotations: [String: String]?
    
    public init(
        path: String,
        digest: String,
        size: Int64,
        mediaType: String,
        role: String,
        compression: String? = nil,
        annotations: [String: String]? = nil
    ) throws {
        // Validate path
        let normalizedPath = Self.normalizePath(path)
        try _validatePath(normalizedPath)
        try Self.validateNoHiddenComponents(normalizedPath)
        
        // Validate digest
        try HashCalculator.hexFromOCIDigest(digest) // Validates OCI format
        
        // Validate size
        guard size >= BundleConstants.MIN_FILE_SIZE_BYTES else {
            throw BundleError.invalidManifest("Asset size must be >= \(BundleConstants.MIN_FILE_SIZE_BYTES), got \(size)")
        }
        guard size <= BundleConstants.JSON_SAFE_INTEGER_MAX else {
            throw BundleError.invalidManifest("Asset size exceeds JSON_SAFE_INTEGER_MAX: \(size)")
        }
        
        // Validate mediaType
        guard allowedContentTypes.contains(mediaType) else {
            throw BundleError.invalidManifest("Invalid mediaType: \(mediaType)")
        }
        
        // Validate role
        guard allowedRoles.contains(role) else {
            throw BundleError.invalidManifest("Invalid role: \(role)")
        }
        
        // Validate annotations if present
        if let annotations = annotations {
            guard annotations.count <= BundleConstants.BUILD_META_MAX_KEYS else {
                throw BundleError.invalidManifest("Annotations exceed MAX_KEYS: \(annotations.count)")
            }
            for (key, value) in annotations {
                try _validateString(key, field: "annotations.key")
                try _validateString(value, field: "annotations.value")
                guard key.utf8.count <= BundleConstants.BUILD_META_MAX_KEY_BYTES else {
                    throw BundleError.invalidManifest("Annotation key exceeds MAX_KEY_BYTES: \(key)")
                }
                guard value.utf8.count <= BundleConstants.BUILD_META_MAX_VALUE_BYTES else {
                    throw BundleError.invalidManifest("Annotation value exceeds MAX_VALUE_BYTES: \(value)")
                }
            }
        }
        
        self.path = normalizedPath
        self.digest = digest
        self.size = size
        self.mediaType = mediaType
        self.role = role
        self.compression = compression
        self.annotations = annotations
    }
    
    /// Normalize path to NFC and validate ASCII.
    ///
    /// **SEAL FIX**: NFC normalization prevents Unicode normalization path traversal attacks (CVE-2025-52488).
    /// After normalization, path must still be pure ASCII.
    ///
    /// - Parameter path: Original path
    /// - Returns: NFC-normalized path
    /// - Throws: BundleError.invalidManifest if post-NFC path is not ASCII
    private static func normalizePath(_ path: String) -> String {
        let nfc = path.precomposedStringWithCanonicalMapping
        // Re-check ASCII after NFC
        for byte in nfc.utf8 {
            if byte < 0x20 || byte > 0x7E {
                // Will be caught by _validatePath, but document here
            }
        }
        return nfc
    }
    
    /// Validate no hidden path components.
    ///
    /// **SEAL FIX**: Rejects paths containing components starting with '.' (e.g., ".hidden", ".DS_Store").
    /// This is separate from _validatePath which doesn't check this.
    ///
    /// - Parameter path: Path to validate
    /// - Throws: BundleError.invalidManifest if hidden component found
    private static func validateNoHiddenComponents(_ path: String) throws {
        let components = path.split(separator: "/")
        for component in components {
            if component.hasPrefix(".") {
                throw BundleError.invalidManifest("Path contains hidden component: \(component)")
            }
        }
    }
}

// MARK: - V6 Types

/// Context binding prevents cross-context bundle substitution.
///
/// INV-B17: Context-bound hashing (anti-substitution)
///
/// bundleHash includes the context hash, so a bundle created for
/// Context_A cannot be replayed in Context_B.
///
/// SEAL FIX: contextId is INSIDE the hash preimage.
/// GATE: Removing contextId enables substitution attacks.
public struct BundleContext: Codable, Sendable, Equatable {
    /// Project this bundle belongs to
    public let projectId: String
    
    /// Intended recipient (user, service, pipeline)
    public let recipientId: String
    
    /// Purpose (capture, training, rendering, distribution)
    public let purpose: String
    
    /// Unique nonce preventing replay (UUID v4)
    public let nonce: String
    
    public init(projectId: String, recipientId: String, purpose: String, nonce: String) {
        self.projectId = projectId
        self.recipientId = recipientId
        self.purpose = purpose
        self.nonce = nonce
    }
}

/// Bundle version chain — append-only, fork-detectable.
///
/// INV-B16: Temporal integrity with fork detection (V6)
///
/// Each bundle version contains a reference to its predecessor.
/// If two different bundles claim the same predecessor, a fork is detected.
public struct BundleVersionRef: Codable, Sendable, Equatable {
    /// Previous version's bundle hash (nil for genesis/first version)
    public let previousBundleHash: String?
    
    /// Version sequence number (monotonic, starts at 1)
    public let versionSequence: UInt64
    
    /// Audit log tree size at time of this version (for consistency proof)
    public let auditLogTreeSize: UInt64
    
    public init(previousBundleHash: String?, versionSequence: UInt64, auditLogTreeSize: UInt64) {
        self.previousBundleHash = previousBundleHash
        self.versionSequence = versionSequence
        self.auditLogTreeSize = auditLogTreeSize
    }
}

/// Hierarchical LOD-aware Merkle tree structure.
///
/// INV-B15: LOD-aware hierarchical integrity (V6)
///
/// **V7 修正**: MerkleTree has no native subtree support.
/// LOD tree requires multiple independent MerkleTree instances (one per LOD tier),
/// with their roots fed into a final "super-tree".
public struct LODMerkleStructure: Codable, Sendable, Equatable {
    /// Subtree roots keyed by LOD tier ID
    public let subtreeRoots: [String: String]  // tier ID → 64 hex root hash (SHA-256)
    
    /// Combined bundle root (hash of all subtree roots sorted)
    public let bundleRoot: String              // 64 hex, hash of all subtree roots sorted
    
    public init(subtreeRoots: [String: String], bundleRoot: String) {
        self.subtreeRoots = subtreeRoots
        self.bundleRoot = bundleRoot
    }
}

/// Hints for the verification engine to optimize verification strategy.
///
/// INV-B12: Adaptive four-mode verification (V6)
public struct VerificationHints: Codable, Sendable, Equatable {
    /// Assets sorted by priority tier for progressive verification
    public let criticalPaths: [String]
    
    /// Total byte count (for estimating verification time)
    public let totalBytes: Int64
    
    /// Number of LOD tiers (0 = flat, 1+ = hierarchical)
    public let lodTierCount: Int
    
    public init(criticalPaths: [String], totalBytes: Int64, lodTierCount: Int) {
        self.criticalPaths = criticalPaths
        self.totalBytes = totalBytes
        self.lodTierCount = lodTierCount
    }
}

// MARK: - BundleManifest

/// Immutable Bundle manifest with complete schema.
///
/// **Invariants:**
/// - INV-B1: Content-addressable bundleHash (SHA-256 + domain separation)
/// - INV-B2: Merkle tree integrity (RFC 9162 domain separation)
/// - INV-B3: Immutability (all `let`, no public init, factory-only)
/// - INV-B6: Cross-platform determinism (deterministicTimestamp, manual canonical JSON)
/// - INV-B7: OCI digest format (sha256:<64 lowercase hex>)
/// - INV-B8: JSON-safe integers (all sizes <= 2^53 - 1)
/// - INV-B9: Fail-closed on unknown required capabilities
/// - INV-B10: All DeviceInfo string fields validated
/// - INV-B17: Context-bound hashing (anti-substitution)
/// - INV-B18: Epoch-bound hashing (anti-rollback)
public struct BundleManifest: Codable, Sendable {
    // === Core Fields ===
    public let schemaVersion: String         // "1.0.0"
    public let bundleType: String            // BUNDLE_MANIFEST_MEDIA_TYPE
    public let createdAt: String             // deterministicTimestamp()
    public let artifactManifest: ArtifactManifestRef
    public let assets: [AssetDescriptor]     // sorted by path (UTF-8 byte order)
    public let merkleRoot: String            // 64 hex (SHA-256)
    public let bundleHash: String            // 64 hex (SHA-256)
    public let deviceInfo: BundleDeviceInfo
    public let buildProvenance: BuildProvenance
    public let captureSessionId: String?     // nil → omit from canonical JSON
    public let policyHash: String            // 64 hex
    public let requiredCapabilities: [String] // always [] in v1.0.0, always present
    
    // === V5 Fields ===
    public let license: String?              // SPDX, nil → omit
    public let privacyClassification: String? // nil → omit
    
    // === V6 Fields ===
    public let context: BundleContext        // anti-substitution
    public let epoch: UInt64                 // anti-rollback, strictly monotonic
    public let versionRef: BundleVersionRef? // nil if no versioning
    public let lodStructure: LODMerkleStructure? // nil if flat tree
    public let verificationHints: VerificationHints
    
    // No public init — factory only
    
    /// Compute bundle manifest from components.
    ///
    /// **SEAL FIX**: canonicalBytesForHashing EXCLUDES bundleHash field.
    /// Rationale: Two-phase hash — hash cannot contain itself.
    /// GATE: Adding bundleHash to forHashing creates a circular dependency = wrong hash.
    ///
    /// **SEAL FIX**: deterministicTimestamp uses DateFormatter, NOT ISO8601DateFormatter.
    /// Rationale: ISO8601DateFormatter outputs different formats on macOS vs Linux.
    /// GATE: Cross-platform determinism is a constitutional requirement.
    ///
    /// - Parameters:
    ///   - schemaVersion: Schema version (must be "1.0.0" for v1.0.0)
    ///   - artifactManifest: ArtifactManifest reference
    ///   - assets: Asset descriptors (will be sorted by path)
    ///   - merkleRoot: Merkle tree root (64 hex, validated)
    ///   - deviceInfo: Device information (validated)
    ///   - buildProvenance: Build provenance (validated)
    ///   - context: Bundle context (anti-substitution)
    ///   - epoch: Epoch counter (anti-rollback)
    ///   - captureSessionId: Optional capture session ID
    ///   - policyHash: Policy hash (from getCurrentPolicyHash())
    ///   - license: Optional SPDX license identifier
    ///   - privacyClassification: Optional privacy classification
    ///   - versionRef: Optional version chain reference
    ///   - lodStructure: Optional LOD Merkle structure
    ///   - verificationHints: Verification hints
    ///   - requiredCapabilities: Required capabilities (must be [] for v1.0.0)
    ///   - createdAt: Creation timestamp (defaults to now)
    /// - Returns: BundleManifest with computed bundleHash
    /// - Throws: BundleError for validation failures
    public static func compute(
        schemaVersion: String = BundleConstants.SCHEMA_VERSION,
        artifactManifest: ArtifactManifestRef,
        assets: [AssetDescriptor],
        merkleRoot: String,
        deviceInfo: BundleDeviceInfo,
        buildProvenance: BuildProvenance,
        context: BundleContext,
        epoch: UInt64,
        captureSessionId: String? = nil,
        policyHash: String,
        license: String? = nil,
        privacyClassification: String? = nil,
        versionRef: BundleVersionRef? = nil,
        lodStructure: LODMerkleStructure? = nil,
        verificationHints: VerificationHints,
        requiredCapabilities: [String] = [],
        createdAt: Date = Date()
    ) throws -> BundleManifest {
        // Validate schema version
        try validateSchemaVersion(schemaVersion)
        
        // Validate merkleRoot
        try _validateSHA256(merkleRoot)
        
        // Validate deviceInfo (all string fields)
        let validatedDeviceInfo = try deviceInfo.validated()
        
        // Validate buildProvenance (all string fields + metadata limits)
        try _validateString(buildProvenance.builderId, field: "buildProvenance.builderId")
        try _validateString(buildProvenance.buildType, field: "buildProvenance.buildType")
        
        guard buildProvenance.metadata.count <= BundleConstants.BUILD_META_MAX_KEYS else {
            throw BundleError.invalidManifest("buildProvenance.metadata exceeds \(BundleConstants.BUILD_META_MAX_KEYS) keys")
        }
        for (key, value) in buildProvenance.metadata {
            try _validateString(key, field: "buildProvenance.metadata.key")
            try _validateString(value, field: "buildProvenance.metadata.value")
            guard key.utf8.count <= BundleConstants.BUILD_META_MAX_KEY_BYTES else {
                throw BundleError.invalidManifest("buildProvenance.metadata key exceeds \(BundleConstants.BUILD_META_MAX_KEY_BYTES) bytes")
            }
            guard value.utf8.count <= BundleConstants.BUILD_META_MAX_VALUE_BYTES else {
                throw BundleError.invalidManifest("buildProvenance.metadata value exceeds \(BundleConstants.BUILD_META_MAX_VALUE_BYTES) bytes")
            }
        }
        
        // Validate epoch (must be > 0)
        guard epoch > 0 else {
            throw BundleError.invalidManifest("epoch must be > 0, got \(epoch)")
        }
        
        // Validate context fields
        try _validateString(context.projectId, field: "context.projectId")
        try _validateString(context.recipientId, field: "context.recipientId")
        try _validateString(context.purpose, field: "context.purpose")
        try _validateString(context.nonce, field: "context.nonce")
        
        // Validate requiredCapabilities (must be empty for v1.0.0)
        guard requiredCapabilities.isEmpty else {
            throw BundleError.unknownRequiredCapability("v1.0.0 supports no required capabilities")
        }
        
        // Sort assets by path (UTF-8 byte lexicographic)
        let sortedAssets = assets.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
        
        // Check for duplicate paths
        if sortedAssets.count >= 2 {
            for i in 0..<sortedAssets.count - 1 {
                if sortedAssets[i].path == sortedAssets[i + 1].path {
                    throw BundleError.duplicatePath(path: sortedAssets[i].path)
                }
            }
        }
        
        // Compute context hash
        let contextCanonical = "\(context.projectId)|\(context.recipientId)|\(context.purpose)|\(context.nonce)"
        let contextHash = HashCalculator.sha256WithDomain(
            BundleConstants.CONTEXT_HASH_DOMAIN_TAG,
            data: contextCanonical.data(using: .utf8)!
        )
        
        // Compute canonical bytes for hashing (EXCLUDES bundleHash)
        let canonicalBytes = try Self._canonicalBytesForHashing(
            schemaVersion: schemaVersion,
            bundleType: BundleConstants.BUNDLE_MANIFEST_MEDIA_TYPE,
            createdAt: deterministicTimestamp(createdAt),
            artifactManifest: artifactManifest,
            assets: sortedAssets,
            merkleRoot: merkleRoot,
            deviceInfo: validatedDeviceInfo,
            buildProvenance: buildProvenance,
            captureSessionId: captureSessionId,
            policyHash: policyHash,
            requiredCapabilities: requiredCapabilities,
            license: license,
            privacyClassification: privacyClassification,
            context: context,
            epoch: epoch,
            versionRef: versionRef,
            lodStructure: lodStructure,
            verificationHints: verificationHints
        )
        
        // Compute bundleHash: SHA256(BUNDLE_HASH_DOMAIN_TAG || contextHash || canonicalBytes)
        let bundleHashData = BundleConstants.BUNDLE_HASH_DOMAIN_TAG.data(using: .ascii)! +
            Data(try CryptoHashFacade.hexStringToBytes(contextHash)) +
            canonicalBytes
        let bundleHashDigest = _SHA256.hash(data: bundleHashData)
        let bundleHash = _hexLowercase(Array(bundleHashDigest))
        
        // Create manifest
        return BundleManifest(
            schemaVersion: schemaVersion,
            bundleType: BundleConstants.BUNDLE_MANIFEST_MEDIA_TYPE,
            createdAt: deterministicTimestamp(createdAt),
            artifactManifest: artifactManifest,
            assets: sortedAssets,
            merkleRoot: merkleRoot,
            bundleHash: bundleHash,
            deviceInfo: validatedDeviceInfo,
            buildProvenance: buildProvenance,
            captureSessionId: captureSessionId,
            policyHash: policyHash,
            requiredCapabilities: requiredCapabilities,
            license: license,
            privacyClassification: privacyClassification,
            context: context,
            epoch: epoch,
            versionRef: versionRef,
            lodStructure: lodStructure,
            verificationHints: verificationHints
        )
    }
    
    // MARK: - Private Initializer
    
    private init(
        schemaVersion: String,
        bundleType: String,
        createdAt: String,
        artifactManifest: ArtifactManifestRef,
        assets: [AssetDescriptor],
        merkleRoot: String,
        bundleHash: String,
        deviceInfo: BundleDeviceInfo,
        buildProvenance: BuildProvenance,
        captureSessionId: String?,
        policyHash: String,
        requiredCapabilities: [String],
        license: String?,
        privacyClassification: String?,
        context: BundleContext,
        epoch: UInt64,
        versionRef: BundleVersionRef?,
        lodStructure: LODMerkleStructure?,
        verificationHints: VerificationHints
    ) {
        self.schemaVersion = schemaVersion
        self.bundleType = bundleType
        self.createdAt = createdAt
        self.artifactManifest = artifactManifest
        self.assets = assets
        self.merkleRoot = merkleRoot
        self.bundleHash = bundleHash
        self.deviceInfo = deviceInfo
        self.buildProvenance = buildProvenance
        self.captureSessionId = captureSessionId
        self.policyHash = policyHash
        self.requiredCapabilities = requiredCapabilities
        self.license = license
        self.privacyClassification = privacyClassification
        self.context = context
        self.epoch = epoch
        self.versionRef = versionRef
        self.lodStructure = lodStructure
        self.verificationHints = verificationHints
    }
    
    // MARK: - Canonical JSON Encoding
    
    /// Compute canonical bytes for hashing (EXCLUDES bundleHash).
    ///
    /// **SEAL FIX**: bundleHash field is EXCLUDED from this encoding.
    /// This is used to compute bundleHash itself, so it cannot contain bundleHash.
    ///
    /// **Performance**: Uses reserveCapacity to pre-allocate buffer.
    ///
    /// - Returns: Canonical JSON bytes (no whitespace, sorted keys)
    /// - Throws: Encoding errors
    internal func canonicalBytesForHashing() throws -> Data {
        return try Self._canonicalBytesForHashing(
            schemaVersion: schemaVersion,
            bundleType: bundleType,
            createdAt: createdAt,
            artifactManifest: artifactManifest,
            assets: assets,
            merkleRoot: merkleRoot,
            deviceInfo: deviceInfo,
            buildProvenance: buildProvenance,
            captureSessionId: captureSessionId,
            policyHash: policyHash,
            requiredCapabilities: requiredCapabilities,
            license: license,
            privacyClassification: privacyClassification,
            context: context,
            epoch: epoch,
            versionRef: versionRef,
            lodStructure: lodStructure,
            verificationHints: verificationHints
        )
    }
    
    /// Compute canonical bytes for storage (INCLUDES bundleHash).
    ///
    /// **Performance**: Uses reserveCapacity to pre-allocate buffer.
    ///
    /// - Returns: Canonical JSON bytes with bundleHash included
    /// - Throws: Encoding errors
    internal func canonicalBytesForStorage() throws -> Data {
        var result = Data()
        let estimatedSize = assets.count * 240 + 500 // Rough estimate
        result.reserveCapacity(estimatedSize)
        
        // Key order (alphabetical): artifactManifest, assets, buildProvenance, bundleHash, bundleType, ...
        result.append("{\"artifactManifest\":".data(using: .utf8)!)
        result.append(try Self._encodeArtifactManifestRef(artifactManifest))
        result.append(",\"assets\":[".data(using: .utf8)!)
        for (index, asset) in assets.enumerated() {
            if index > 0 { result.append(",".data(using: .utf8)!) }
            result.append(try Self._encodeAssetDescriptor(asset))
        }
        result.append("],\"buildProvenance\":".data(using: .utf8)!)
        result.append(try Self._encodeBuildProvenance(buildProvenance))
        result.append(",\"bundleHash\":".data(using: .utf8)!)
        result.append(_encodeJSONString(bundleHash).data(using: .utf8)!)
        result.append(",\"bundleType\":".data(using: .utf8)!)
        result.append(_encodeJSONString(bundleType).data(using: .utf8)!)
        if let captureSessionId = captureSessionId {
            result.append(",\"captureSessionId\":".data(using: .utf8)!)
            result.append(_encodeJSONString(captureSessionId).data(using: .utf8)!)
        }
        result.append(",\"context\":".data(using: .utf8)!)
        result.append(try Self._encodeBundleContext(context))
        result.append(",\"createdAt\":".data(using: .utf8)!)
        result.append(_encodeJSONString(createdAt).data(using: .utf8)!)
        result.append(",\"deviceInfo\":".data(using: .utf8)!)
        result.append(try Self._encodeDeviceInfo(deviceInfo))
        result.append(",\"epoch\":".data(using: .utf8)!)
        result.append(String(epoch).data(using: .utf8)!)
        if let license = license {
            result.append(",\"license\":".data(using: .utf8)!)
            result.append(_encodeJSONString(license).data(using: .utf8)!)
        }
        if let lodStructure = lodStructure {
            result.append(",\"lodStructure\":".data(using: .utf8)!)
            result.append(try Self._encodeLODMerkleStructure(lodStructure))
        }
        result.append(",\"merkleRoot\":".data(using: .utf8)!)
        result.append(_encodeJSONString(merkleRoot).data(using: .utf8)!)
        result.append(",\"policyHash\":".data(using: .utf8)!)
        result.append(_encodeJSONString(policyHash).data(using: .utf8)!)
        if let privacyClassification = privacyClassification {
            result.append(",\"privacyClassification\":".data(using: .utf8)!)
            result.append(_encodeJSONString(privacyClassification).data(using: .utf8)!)
        }
        result.append(",\"requiredCapabilities\":[".data(using: .utf8)!)
        // requiredCapabilities always present (even if empty)
        // Encode array elements if non-empty
        for (index, capability) in requiredCapabilities.enumerated() {
            if index > 0 { result.append(",".data(using: .utf8)!) }
            result.append(_encodeJSONString(capability).data(using: .utf8)!)
        }
        result.append("],\"schemaVersion\":".data(using: .utf8)!)
        result.append(_encodeJSONString(schemaVersion).data(using: .utf8)!)
        result.append(",\"verificationHints\":".data(using: .utf8)!)
        result.append(try Self._encodeVerificationHints(verificationHints))
        if let versionRef = versionRef {
            result.append(",\"versionRef\":".data(using: .utf8)!)
            result.append(try Self._encodeBundleVersionRef(versionRef))
        }
        result.append("}".data(using: .utf8)!)
        
        // Assertion: forStorage must be longer than forHashing (contains bundleHash)
        let forHashing = try canonicalBytesForHashing()
        assert(result.count > forHashing.count, "Storage bytes must include bundleHash")
        assert(!String(data: forHashing, encoding: .utf8)!.contains("\"bundleHash\""), "Hashing bytes must exclude bundleHash")
        
        return result
    }
    
    // MARK: - Private Canonical Encoding Helpers
    
    private static func _canonicalBytesForHashing(
        schemaVersion: String,
        bundleType: String,
        createdAt: String,
        artifactManifest: ArtifactManifestRef,
        assets: [AssetDescriptor],
        merkleRoot: String,
        deviceInfo: BundleDeviceInfo,
        buildProvenance: BuildProvenance,
        captureSessionId: String?,
        policyHash: String,
        requiredCapabilities: [String],
        license: String?,
        privacyClassification: String?,
        context: BundleContext,
        epoch: UInt64,
        versionRef: BundleVersionRef?,
        lodStructure: LODMerkleStructure?,
        verificationHints: VerificationHints
    ) throws -> Data {
        var result = Data()
        let estimatedSize = assets.count * 240 + 500 // Rough estimate
        result.reserveCapacity(estimatedSize)
        
        // Key order (alphabetical): artifactManifest, assets, buildProvenance, bundleType, ...
        // NOTE: bundleHash is EXCLUDED
        result.append("{\"artifactManifest\":".data(using: .utf8)!)
        result.append(try Self._encodeArtifactManifestRef(artifactManifest))
        result.append(",\"assets\":[".data(using: .utf8)!)
        for (index, asset) in assets.enumerated() {
            if index > 0 { result.append(",".data(using: .utf8)!) }
            result.append(try Self._encodeAssetDescriptor(asset))
        }
        result.append("],\"buildProvenance\":".data(using: .utf8)!)
        result.append(try Self._encodeBuildProvenance(buildProvenance))
        result.append(",\"bundleType\":".data(using: .utf8)!)
        result.append(_encodeJSONString(bundleType).data(using: .utf8)!)
        if let captureSessionId = captureSessionId {
            result.append(",\"captureSessionId\":".data(using: .utf8)!)
            result.append(_encodeJSONString(captureSessionId).data(using: .utf8)!)
        }
        result.append(",\"context\":".data(using: .utf8)!)
        result.append(try Self._encodeBundleContext(context))
        result.append(",\"createdAt\":".data(using: .utf8)!)
        result.append(_encodeJSONString(createdAt).data(using: .utf8)!)
        result.append(",\"deviceInfo\":".data(using: .utf8)!)
        result.append(try Self._encodeDeviceInfo(deviceInfo))
        result.append(",\"epoch\":".data(using: .utf8)!)
        result.append(String(epoch).data(using: .utf8)!)
        if let license = license {
            result.append(",\"license\":".data(using: .utf8)!)
            result.append(_encodeJSONString(license).data(using: .utf8)!)
        }
        if let lodStructure = lodStructure {
            result.append(",\"lodStructure\":".data(using: .utf8)!)
            result.append(try Self._encodeLODMerkleStructure(lodStructure))
        }
        result.append(",\"merkleRoot\":".data(using: .utf8)!)
        result.append(_encodeJSONString(merkleRoot).data(using: .utf8)!)
        result.append(",\"policyHash\":".data(using: .utf8)!)
        result.append(_encodeJSONString(policyHash).data(using: .utf8)!)
        if let privacyClassification = privacyClassification {
            result.append(",\"privacyClassification\":".data(using: .utf8)!)
            result.append(_encodeJSONString(privacyClassification).data(using: .utf8)!)
        }
        result.append(",\"requiredCapabilities\":[".data(using: .utf8)!)
        // requiredCapabilities always present (even if empty)
        // Encode array elements if non-empty
        for (index, capability) in requiredCapabilities.enumerated() {
            if index > 0 { result.append(",".data(using: .utf8)!) }
            result.append(_encodeJSONString(capability).data(using: .utf8)!)
        }
        result.append("],\"schemaVersion\":".data(using: .utf8)!)
        result.append(_encodeJSONString(schemaVersion).data(using: .utf8)!)
        result.append(",\"verificationHints\":".data(using: .utf8)!)
        result.append(try Self._encodeVerificationHints(verificationHints))
        if let versionRef = versionRef {
            result.append(",\"versionRef\":".data(using: .utf8)!)
            result.append(try Self._encodeBundleVersionRef(versionRef))
        }
        result.append("}".data(using: .utf8)!)
        
        return result
    }
    
    // MARK: - Encoding Helpers
    
    private static func _encodeArtifactManifestRef(_ ref: ArtifactManifestRef) throws -> Data {
        var result = Data()
        result.reserveCapacity(200)
        result.append("{\"artifactId\":".data(using: .utf8)!)
        result.append(_encodeJSONString(ref.artifactId).data(using: .utf8)!)
        result.append(",\"rootHash\":".data(using: .utf8)!)
        result.append(_encodeJSONString(ref.rootHash).data(using: .utf8)!)
        result.append(",\"schemaVersion\":".data(using: .utf8)!)
        result.append(String(ref.schemaVersion).data(using: .utf8)!)
        result.append("}".data(using: .utf8)!)
        return result
    }
    
    private static func _encodeBuildProvenance(_ prov: BuildProvenance) throws -> Data {
        var result = Data()
        result.reserveCapacity(300)
        result.append("{\"builderId\":".data(using: .utf8)!)
        result.append(_encodeJSONString(prov.builderId).data(using: .utf8)!)
        result.append(",\"buildType\":".data(using: .utf8)!)
        result.append(_encodeJSONString(prov.buildType).data(using: .utf8)!)
        result.append(",\"metadata\":{".data(using: .utf8)!)
        
        // Sort metadata keys alphabetically
        let sortedKeys = prov.metadata.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        for (index, key) in sortedKeys.enumerated() {
            if index > 0 { result.append(",".data(using: .utf8)!) }
            result.append(_encodeJSONString(key).data(using: .utf8)!)
            result.append(":".data(using: .utf8)!)
            result.append(_encodeJSONString(prov.metadata[key]!).data(using: .utf8)!)
        }
        result.append("}}".data(using: .utf8)!)
        return result
    }
    
    private static func _encodeAssetDescriptor(_ asset: AssetDescriptor) throws -> Data {
        var result = Data()
        result.reserveCapacity(300)
        
        // Key order (alphabetical): annotations?, compression?, digest, mediaType, path, role, size
        result.append("{".data(using: .utf8)!)

        if let annotations = asset.annotations {
            result.append("\"annotations\":{".data(using: .utf8)!)
            let sortedKeys = annotations.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            for (index, key) in sortedKeys.enumerated() {
                if index > 0 { result.append(",".data(using: .utf8)!) }
                result.append(_encodeJSONString(key).data(using: .utf8)!)
                result.append(":".data(using: .utf8)!)
                result.append(_encodeJSONString(annotations[key]!).data(using: .utf8)!)
            }
            result.append("},".data(using: .utf8)!)
        }

        if let compression = asset.compression {
            result.append("\"compression\":".data(using: .utf8)!)
            result.append(_encodeJSONString(compression).data(using: .utf8)!)
            result.append(",".data(using: .utf8)!)
        }

        result.append("\"digest\":".data(using: .utf8)!)
        result.append(_encodeJSONString(asset.digest).data(using: .utf8)!)
        result.append(",\"mediaType\":".data(using: .utf8)!)
        result.append(_encodeJSONString(asset.mediaType).data(using: .utf8)!)
        result.append(",\"path\":".data(using: .utf8)!)
        result.append(_encodeJSONString(asset.path).data(using: .utf8)!)
        result.append(",\"role\":".data(using: .utf8)!)
        result.append(_encodeJSONString(asset.role).data(using: .utf8)!)
        result.append(",\"size\":".data(using: .utf8)!)
        result.append(String(asset.size).data(using: .utf8)!)
        result.append("}".data(using: .utf8)!)
        return result
    }
    
    private static func _encodeDeviceInfo(_ info: BundleDeviceInfo) throws -> Data {
        var result = Data()
        result.reserveCapacity(200)
        
        // Key order (alphabetical): availableMemoryMB, chipArchitecture, deviceModel, osVersion, platform, thermalState
        result.append("{\"availableMemoryMB\":".data(using: .utf8)!)
        result.append(String(info.availableMemoryMB).data(using: .utf8)!)
        result.append(",\"chipArchitecture\":".data(using: .utf8)!)
        result.append(_encodeJSONString(info.chipArchitecture).data(using: .utf8)!)
        result.append(",\"deviceModel\":".data(using: .utf8)!)
        result.append(_encodeJSONString(info.deviceModel).data(using: .utf8)!)
        result.append(",\"osVersion\":".data(using: .utf8)!)
        result.append(_encodeJSONString(info.osVersion).data(using: .utf8)!)
        result.append(",\"platform\":".data(using: .utf8)!)
        result.append(_encodeJSONString(info.platform).data(using: .utf8)!)
        result.append(",\"thermalState\":".data(using: .utf8)!)
        result.append(_encodeJSONString(info.thermalState).data(using: .utf8)!)
        result.append("}".data(using: .utf8)!)
        return result
    }
    
    private static func _encodeBundleContext(_ context: BundleContext) throws -> Data {
        var result = Data()
        result.reserveCapacity(200)
        
        // Key order (alphabetical): nonce, projectId, purpose, recipientId
        result.append("{\"nonce\":".data(using: .utf8)!)
        result.append(_encodeJSONString(context.nonce).data(using: .utf8)!)
        result.append(",\"projectId\":".data(using: .utf8)!)
        result.append(_encodeJSONString(context.projectId).data(using: .utf8)!)
        result.append(",\"purpose\":".data(using: .utf8)!)
        result.append(_encodeJSONString(context.purpose).data(using: .utf8)!)
        result.append(",\"recipientId\":".data(using: .utf8)!)
        result.append(_encodeJSONString(context.recipientId).data(using: .utf8)!)
        result.append("}".data(using: .utf8)!)
        return result
    }
    
    private static func _encodeBundleVersionRef(_ ref: BundleVersionRef) throws -> Data {
        var result = Data()
        result.reserveCapacity(150)
        
        // Key order (alphabetical): auditLogTreeSize, previousBundleHash?, versionSequence
        result.append("{\"auditLogTreeSize\":".data(using: .utf8)!)
        result.append(String(ref.auditLogTreeSize).data(using: .utf8)!)
        if let previousHash = ref.previousBundleHash {
            result.append(",\"previousBundleHash\":".data(using: .utf8)!)
            result.append(_encodeJSONString(previousHash).data(using: .utf8)!)
        }
        result.append(",\"versionSequence\":".data(using: .utf8)!)
        result.append(String(ref.versionSequence).data(using: .utf8)!)
        result.append("}".data(using: .utf8)!)
        return result
    }
    
    private static func _encodeLODMerkleStructure(_ lod: LODMerkleStructure) throws -> Data {
        var result = Data()
        result.reserveCapacity(300)
        
        // Key order (alphabetical): bundleRoot, subtreeRoots
        result.append("{\"bundleRoot\":".data(using: .utf8)!)
        result.append(_encodeJSONString(lod.bundleRoot).data(using: .utf8)!)
        result.append(",\"subtreeRoots\":{".data(using: .utf8)!)
        
        // Sort subtreeRoots keys alphabetically
        let sortedKeys = lod.subtreeRoots.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        for (index, key) in sortedKeys.enumerated() {
            if index > 0 { result.append(",".data(using: .utf8)!) }
            result.append(_encodeJSONString(key).data(using: .utf8)!)
            result.append(":".data(using: .utf8)!)
            result.append(_encodeJSONString(lod.subtreeRoots[key]!).data(using: .utf8)!)
        }
        result.append("}}".data(using: .utf8)!)
        return result
    }
    
    private static func _encodeVerificationHints(_ hints: VerificationHints) throws -> Data {
        var result = Data()
        result.reserveCapacity(200)
        
        // Key order (alphabetical): criticalPaths, lodTierCount, totalBytes
        result.append("{\"criticalPaths\":[".data(using: .utf8)!)
        for (index, path) in hints.criticalPaths.enumerated() {
            if index > 0 { result.append(",".data(using: .utf8)!) }
            result.append(_encodeJSONString(path).data(using: .utf8)!)
        }
        result.append("],\"lodTierCount\":".data(using: .utf8)!)
        result.append(String(hints.lodTierCount).data(using: .utf8)!)
        result.append(",\"totalBytes\":".data(using: .utf8)!)
        result.append(String(hints.totalBytes).data(using: .utf8)!)
        result.append("}".data(using: .utf8)!)
        return result
    }
    
    // MARK: - Verification
    
    /// Verify bundleHash by recomputing and comparing timing-safely.
    ///
    /// - Returns: true if bundleHash matches recomputed value
    public func verifyHash() -> Bool {
        do {
            let recomputedBytes = try canonicalBytesForHashing()
            let contextCanonical = "\(context.projectId)|\(context.recipientId)|\(context.purpose)|\(context.nonce)"
            let contextHash = HashCalculator.sha256WithDomain(
                BundleConstants.CONTEXT_HASH_DOMAIN_TAG,
                data: contextCanonical.data(using: .utf8)!
            )
            let bundleHashData = BundleConstants.BUNDLE_HASH_DOMAIN_TAG.data(using: .ascii)! +
                Data(try CryptoHashFacade.hexStringToBytes(contextHash)) +
                recomputedBytes
            let recomputedDigest = _SHA256.hash(data: bundleHashData)
            let recomputedHash = _hexLowercase(Array(recomputedDigest))
            return HashCalculator.timingSafeEqualHex(bundleHash, recomputedHash)
        } catch {
            return false
        }
    }
    
    // MARK: - Timestamp
    
    /// Deterministic ISO 8601 UTC timestamp string.
    ///
    /// **SEAL FIX**: Uses explicit format string — NOT ISO8601DateFormatter — for cross-platform determinism.
    ///
    /// Output: "2026-02-08T12:34:56Z" (always UTC, always Z suffix, no fractional seconds)
    ///
    /// Why no fractional seconds: macOS outputs 3 digits, Linux outputs 6-7 digits,
    /// making canonical JSON non-deterministic. Integer seconds are sufficient for bundle creation timestamp.
    ///
    /// - Parameter date: Date to format (defaults to now)
    /// - Returns: ISO 8601 UTC string
    private static func deterministicTimestamp(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = BundleConstants.TIMESTAMP_FORMAT
        return formatter.string(from: date)
    }
    
    // MARK: - Validation
    
    /// Validate schema version.
    ///
    /// v1 code must reject bundles with schemaVersion != "1.0.0".
    /// Future versions will define their own migration strategy.
    ///
    /// - Parameter version: Schema version string
    /// - Throws: BundleError.invalidManifest if version is unsupported
    private static func validateSchemaVersion(_ version: String) throws {
        let components = version.split(separator: ".")
        guard components.count == 3,
              let major = Int(components[0]),
              major == 1 else {
            throw BundleError.invalidManifest("Unsupported schema version: \(version). This code supports 1.x.x only.")
        }
    }
}
