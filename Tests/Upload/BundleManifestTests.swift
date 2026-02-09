//
//  BundleManifestTests.swift
//  Aether3D
//
//  PR#8: Immutable Bundle Format - Bundle Manifest Tests
//

import XCTest
@testable import Aether3DCore

final class BundleManifestTests: XCTestCase {
    
    // MARK: - Test Helpers
    
    func makeTestArtifactManifest() throws -> ArtifactManifest {
        let coordinateSystem = try CoordinateSystem(upAxis: "Y", unitScale: 1.0)
        // ArtifactManifest requires at least one file and one LOD
        let testFile = try FileDescriptor(
            path: "dummy.txt",
            sha256: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            bytes: 1,
            contentType: "application/octet-stream",
            role: "asset"
        )
        let testLOD = try LODDescriptor(
            lodId: "lod0",
            qualityTier: "medium",
            approxSplatCount: 1000,
            entryFile: "dummy.txt"
        )
        return try ArtifactManifest(
            buildMeta: [:],
            coordinateSystem: coordinateSystem,
            lods: [testLOD],
            files: [testFile],
            fallbacks: nil,
            policyHash: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
    }
    
    func makeTestAssetDescriptor(path: String, content: String = "test content") throws -> AssetDescriptor {
        let data = content.data(using: .utf8)!
        let hash = HashCalculator.sha256(of: data)
        let digest = HashCalculator.ociDigest(fromHex: hash)
        return try AssetDescriptor(
            path: path,
            digest: digest,
            size: Int64(data.count),
            mediaType: "application/octet-stream",
            role: "asset"
        )
    }
    
    func makeTestBuildProvenance() -> BuildProvenance {
        return BuildProvenance(
            builderId: "test-builder/1.0.0",
            buildType: "https://aether3d.dev/bundle/v1",
            metadata: [:]
        )
    }
    
    func makeTestBundleContext() -> BundleContext {
        return BundleContext(
            projectId: "test-project",
            recipientId: "test-recipient",
            purpose: "capture",
            nonce: UUID().uuidString
        )
    }
    
    func makeTestVerificationHints() -> VerificationHints {
        return VerificationHints(
            criticalPaths: [],
            totalBytes: 100,
            lodTierCount: 0
        )
    }
    
    func computeMerkleRoot(for assets: [AssetDescriptor]) async throws -> String {
        let merkleTree = MerkleTree()
        for asset in assets {
            let hexHash = try HashCalculator.hexFromOCIDigest(asset.digest)
            let rawDigest = Data(try CryptoHashFacade.hexStringToBytes(hexHash))
            await merkleTree.append(rawDigest)
        }
        let merkleRootData = await merkleTree.rootHash
        return _hexLowercase(Array(merkleRootData))
    }
    
    // MARK: - ArtifactManifestRef Tests
    
    func testArtifactManifestRefCreation() {
        let ref = ArtifactManifestRef(
            artifactId: "test-artifact-id",
            schemaVersion: 1,
            rootHash: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        
        XCTAssertEqual(ref.artifactId, "test-artifact-id")
        XCTAssertEqual(ref.schemaVersion, 1)
        XCTAssertEqual(ref.rootHash.count, 64)
    }
    
    // MARK: - AssetDescriptor Tests
    
    func testAssetDescriptorCreation() throws {
        let descriptor = try makeTestAssetDescriptor(path: "test.txt")
        
        XCTAssertEqual(descriptor.path, "test.txt")
        XCTAssertTrue(descriptor.digest.hasPrefix("sha256:"))
        XCTAssertEqual(descriptor.size, 12) // "test content".count
        XCTAssertEqual(descriptor.mediaType, "application/octet-stream")
        XCTAssertEqual(descriptor.role, "asset")
    }
    
    func testAssetDescriptorRejectsZeroByteFile() {
        let data = Data()
        let hash = HashCalculator.sha256(of: data)
        let digest = HashCalculator.ociDigest(fromHex: hash)
        
        XCTAssertThrowsError(try AssetDescriptor(
            path: "empty.txt",
            digest: digest,
            size: 0,
            mediaType: "application/octet-stream",
            role: "asset"
        )) { error in
            XCTAssertTrue(error is BundleError,
                         "Should throw BundleError for zero-byte file")
        }
    }
    
    func testAssetDescriptorRejectsInvalidMediaType() {
        let data = "test".data(using: .utf8)!
        let hash = HashCalculator.sha256(of: data)
        let digest = HashCalculator.ociDigest(fromHex: hash)
        
        XCTAssertThrowsError(try AssetDescriptor(
            path: "test.txt",
            digest: digest,
            size: Int64(data.count),
            mediaType: "invalid/type",
            role: "asset"
        )) { error in
            XCTAssertTrue(error is BundleError,
                         "Should throw BundleError for invalid mediaType")
        }
    }
    
    func testAssetDescriptorRejectsInvalidRole() {
        let data = "test".data(using: .utf8)!
        let hash = HashCalculator.sha256(of: data)
        let digest = HashCalculator.ociDigest(fromHex: hash)
        
        XCTAssertThrowsError(try AssetDescriptor(
            path: "test.txt",
            digest: digest,
            size: Int64(data.count),
            mediaType: "application/octet-stream",
            role: "invalid-role"
        )) { error in
            XCTAssertTrue(error is BundleError,
                         "Should throw BundleError for invalid role")
        }
    }
    
    func testAssetDescriptorRejectsHiddenPath() {
        let data = "test".data(using: .utf8)!
        let hash = HashCalculator.sha256(of: data)
        let digest = HashCalculator.ociDigest(fromHex: hash)
        
        XCTAssertThrowsError(try AssetDescriptor(
            path: ".hidden/file.txt",
            digest: digest,
            size: Int64(data.count),
            mediaType: "application/octet-stream",
            role: "asset"
        )) { error in
            XCTAssertTrue(error is BundleError,
                         "Should throw BundleError for hidden path component")
        }
    }
    
    func testAssetDescriptorValidatesSizeLimit() {
        let data = "test".data(using: .utf8)!
        let hash = HashCalculator.sha256(of: data)
        let digest = HashCalculator.ociDigest(fromHex: hash)
        
        // Size exceeds JSON_SAFE_INTEGER_MAX
        let oversized = BundleConstants.JSON_SAFE_INTEGER_MAX + 1
        
        XCTAssertThrowsError(try AssetDescriptor(
            path: "test.txt",
            digest: digest,
            size: oversized,
            mediaType: "application/octet-stream",
            role: "asset"
        )) { error in
            XCTAssertTrue(error is BundleError,
                         "Should throw BundleError for size exceeding JSON_SAFE_INTEGER_MAX")
        }
    }
    
    // MARK: - BuildProvenance Tests
    
    func testBuildProvenanceCreation() {
        let provenance = makeTestBuildProvenance()
        
        XCTAssertEqual(provenance.builderId, "test-builder/1.0.0")
        XCTAssertEqual(provenance.buildType, "https://aether3d.dev/bundle/v1")
        XCTAssertTrue(provenance.metadata.isEmpty)
    }
    
    func testBuildProvenanceMetadataLimits() throws {
        // Test metadata key count limit
        var metadata: [String: String] = [:]
        for i in 0..<BundleConstants.BUILD_META_MAX_KEYS {
            metadata["key\(i)"] = "value\(i)"
        }
        
        let provenance = BuildProvenance(
            builderId: "test",
            buildType: "test",
            metadata: metadata
        )
        
        let artifactManifest = try makeTestArtifactManifest()
        let artifactRef = ArtifactManifestRef(
            artifactId: artifactManifest.artifactId,
            schemaVersion: artifactManifest.schemaVersion,
            rootHash: artifactManifest.artifactHash
        )
        
        let assets = [try makeTestAssetDescriptor(path: "test.txt")]
        let merkleRoot = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        
        // Should succeed with max keys
        let _ = try BundleManifest.compute(
            artifactManifest: artifactRef,
            assets: assets,
            merkleRoot: merkleRoot,
            deviceInfo: BundleDeviceInfo.current(),
            buildProvenance: provenance,
            context: makeTestBundleContext(),
            epoch: 1,
            policyHash: getCurrentPolicyHash(),
            verificationHints: makeTestVerificationHints()
        )
        
        // Should fail with too many keys
        metadata["excess"] = "value"
        let excessProvenance = BuildProvenance(
            builderId: "test",
            buildType: "test",
            metadata: metadata
        )
        
        XCTAssertThrowsError(try BundleManifest.compute(
            artifactManifest: artifactRef,
            assets: assets,
            merkleRoot: merkleRoot,
            deviceInfo: BundleDeviceInfo.current(),
            buildProvenance: excessProvenance,
            context: makeTestBundleContext(),
            epoch: 1,
            policyHash: getCurrentPolicyHash(),
            verificationHints: makeTestVerificationHints()
        )) { error in
            XCTAssertTrue(error is BundleError,
                         "Should throw BundleError for metadata exceeding MAX_KEYS")
        }
    }
    
    // MARK: - BundleManifest.compute() Tests
    
    func testBundleManifestCompute() async throws {
        let artifactManifest = try makeTestArtifactManifest()
        let artifactRef = ArtifactManifestRef(
            artifactId: artifactManifest.artifactId,
            schemaVersion: artifactManifest.schemaVersion,
            rootHash: artifactManifest.artifactHash
        )
        
        let assets = [try makeTestAssetDescriptor(path: "test.txt")]
        
        // Create MerkleTree for merkleRoot
        let merkleRoot = try await computeMerkleRoot(for: assets)
        
        let manifest = try BundleManifest.compute(
            artifactManifest: artifactRef,
            assets: assets,
            merkleRoot: merkleRoot,
            deviceInfo: BundleDeviceInfo.current(),
            buildProvenance: makeTestBuildProvenance(),
            context: makeTestBundleContext(),
            epoch: 1,
            policyHash: getCurrentPolicyHash(),
            verificationHints: makeTestVerificationHints()
        )
        
        XCTAssertEqual(manifest.schemaVersion, BundleConstants.SCHEMA_VERSION)
        XCTAssertEqual(manifest.bundleType, BundleConstants.BUNDLE_MANIFEST_MEDIA_TYPE)
        XCTAssertEqual(manifest.assets.count, 1)
        XCTAssertEqual(manifest.bundleHash.count, 64)
        XCTAssertEqual(manifest.merkleRoot.count, 64)
    }
    
    func testBundleManifestComputeDeterministic() async throws {
        let artifactManifest = try makeTestArtifactManifest()
        let artifactRef = ArtifactManifestRef(
            artifactId: artifactManifest.artifactId,
            schemaVersion: artifactManifest.schemaVersion,
            rootHash: artifactManifest.artifactHash
        )
        
        let assets = [try makeTestAssetDescriptor(path: "test.txt")]
        
        let merkleRoot = try await computeMerkleRoot(for: assets)
        
        let context = makeTestBundleContext()
        
        let manifest1 = try BundleManifest.compute(
            artifactManifest: artifactRef,
            assets: assets,
            merkleRoot: merkleRoot,
            deviceInfo: BundleDeviceInfo.current(),
            buildProvenance: makeTestBuildProvenance(),
            context: context,
            epoch: 1,
            policyHash: getCurrentPolicyHash(),
            verificationHints: makeTestVerificationHints()
        )
        
        let manifest2 = try BundleManifest.compute(
            artifactManifest: artifactRef,
            assets: assets,
            merkleRoot: merkleRoot,
            deviceInfo: BundleDeviceInfo.current(),
            buildProvenance: makeTestBuildProvenance(),
            context: context,
            epoch: 1,
            policyHash: getCurrentPolicyHash(),
            verificationHints: makeTestVerificationHints()
        )
        
        // Same inputs should produce same bundleHash
        XCTAssertEqual(manifest1.bundleHash, manifest2.bundleHash,
                       "Same inputs must produce same bundleHash (deterministic)")
    }
    
    func testBundleManifestComputeDifferentContextProducesDifferentHash() async throws {
        let artifactManifest = try makeTestArtifactManifest()
        let artifactRef = ArtifactManifestRef(
            artifactId: artifactManifest.artifactId,
            schemaVersion: artifactManifest.schemaVersion,
            rootHash: artifactManifest.artifactHash
        )
        
        let assets = [try makeTestAssetDescriptor(path: "test.txt")]
        
        let merkleRoot = try await computeMerkleRoot(for: assets)
        
        let context1 = BundleContext(
            projectId: "project1",
            recipientId: "recipient1",
            purpose: "capture",
            nonce: UUID().uuidString
        )
        
        let context2 = BundleContext(
            projectId: "project2",
            recipientId: "recipient2",
            purpose: "capture",
            nonce: UUID().uuidString
        )
        
        let manifest1 = try BundleManifest.compute(
            artifactManifest: artifactRef,
            assets: assets,
            merkleRoot: merkleRoot,
            deviceInfo: BundleDeviceInfo.current(),
            buildProvenance: makeTestBuildProvenance(),
            context: context1,
            epoch: 1,
            policyHash: getCurrentPolicyHash(),
            verificationHints: makeTestVerificationHints()
        )
        
        let manifest2 = try BundleManifest.compute(
            artifactManifest: artifactRef,
            assets: assets,
            merkleRoot: merkleRoot,
            deviceInfo: BundleDeviceInfo.current(),
            buildProvenance: makeTestBuildProvenance(),
            context: context2,
            epoch: 1,
            policyHash: getCurrentPolicyHash(),
            verificationHints: makeTestVerificationHints()
        )
        
        // Different contexts must produce different bundleHash
        XCTAssertNotEqual(manifest1.bundleHash, manifest2.bundleHash,
                          "Different contexts must produce different bundleHash (anti-substitution)")
    }
    
    func testBundleManifestComputeDifferentEpochProducesDifferentHash() async throws {
        let artifactManifest = try makeTestArtifactManifest()
        let artifactRef = ArtifactManifestRef(
            artifactId: artifactManifest.artifactId,
            schemaVersion: artifactManifest.schemaVersion,
            rootHash: artifactManifest.artifactHash
        )
        
        let assets = [try makeTestAssetDescriptor(path: "test.txt")]
        
        let merkleRoot = try await computeMerkleRoot(for: assets)
        
        let context = makeTestBundleContext()
        
        let manifest1 = try BundleManifest.compute(
            artifactManifest: artifactRef,
            assets: assets,
            merkleRoot: merkleRoot,
            deviceInfo: BundleDeviceInfo.current(),
            buildProvenance: makeTestBuildProvenance(),
            context: context,
            epoch: 1,
            policyHash: getCurrentPolicyHash(),
            verificationHints: makeTestVerificationHints()
        )
        
        let manifest2 = try BundleManifest.compute(
            artifactManifest: artifactRef,
            assets: assets,
            merkleRoot: merkleRoot,
            deviceInfo: BundleDeviceInfo.current(),
            buildProvenance: makeTestBuildProvenance(),
            context: context,
            epoch: 2,
            policyHash: getCurrentPolicyHash(),
            verificationHints: makeTestVerificationHints()
        )
        
        // Different epochs must produce different bundleHash
        XCTAssertNotEqual(manifest1.bundleHash, manifest2.bundleHash,
                          "Different epochs must produce different bundleHash (anti-rollback)")
    }
    
    func testBundleManifestComputeRejectsInvalidSchemaVersion() async throws {
        let artifactManifest = try makeTestArtifactManifest()
        let artifactRef = ArtifactManifestRef(
            artifactId: artifactManifest.artifactId,
            schemaVersion: artifactManifest.schemaVersion,
            rootHash: artifactManifest.artifactHash
        )
        
        let assets = [try makeTestAssetDescriptor(path: "test.txt")]
        
        let merkleRoot = try await computeMerkleRoot(for: assets)
        
        XCTAssertThrowsError(try BundleManifest.compute(
            schemaVersion: "2.0.0", // Invalid - only 1.x.x supported
            artifactManifest: artifactRef,
            assets: assets,
            merkleRoot: merkleRoot,
            deviceInfo: BundleDeviceInfo.current(),
            buildProvenance: makeTestBuildProvenance(),
            context: makeTestBundleContext(),
            epoch: 1,
            policyHash: getCurrentPolicyHash(),
            verificationHints: makeTestVerificationHints()
        )) { error in
            XCTAssertTrue(error is BundleError,
                         "Should throw BundleError for unsupported schema version")
        }
    }
    
    func testBundleManifestComputeRejectsZeroEpoch() async throws {
        let artifactManifest = try makeTestArtifactManifest()
        let artifactRef = ArtifactManifestRef(
            artifactId: artifactManifest.artifactId,
            schemaVersion: artifactManifest.schemaVersion,
            rootHash: artifactManifest.artifactHash
        )
        
        let assets = [try makeTestAssetDescriptor(path: "test.txt")]
        
        let merkleRoot = try await computeMerkleRoot(for: assets)
        
        XCTAssertThrowsError(try BundleManifest.compute(
            artifactManifest: artifactRef,
            assets: assets,
            merkleRoot: merkleRoot,
            deviceInfo: BundleDeviceInfo.current(),
            buildProvenance: makeTestBuildProvenance(),
            context: makeTestBundleContext(),
            epoch: 0, // Invalid - must be > 0
            policyHash: getCurrentPolicyHash(),
            verificationHints: makeTestVerificationHints()
        )) { error in
            XCTAssertTrue(error is BundleError,
                         "Should throw BundleError for zero epoch")
        }
    }
    
    // MARK: - Canonical JSON Tests
    
    func testCanonicalBytesForHashingExcludesBundleHash() async throws {
        let artifactManifest = try makeTestArtifactManifest()
        let artifactRef = ArtifactManifestRef(
            artifactId: artifactManifest.artifactId,
            schemaVersion: artifactManifest.schemaVersion,
            rootHash: artifactManifest.artifactHash
        )
        
        let assets = [try makeTestAssetDescriptor(path: "test.txt")]
        
        let merkleRoot = try await computeMerkleRoot(for: assets)
        
        let manifest = try BundleManifest.compute(
            artifactManifest: artifactRef,
            assets: assets,
            merkleRoot: merkleRoot,
            deviceInfo: BundleDeviceInfo.current(),
            buildProvenance: makeTestBuildProvenance(),
            context: makeTestBundleContext(),
            epoch: 1,
            policyHash: getCurrentPolicyHash(),
            verificationHints: makeTestVerificationHints()
        )
        
        let forHashing = try manifest.canonicalBytesForHashing()
        let forStorage = try manifest.canonicalBytesForStorage()
        
        // Storage must be longer (includes bundleHash)
        XCTAssertGreaterThan(forStorage.count, forHashing.count,
                             "Storage bytes must include bundleHash")
        
        // Hashing bytes must not contain bundleHash key
        let forHashingString = String(data: forHashing, encoding: .utf8)!
        XCTAssertFalse(forHashingString.contains("\"bundleHash\""),
                       "Hashing bytes must exclude bundleHash field")
    }
    
    func testCanonicalBytesDeterministic() async throws {
        let artifactManifest = try makeTestArtifactManifest()
        let artifactRef = ArtifactManifestRef(
            artifactId: artifactManifest.artifactId,
            schemaVersion: artifactManifest.schemaVersion,
            rootHash: artifactManifest.artifactHash
        )
        
        let assets = [try makeTestAssetDescriptor(path: "test.txt")]
        
        let merkleRoot = try await computeMerkleRoot(for: assets)
        
        let context = makeTestBundleContext()
        
        let manifest = try BundleManifest.compute(
            artifactManifest: artifactRef,
            assets: assets,
            merkleRoot: merkleRoot,
            deviceInfo: BundleDeviceInfo.current(),
            buildProvenance: makeTestBuildProvenance(),
            context: context,
            epoch: 1,
            policyHash: getCurrentPolicyHash(),
            verificationHints: makeTestVerificationHints()
        )
        
        // Compute canonical bytes multiple times
        let bytes1 = try manifest.canonicalBytesForHashing()
        let bytes2 = try manifest.canonicalBytesForHashing()
        let bytes3 = try manifest.canonicalBytesForHashing()
        
        // Must be identical
        XCTAssertEqual(bytes1, bytes2,
                       "Canonical bytes must be deterministic (run 1 vs 2)")
        XCTAssertEqual(bytes2, bytes3,
                       "Canonical bytes must be deterministic (run 2 vs 3)")
    }
    
    // MARK: - VerifyHash Tests
    
    func testVerifyHash() async throws {
        let artifactManifest = try makeTestArtifactManifest()
        let artifactRef = ArtifactManifestRef(
            artifactId: artifactManifest.artifactId,
            schemaVersion: artifactManifest.schemaVersion,
            rootHash: artifactManifest.artifactHash
        )
        
        let assets = [try makeTestAssetDescriptor(path: "test.txt")]
        
        let merkleRoot = try await computeMerkleRoot(for: assets)
        
        let manifest = try BundleManifest.compute(
            artifactManifest: artifactRef,
            assets: assets,
            merkleRoot: merkleRoot,
            deviceInfo: BundleDeviceInfo.current(),
            buildProvenance: makeTestBuildProvenance(),
            context: makeTestBundleContext(),
            epoch: 1,
            policyHash: getCurrentPolicyHash(),
            verificationHints: makeTestVerificationHints()
        )
        
        // Verify hash should pass
        XCTAssertTrue(manifest.verifyHash(),
                      "verifyHash() must return true for valid manifest")
    }
    
    // MARK: - Asset Sorting Tests
    
    func testAssetsAreSortedByPath() async throws {
        let artifactManifest = try makeTestArtifactManifest()
        let artifactRef = ArtifactManifestRef(
            artifactId: artifactManifest.artifactId,
            schemaVersion: artifactManifest.schemaVersion,
            rootHash: artifactManifest.artifactHash
        )
        
        // Create assets in non-sorted order
        let assets = [
            try makeTestAssetDescriptor(path: "zebra.txt"),
            try makeTestAssetDescriptor(path: "alpha.txt"),
            try makeTestAssetDescriptor(path: "beta.txt")
        ]
        
        let merkleRoot = try await computeMerkleRoot(for: assets)
        
        let manifest = try BundleManifest.compute(
            artifactManifest: artifactRef,
            assets: assets,
            merkleRoot: merkleRoot,
            deviceInfo: BundleDeviceInfo.current(),
            buildProvenance: makeTestBuildProvenance(),
            context: makeTestBundleContext(),
            epoch: 1,
            policyHash: getCurrentPolicyHash(),
            verificationHints: makeTestVerificationHints()
        )
        
        // Assets must be sorted
        let paths = manifest.assets.map { $0.path }
        XCTAssertEqual(paths, ["alpha.txt", "beta.txt", "zebra.txt"],
                       "Assets must be sorted by path (UTF-8 lexicographic)")
    }
    
    func testBundleManifestRejectsDuplicatePaths() async throws {
        let artifactManifest = try makeTestArtifactManifest()
        let artifactRef = ArtifactManifestRef(
            artifactId: artifactManifest.artifactId,
            schemaVersion: artifactManifest.schemaVersion,
            rootHash: artifactManifest.artifactHash
        )
        
        // Create assets with duplicate paths
        let assets = [
            try makeTestAssetDescriptor(path: "test.txt", content: "content1"),
            try makeTestAssetDescriptor(path: "test.txt", content: "content2")
        ]
        
        let merkleRoot = try await computeMerkleRoot(for: assets)
        
        XCTAssertThrowsError(try BundleManifest.compute(
            artifactManifest: artifactRef,
            assets: assets,
            merkleRoot: merkleRoot,
            deviceInfo: BundleDeviceInfo.current(),
            buildProvenance: makeTestBuildProvenance(),
            context: makeTestBundleContext(),
            epoch: 1,
            policyHash: getCurrentPolicyHash(),
            verificationHints: makeTestVerificationHints()
        )) { error in
            guard case BundleError.duplicatePath = error else {
                XCTFail("Expected duplicatePath error")
                return
            }
        }
    }
}
