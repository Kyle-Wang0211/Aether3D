// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  ImmutableBundle.swift
//  Aether3D
//
//  PR#8: Immutable Bundle Format - Immutable Bundle Container
//

import Foundation

/// Asset entry for bundle sealing.
///
/// Represents a single file asset with its metadata.
public struct AssetEntry: Sendable {
    /// Relative path within assets directory
    public let path: String
    
    /// Role (must be in allowedRoles)
    public let role: String
    
    /// Media type (must be in allowedContentTypes)
    public let mediaType: String
    
    public init(path: String, role: String, mediaType: String) {
        self.path = path
        self.role = role
        self.mediaType = mediaType
    }
}

/// Sealed, immutable bundle container.
///
/// Created exclusively via `seal()` factory method. Once sealed, all properties
/// are frozen and cannot be modified. The bundle's integrity can be verified
/// at any time via `verify()`.
///
/// **Invariants:**
/// - INV-B1: Content-addressable bundleHash (SHA-256 + domain separation)
/// - INV-B2: Merkle tree integrity (RFC 9162 domain separation)
/// - INV-B3: Immutability (all `let`, no public init, factory-only)
/// - INV-B4: Timing-safe verification (Double-HMAC)
/// - INV-B5: Path safety (NFC + ASCII + no hidden + no symlink escape)
/// - INV-B6: Cross-platform determinism (deterministicTimestamp, manual JSON)
/// - INV-B9: Fail-closed on unknown required capabilities
///
/// **Future Integration Points:**
/// - ProvenanceBundle: `manifest.bundleHash` → `ProvenanceBundle.contentHash`
/// - MerkleAuditLog: `manifest.merkleRoot` → audit log leaf
/// - C2PA: `exportManifest()` → C2PA assertion payload
public struct ImmutableBundle: Sendable {
    /// Bundle ID: first 32 hex chars of bundleHash (NOT 16)
    public let bundleId: String
    
    /// Frozen manifest
    public let manifest: BundleManifest
    
    /// ISO 8601 UTC timestamp when sealed
    public let sealedAt: String
    
    /// Seal protocol version
    public let sealVersion: UInt8
    
    // No public init — factory only
    
    /// Seal a bundle from the given assets.
    ///
    /// **Precondition**: No concurrent writes to files in `assetsDirectory` during seal.
    /// **Cancellation**: Checks `Task.checkCancellation()` before each file hash.
    /// **Memory**: O(256 KB) per file hash + O(n) for Merkle tree leaves.
    ///
    /// **V7 最终版 — 19 步**:
    /// 1. Validate: `assetEntries.count >= 1`, `<= MAX_ASSET_COUNT`
    /// 2. Validate `requiredCapabilities` (v1.0.0 sealing must be empty)
    /// 3. **V6**: Validate `epoch > 0` (must be positive)
    /// 4. **V6**: Validate context all fields non-empty, nonce is valid UUID format
    /// 5. **CRITICAL**: Create local MerkleTree actor (not shared, discard if cancelled)
    /// 6. **V6**: If `lodTierAssignments != nil`, create independent MerkleTree instances per LOD tier
    /// 7. For each file URL:
    ///    - **CRITICAL**: `try Task.checkCancellation()` (at loop start)
    ///    - **CRITICAL**: Validate file within boundary (prevent symlink escape): `validateFileWithinBoundary(fileURL:assetsDirectory:)`
    ///    - **CRITICAL**: Get `FileHashResult` via `HashCalculator.sha256OfFile(at:)` (hash + byteCount, single pass, eliminates TOCTOU)
    ///    - **CRITICAL**: Use `result.byteCount` as file size (**NOT** `FileManager.attributesOfItem`)
    ///    - Accumulate total size, check <= MAX_BUNDLE_TOTAL_BYTES
    ///    - Create AssetDescriptor with OCI digest format (`compression: nil`)
    /// 8. Sort descriptors by path (UTF-8 lexicographic, using `.utf8.lexicographicallyPrecedes`)
    /// 9. Check for duplicate paths (adjacent comparison after sort)
    /// 10. For each sorted descriptor, build MerkleTree:
    ///     - Extract raw hex from OCI digest: `let hexHash = try HashCalculator.hexFromOCIDigest(descriptor.digest)`
    ///     - Convert to raw 32-byte binary digest: `let rawDigest = Data(try CryptoHashFacade.hexStringToBytes(hexHash))`
    ///     - **CRITICAL**: Use `await merkleTree.append(rawDigest)` (NOT `appendHash()`, NOT manual `hashLeaf()`)
    ///     - `append()` internally applies `MerkleTreeHash.hashLeaf()`, correctly applying RFC 9162 domain separation (0x00 prefix)
    ///     - **V6**: If LOD mode, also append to corresponding tier's MerkleTree
    /// 11. Get `merkleRoot = _hexLowercase(Array(await merkleTree.rootHash))` (**Note**: rootHash is Data, needs hex conversion)
    /// 12. **V6**: If LOD mode, collect tier root hashes, sort by tier ID, build `LODMerkleStructure`
    /// 13. **V6**: Build `VerificationHints` from asset analysis (criticalPaths, totalBytes, lodTierCount)
    /// 14. **V6**: If `previousBundleHash` provided, build `BundleVersionRef`
    /// 15. **CRITICAL**: Call `try Task.checkCancellation()` again before manifest computation
    /// 16. Create ArtifactManifestRef from provided ArtifactManifest
    /// 17. Call `BundleManifest.compute(...)` (pass context, epoch, versionRef, lodStructure, verificationHints, use `deterministicTimestamp()` NOT `ISO8601DateFormatter`)
    /// 18. `bundleId = String(bundleHash.prefix(BUNDLE_ID_LENGTH))` (32 chars, **NOT** 16)
    /// 19. `sealedAt = deterministicTimestamp(Date())`
    /// 20. Return ImmutableBundle (all let, permanently frozen)
    ///
    /// - Parameters:
    ///   - assetsDirectory: Base directory containing asset files
    ///   - assetEntries: Asset entries (path, role, mediaType)
    ///   - artifactManifest: Existing ArtifactManifest this bundle packages
    ///   - buildProvenance: Build provenance information
    ///   - context: Bundle context (anti-substitution)
    ///   - epoch: Epoch counter (anti-rollback, must be > 0)
    ///   - captureSessionId: Optional capture session ID
    ///   - license: Optional SPDX license identifier
    ///   - privacyClassification: Optional privacy classification
    ///   - previousBundleHash: Optional previous bundle hash for version chain
    ///   - lodTierAssignments: Optional path → LOD tier ID mapping
    /// - Returns: Sealed ImmutableBundle
    /// - Throws: BundleError for validation failures
    public static func seal(
        assetsDirectory: URL,
        assetEntries: [AssetEntry],
        artifactManifest: ArtifactManifest,
        buildProvenance: BuildProvenance,
        context: BundleContext,
        epoch: UInt64,
        captureSessionId: String? = nil,
        license: String? = nil,
        privacyClassification: String? = nil,
        previousBundleHash: String? = nil,
        lodTierAssignments: [String: String]? = nil
    ) async throws -> ImmutableBundle {
        // Step 1: Validate asset count
        guard !assetEntries.isEmpty else {
            throw BundleError.emptyAssets
        }
        guard assetEntries.count <= BundleConstants.MAX_ASSET_COUNT else {
            throw BundleError.tooManyAssets(count: assetEntries.count, max: BundleConstants.MAX_ASSET_COUNT)
        }
        
        // Step 2: Validate requiredCapabilities (must be empty for v1.0.0)
        // This is validated in BundleManifest.compute()
        
        // Step 3: Validate epoch
        guard epoch > 0 else {
            throw BundleError.invalidManifest("Epoch must be positive, got \(epoch)")
        }
        
        // Step 4: Validate context fields
        try _validateString(context.projectId, field: "context.projectId")
        try _validateString(context.recipientId, field: "context.recipientId")
        try _validateString(context.purpose, field: "context.purpose")
        try _validateString(context.nonce, field: "context.nonce")
        // Basic UUID format check (not strict, but catches obvious errors)
        guard context.nonce.count == 36, context.nonce.contains("-") else {
            throw BundleError.invalidManifest("Context nonce must be UUID v4 format")
        }
        
        // Step 5: Create local MerkleTree actor
        let merkleTree = MerkleTree()
        
        // Step 6: Create LOD tier MerkleTrees if needed
        var lodTrees: [String: MerkleTree] = [:]
        if let lodTierAssignments = lodTierAssignments {
            for tierId in Set(lodTierAssignments.values) {
                lodTrees[tierId] = MerkleTree()
            }
        }
        
        // Step 7: Hash all files and create descriptors
        var descriptors: [AssetDescriptor] = []
        var totalBytes: Int64 = 0
        var criticalPaths: [String] = []
        
        for entry in assetEntries {
            // Check cancellation
            try Task.checkCancellation()
            
            // Construct file URL
            let fileURL = assetsDirectory.appendingPathComponent(entry.path)
            
            // Validate file within boundary (prevent symlink escape)
            try Self.validateFileWithinBoundary(fileURL: fileURL, baseDirectory: assetsDirectory)
            
            // Compute hash and size in single pass (TOCTOU prevention)
            let hashResult = try HashCalculator.sha256OfFile(at: fileURL)
            
            // Use byteCount from hash result (NOT FileManager.attributesOfItem)
            totalBytes += hashResult.byteCount
            
            // Check total size limit
            guard totalBytes <= BundleConstants.MAX_BUNDLE_TOTAL_BYTES else {
                throw BundleError.bundleTooLarge(totalBytes: totalBytes, maxBytes: BundleConstants.MAX_BUNDLE_TOTAL_BYTES)
            }
            
            // Create OCI digest
            let digest = HashCalculator.ociDigest(fromHex: hashResult.sha256Hex)
            
            // Create descriptor
            let descriptor = try AssetDescriptor(
                path: entry.path,
                digest: digest,
                size: hashResult.byteCount,
                mediaType: entry.mediaType,
                role: entry.role
            )
            descriptors.append(descriptor)
            
            // Track critical paths (for now, all paths are critical; can be refined)
            if entry.role == BundleConstants.LOD_TIER_CRITICAL || entry.role == "asset" {
                criticalPaths.append(entry.path)
            }
        }
        
        // Step 8: Sort descriptors by path
        descriptors.sort { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
        
        // Step 9: Check for duplicate paths
        if descriptors.count >= 2 {
            for i in 0..<descriptors.count - 1 {
                if descriptors[i].path == descriptors[i + 1].path {
                    throw BundleError.duplicatePath(path: descriptors[i].path)
                }
            }
        }
        
        // Step 10: Build Merkle tree
        for descriptor in descriptors {
            // Extract hex from OCI digest
            let hexHash = try HashCalculator.hexFromOCIDigest(descriptor.digest)
            
            // Convert to raw 32-byte binary digest
            let rawDigest = Data(try CryptoHashFacade.hexStringToBytes(hexHash))
            
            // Append to main MerkleTree (append() internally calls hashLeaf())
            await merkleTree.append(rawDigest)
            
            // If LOD mode, also append to tier tree
            if let lodTierAssignments = lodTierAssignments,
               let tierId = lodTierAssignments[descriptor.path],
               let tierTree = lodTrees[tierId] {
                await tierTree.append(rawDigest)
            }
        }
        
        // Step 11: Get merkle root
        let merkleRootData = await merkleTree.rootHash
        let merkleRoot = _hexLowercase(Array(merkleRootData))
        
        // Step 12: Build LOD structure if needed
        var lodStructure: LODMerkleStructure? = nil
        if !lodTrees.isEmpty {
            var subtreeRoots: [String: String] = [:]
            for (tierId, tree) in lodTrees {
                let rootData = await tree.rootHash
                subtreeRoots[tierId] = _hexLowercase(Array(rootData))
            }
            
            // Sort tier IDs and hash their roots
            let sortedTierIds = subtreeRoots.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            var combinedRoots = Data()
            for tierId in sortedTierIds {
                let rootHex = subtreeRoots[tierId]!
                combinedRoots.append(Data(try CryptoHashFacade.hexStringToBytes(rootHex)))
            }
            let bundleRootData = _SHA256.hash(data: combinedRoots)
            let bundleRoot = _hexLowercase(Array(bundleRootData))
            
            lodStructure = LODMerkleStructure(subtreeRoots: subtreeRoots, bundleRoot: bundleRoot)
        }
        
        // Step 13: Build verification hints
        let verificationHints = VerificationHints(
            criticalPaths: criticalPaths,
            totalBytes: totalBytes,
            lodTierCount: lodTrees.count
        )
        
        // Step 14: Build version ref if needed
        var versionRef: BundleVersionRef? = nil
        if let previousHash = previousBundleHash {
            versionRef = BundleVersionRef(
                previousBundleHash: previousHash,
                versionSequence: epoch, // Use epoch as sequence number
                auditLogTreeSize: 0 // TODO: Get from audit log if available
            )
        }
        
        // Step 15: Check cancellation before manifest computation
        try Task.checkCancellation()
        
        // Step 16: Create ArtifactManifestRef
        let artifactManifestRef = ArtifactManifestRef(
            artifactId: artifactManifest.artifactId,
            schemaVersion: artifactManifest.schemaVersion,
            rootHash: artifactManifest.artifactHash // Use artifactHash as rootHash
        )
        
        // Step 17: Compute manifest
        let manifest = try BundleManifest.compute(
            artifactManifest: artifactManifestRef,
            assets: descriptors,
            merkleRoot: merkleRoot,
            deviceInfo: BundleDeviceInfo.current(),
            buildProvenance: buildProvenance,
            context: context,
            epoch: epoch,
            captureSessionId: captureSessionId,
            policyHash: getCurrentPolicyHash(),
            license: license,
            privacyClassification: privacyClassification,
            versionRef: versionRef,
            lodStructure: lodStructure,
            verificationHints: verificationHints
        )
        
        // Step 18: Compute bundleId
        let bundleId = String(manifest.bundleHash.prefix(BundleConstants.BUNDLE_ID_LENGTH))
        
        // Step 19: Get sealed timestamp
        let sealedAt = Self.deterministicTimestamp()
        
        // Step 20: Return bundle
        return ImmutableBundle(
            bundleId: bundleId,
            manifest: manifest,
            sealedAt: sealedAt,
            sealVersion: BundleConstants.SEAL_VERSION
        )
    }
    
    /// Verify bundle integrity against the assets directory.
    ///
    /// Recomputes all hashes from scratch and compares timing-safely.
    /// **Does NOT use** `InclusionProof.verify()` (non-timing-safe `==`).
    ///
    /// **V6**: Supports four verification modes (progressive, probabilistic, incremental, full).
    ///
    /// - Parameters:
    ///   - assetsDirectory: Base directory containing asset files
    ///   - mode: Verification mode (default: .full)
    /// - Returns: true if verification passes
    /// - Throws: BundleError for verification failures
    public func verify(assetsDirectory: URL, mode: VerificationMode = .full) async throws -> Bool {
        switch mode {
        case .full:
            return try await verifyFull(assetsDirectory: assetsDirectory)
        case .progressive:
            return try await verifyProgressive(assetsDirectory: assetsDirectory)
        case .probabilistic(let delta):
            return try await verifyProbabilistic(assetsDirectory: assetsDirectory, delta: delta)
        case .incremental(let previousReceipt):
            return try await verifyIncremental(assetsDirectory: assetsDirectory, previousReceipt: previousReceipt)
        }
    }
    
    // MARK: - Private Verification Implementations
    
    private func verifyFull(assetsDirectory: URL) async throws -> Bool {
        // Verify all assets
        for asset in manifest.assets {
            let fileURL = assetsDirectory.appendingPathComponent(asset.path)
            
            // Validate file within boundary
            try ImmutableBundle.validateFileWithinBoundary(fileURL: fileURL, baseDirectory: assetsDirectory)
            
            // Compute hash
            let hashResult = try HashCalculator.sha256OfFile(at: fileURL)
            
            // Timing-safe comparison
            guard HashCalculator.timingSafeEqualHex(hashResult.sha256Hex, try HashCalculator.hexFromOCIDigest(asset.digest)) else {
                throw BundleError.assetHashMismatch(path: asset.path)
            }
            
            // Verify size
            guard hashResult.byteCount == asset.size else {
                throw BundleError.assetSizeMismatch(path: asset.path, expected: asset.size, actual: hashResult.byteCount)
            }
        }
        
        // Rebuild Merkle tree
        let verifyTree = MerkleTree()
        for asset in manifest.assets {
            let hexHash = try HashCalculator.hexFromOCIDigest(asset.digest)
            let rawDigest = Data(try CryptoHashFacade.hexStringToBytes(hexHash))
            await verifyTree.append(rawDigest)
        }
        
        let computedRootData = await verifyTree.rootHash
        let computedRoot = _hexLowercase(Array(computedRootData))
        
        // Timing-safe Merkle root comparison
        let expectedRootData = Data(try CryptoHashFacade.hexStringToBytes(manifest.merkleRoot))
        guard HashCalculator.timingSafeEqual(computedRootData, expectedRootData) else {
            throw BundleError.merkleRootMismatch(expected: manifest.merkleRoot, actual: computedRoot)
        }
        
        // Verify bundleHash
        guard manifest.verifyHash() else {
            throw BundleError.bundleHashMismatch(expected: manifest.bundleHash, actual: "recomputed")
        }
        
        return true
    }
    
    private func verifyProgressive(assetsDirectory: URL) async throws -> Bool {
        // First verify critical paths
        for path in manifest.verificationHints.criticalPaths {
            guard let asset = manifest.assets.first(where: { $0.path == path }) else {
                continue
            }
            let fileURL = assetsDirectory.appendingPathComponent(asset.path)
            try ImmutableBundle.validateFileWithinBoundary(fileURL: fileURL, baseDirectory: assetsDirectory)
            let hashResult = try HashCalculator.sha256OfFile(at: fileURL)
            guard HashCalculator.timingSafeEqualHex(hashResult.sha256Hex, try HashCalculator.hexFromOCIDigest(asset.digest)) else {
                throw BundleError.assetHashMismatch(path: asset.path)
            }
        }
        
        // Then verify remaining assets
        let criticalSet = Set(manifest.verificationHints.criticalPaths)
        for asset in manifest.assets where !criticalSet.contains(asset.path) {
            let fileURL = assetsDirectory.appendingPathComponent(asset.path)
            try ImmutableBundle.validateFileWithinBoundary(fileURL: fileURL, baseDirectory: assetsDirectory)
            let hashResult = try HashCalculator.sha256OfFile(at: fileURL)
            guard HashCalculator.timingSafeEqualHex(hashResult.sha256Hex, try HashCalculator.hexFromOCIDigest(asset.digest)) else {
                throw BundleError.assetHashMismatch(path: asset.path)
            }
        }
        
        // Rebuild Merkle tree and verify root
        return try await verifyFull(assetsDirectory: assetsDirectory)
    }
    
    private func verifyProbabilistic(assetsDirectory: URL, delta: Double) async throws -> Bool {
        // Always verify critical paths
        for path in manifest.verificationHints.criticalPaths {
            guard let asset = manifest.assets.first(where: { $0.path == path }) else {
                continue
            }
            let fileURL = assetsDirectory.appendingPathComponent(asset.path)
            try ImmutableBundle.validateFileWithinBoundary(fileURL: fileURL, baseDirectory: assetsDirectory)
            let hashResult = try HashCalculator.sha256OfFile(at: fileURL)
            guard HashCalculator.timingSafeEqualHex(hashResult.sha256Hex, try HashCalculator.hexFromOCIDigest(asset.digest)) else {
                throw BundleError.assetHashMismatch(path: asset.path)
            }
        }
        
        // Sample remaining assets
        let criticalSet = Set(manifest.verificationHints.criticalPaths)
        let nonCriticalAssets = manifest.assets.filter { !criticalSet.contains($0.path) }
        let sampleSize = computeSampleSize(totalAssets: nonCriticalAssets.count, delta: delta)
        
        // Shuffle and sample (simplified - in production use proper random sampling)
        let sampledAssets = Array(nonCriticalAssets.prefix(sampleSize))
        
        for asset in sampledAssets {
            let fileURL = assetsDirectory.appendingPathComponent(asset.path)
            try ImmutableBundle.validateFileWithinBoundary(fileURL: fileURL, baseDirectory: assetsDirectory)
            let hashResult = try HashCalculator.sha256OfFile(at: fileURL)
            guard HashCalculator.timingSafeEqualHex(hashResult.sha256Hex, try HashCalculator.hexFromOCIDigest(asset.digest)) else {
                throw BundleError.assetHashMismatch(path: asset.path)
            }
        }
        
        // Verify Merkle root (full tree)
        let verifyTree = MerkleTree()
        for asset in manifest.assets {
            let hexHash = try HashCalculator.hexFromOCIDigest(asset.digest)
            let rawDigest = Data(try CryptoHashFacade.hexStringToBytes(hexHash))
            await verifyTree.append(rawDigest)
        }
        
        let computedRootData = await verifyTree.rootHash
        let expectedRootData = Data(try CryptoHashFacade.hexStringToBytes(manifest.merkleRoot))
        guard HashCalculator.timingSafeEqual(computedRootData, expectedRootData) else {
            throw BundleError.merkleRootMismatch(expected: manifest.merkleRoot, actual: _hexLowercase(Array(computedRootData)))
        }
        
        // Verify bundleHash
        guard manifest.verifyHash() else {
            throw BundleError.bundleHashMismatch(expected: manifest.bundleHash, actual: "recomputed")
        }
        
        return true
    }
    
    private func verifyIncremental(assetsDirectory: URL, previousReceipt: VerificationReceipt) async throws -> Bool {
        // Verify bundle hash matches previous receipt
        guard HashCalculator.timingSafeEqualHex(manifest.bundleHash, previousReceipt.bundleHash) else {
            // Bundle changed - need full verification
            return try await verifyFull(assetsDirectory: assetsDirectory)
        }
        
        // Bundle unchanged - verify Merkle root matches
        let expectedRootData = Data(try CryptoHashFacade.hexStringToBytes(manifest.merkleRoot))
        let receiptRootData = Data(try CryptoHashFacade.hexStringToBytes(previousReceipt.merkleRoot))
        guard HashCalculator.timingSafeEqual(expectedRootData, receiptRootData) else {
            throw BundleError.merkleRootMismatch(expected: manifest.merkleRoot, actual: previousReceipt.merkleRoot)
        }
        
        return true
    }
    
    /// Export the manifest as canonical JSON bytes.
    ///
    /// - Returns: Canonical JSON bytes (for storage/transmission)
    public func exportManifest() -> Data {
        do {
            return try manifest.canonicalBytesForStorage()
        } catch {
            // Should never happen for a valid manifest, but return empty data if it does
            return Data()
        }
    }
    
    // MARK: - Private Helpers
    
    /// Validate file is within base directory boundary (prevent symlink escape).
    ///
    /// **CRITICAL**: Prevents path traversal attacks via symlinks.
    ///
    /// - Parameters:
    ///   - fileURL: File URL to validate
    ///   - baseDirectory: Base directory
    /// - Throws: BundleError.symlinkEscape if file is outside boundary
    private static func validateFileWithinBoundary(fileURL: URL, baseDirectory: URL) throws {
        let resolvedPath = try fileURL.resolvingSymlinksInPath()
        let basePath = try baseDirectory.resolvingSymlinksInPath()
        
        guard resolvedPath.path.hasPrefix(basePath.path) else {
            throw BundleError.symlinkEscape(path: fileURL.path)
        }
    }
    
    /// Deterministic ISO 8601 UTC timestamp string.
    ///
    /// Uses explicit DateFormatter (NOT ISO8601DateFormatter) for cross-platform determinism.
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
}
