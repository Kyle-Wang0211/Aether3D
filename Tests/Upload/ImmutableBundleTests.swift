//
//  ImmutableBundleTests.swift
//  Aether3D
//
//  PR#8: Immutable Bundle Format - Immutable Bundle Tests
//

import XCTest
@testable import Aether3DCore

final class ImmutableBundleTests: XCTestCase {
    
    // MARK: - Test Helpers
    
    func createTempDirectory() -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let testDir = tempDir.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        return testDir
    }
    
    func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
    
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
    
    // MARK: - Seal Tests
    
    func testSealCreatesValidBundle() async throws {
        let tempDir = createTempDirectory()
        defer { cleanup(tempDir) }
        
        // Create test file
        let testFile = tempDir.appendingPathComponent("test.txt")
        try "Hello, World!".write(to: testFile, atomically: true, encoding: .utf8)
        
        let artifactManifest = try makeTestArtifactManifest()
        let assetEntries = [
            AssetEntry(path: "test.txt", role: "asset", mediaType: "application/octet-stream")
        ]
        
        let bundle = try await ImmutableBundle.seal(
            assetsDirectory: tempDir,
            assetEntries: assetEntries,
            artifactManifest: artifactManifest,
            buildProvenance: makeTestBuildProvenance(),
            context: makeTestBundleContext(),
            epoch: 1
        )
        
        XCTAssertEqual(bundle.bundleId.count, BundleConstants.BUNDLE_ID_LENGTH,
                       "bundleId must be \(BundleConstants.BUNDLE_ID_LENGTH) hex characters")
        XCTAssertEqual(bundle.sealVersion, BundleConstants.SEAL_VERSION,
                       "sealVersion must match BundleConstants.SEAL_VERSION")
        XCTAssertFalse(bundle.sealedAt.isEmpty,
                       "sealedAt must be non-empty timestamp")
    }
    
    func testSealBundleIdIs32HexChars() async throws {
        let tempDir = createTempDirectory()
        defer { cleanup(tempDir) }
        
        let testFile = tempDir.appendingPathComponent("test.txt")
        try "test content".write(to: testFile, atomically: true, encoding: .utf8)
        
        let artifactManifest = try makeTestArtifactManifest()
        let assetEntries = [
            AssetEntry(path: "test.txt", role: "asset", mediaType: "application/octet-stream")
        ]
        
        let bundle = try await ImmutableBundle.seal(
            assetsDirectory: tempDir,
            assetEntries: assetEntries,
            artifactManifest: artifactManifest,
            buildProvenance: makeTestBuildProvenance(),
            context: makeTestBundleContext(),
            epoch: 1
        )
        
        // bundleId is first 32 chars of bundleHash
        XCTAssertEqual(bundle.bundleId.count, 32,
                       "bundleId must be exactly 32 hex characters")
        XCTAssertEqual(bundle.bundleId, String(bundle.manifest.bundleHash.prefix(32)),
                       "bundleId must be prefix of bundleHash")
        
        // Verify all characters are hex
        let hexChars = CharacterSet(charactersIn: "0123456789abcdef")
        XCTAssertTrue(bundle.bundleId.unicodeScalars.allSatisfy { hexChars.contains($0) },
                      "bundleId must contain only lowercase hex characters")
    }
    
    func testSealDeterministic() async throws {
        let tempDir = createTempDirectory()
        defer { cleanup(tempDir) }
        
        let testFile = tempDir.appendingPathComponent("test.txt")
        try "test content".write(to: testFile, atomically: true, encoding: .utf8)
        
        let artifactManifest = try makeTestArtifactManifest()
        let assetEntries = [
            AssetEntry(path: "test.txt", role: "asset", mediaType: "application/octet-stream")
        ]
        
        let context = makeTestBundleContext()
        
        let bundle1 = try await ImmutableBundle.seal(
            assetsDirectory: tempDir,
            assetEntries: assetEntries,
            artifactManifest: artifactManifest,
            buildProvenance: makeTestBuildProvenance(),
            context: context,
            epoch: 1
        )
        
        let bundle2 = try await ImmutableBundle.seal(
            assetsDirectory: tempDir,
            assetEntries: assetEntries,
            artifactManifest: artifactManifest,
            buildProvenance: makeTestBuildProvenance(),
            context: context,
            epoch: 1
        )
        
        // Same inputs must produce same bundleHash
        XCTAssertEqual(bundle1.manifest.bundleHash, bundle2.manifest.bundleHash,
                       "Same inputs must produce same bundleHash (deterministic)")
        XCTAssertEqual(bundle1.bundleId, bundle2.bundleId,
                       "Same inputs must produce same bundleId")
    }
    
    func testSealRejectsEmptyAssets() async throws {
        let tempDir = createTempDirectory()
        defer { cleanup(tempDir) }
        
        let artifactManifest = try makeTestArtifactManifest()
        
        do {
            _ = try await ImmutableBundle.seal(
            assetsDirectory: tempDir,
            assetEntries: [],
            artifactManifest: artifactManifest,
            buildProvenance: makeTestBuildProvenance(),
            context: makeTestBundleContext(),
            epoch: 1
            )
            XCTFail("Expected emptyAssets error")
        } catch {
            guard case BundleError.emptyAssets = error else {
                XCTFail("Expected emptyAssets error, got \(error)")
                return
            }
        }
    }
    
    func testSealRejectsTooManyAssets() async throws {
        let tempDir = createTempDirectory()
        defer { cleanup(tempDir) }
        
        // Create max+1 assets
        var assetEntries: [AssetEntry] = []
        for i in 0..<(BundleConstants.MAX_ASSET_COUNT + 1) {
            let testFile = tempDir.appendingPathComponent("file\(i).txt")
            try "content\(i)".write(to: testFile, atomically: true, encoding: .utf8)
            assetEntries.append(AssetEntry(path: "file\(i).txt", role: "asset", mediaType: "application/octet-stream"))
        }
        
        let artifactManifest = try makeTestArtifactManifest()
        
        do {
            _ = try await ImmutableBundle.seal(
            assetsDirectory: tempDir,
            assetEntries: assetEntries,
            artifactManifest: artifactManifest,
            buildProvenance: makeTestBuildProvenance(),
            context: makeTestBundleContext(),
            epoch: 1
            )
            XCTFail("Expected tooManyAssets error")
        } catch {
            guard case BundleError.tooManyAssets = error else {
                XCTFail("Expected tooManyAssets error, got \(error)")
                return
            }
        }
    }
    
    func testSealRejectsOversizedBundle() async throws {
        let tempDir = createTempDirectory()
        defer { cleanup(tempDir) }
        
        // Create file larger than MAX_BUNDLE_TOTAL_BYTES
        let largeSize = BundleConstants.MAX_BUNDLE_TOTAL_BYTES + 1
        let testFile = tempDir.appendingPathComponent("large.bin")
        let largeData = Data(repeating: 0x42, count: Int(largeSize))
        try largeData.write(to: testFile)
        
        let artifactManifest = try makeTestArtifactManifest()
        let assetEntries = [
            AssetEntry(path: "large.bin", role: "asset", mediaType: "application/octet-stream")
        ]
        
        do {
            _ = try await ImmutableBundle.seal(
            assetsDirectory: tempDir,
            assetEntries: assetEntries,
            artifactManifest: artifactManifest,
            buildProvenance: makeTestBuildProvenance(),
            context: makeTestBundleContext(),
            epoch: 1
            )
            XCTFail("Expected bundleTooLarge error")
        } catch {
            guard case BundleError.bundleTooLarge = error else {
                XCTFail("Expected bundleTooLarge error, got \(error)")
                return
            }
        }
    }
    
    // MARK: - Verify Tests
    
    func testVerifyFullPassesForUntamperedBundle() async throws {
        let tempDir = createTempDirectory()
        defer { cleanup(tempDir) }
        
        let testFile = tempDir.appendingPathComponent("test.txt")
        try "test content".write(to: testFile, atomically: true, encoding: .utf8)
        
        let artifactManifest = try makeTestArtifactManifest()
        let assetEntries = [
            AssetEntry(path: "test.txt", role: "asset", mediaType: "application/octet-stream")
        ]
        
        let bundle = try await ImmutableBundle.seal(
            assetsDirectory: tempDir,
            assetEntries: assetEntries,
            artifactManifest: artifactManifest,
            buildProvenance: makeTestBuildProvenance(),
            context: makeTestBundleContext(),
            epoch: 1
        )
        
        // Verify should pass
        let isValid = try await bundle.verify(assetsDirectory: tempDir, mode: .full)
        XCTAssertTrue(isValid,
                      "verify(.full) must return true for untampered bundle")
    }
    
    func testVerifyFullFailsForTamperedFileContent() async throws {
        let tempDir = createTempDirectory()
        defer { cleanup(tempDir) }
        
        let testFile = tempDir.appendingPathComponent("test.txt")
        try "test content".write(to: testFile, atomically: true, encoding: .utf8)
        
        let artifactManifest = try makeTestArtifactManifest()
        let assetEntries = [
            AssetEntry(path: "test.txt", role: "asset", mediaType: "application/octet-stream")
        ]
        
        let bundle = try await ImmutableBundle.seal(
            assetsDirectory: tempDir,
            assetEntries: assetEntries,
            artifactManifest: artifactManifest,
            buildProvenance: makeTestBuildProvenance(),
            context: makeTestBundleContext(),
            epoch: 1
        )
        
        // Tamper with file
        try "tampered content".write(to: testFile, atomically: true, encoding: .utf8)
        
        // Verify should fail
        do {
            _ = try await bundle.verify(assetsDirectory: tempDir, mode: .full)
            XCTFail("Expected BundleError for tampered file")
        } catch {
            XCTAssertTrue(error is BundleError,
                         "Should throw BundleError for tampered file")
        }
    }
    
    func testVerifyFullFailsForMissingFile() async throws {
        let tempDir = createTempDirectory()
        defer { cleanup(tempDir) }
        
        let testFile = tempDir.appendingPathComponent("test.txt")
        try "test content".write(to: testFile, atomically: true, encoding: .utf8)
        
        let artifactManifest = try makeTestArtifactManifest()
        let assetEntries = [
            AssetEntry(path: "test.txt", role: "asset", mediaType: "application/octet-stream")
        ]
        
        let bundle = try await ImmutableBundle.seal(
            assetsDirectory: tempDir,
            assetEntries: assetEntries,
            artifactManifest: artifactManifest,
            buildProvenance: makeTestBuildProvenance(),
            context: makeTestBundleContext(),
            epoch: 1
        )
        
        // Delete file
        try FileManager.default.removeItem(at: testFile)
        
        // Verify should fail (verifyFull throws on file system errors)
        do {
            _ = try await bundle.verify(assetsDirectory: tempDir, mode: .full)
            XCTFail("Expected error for missing file")
        } catch {
            // Should throw file system error or BundleError
            XCTAssertTrue(error is BundleError || error is CocoaError || error is NSError,
                         "Should throw error for missing file, got \(error)")
        }
    }
    
    func testVerifyFullFailsForSizeMismatch() async throws {
        let tempDir = createTempDirectory()
        defer { cleanup(tempDir) }
        
        let testFile = tempDir.appendingPathComponent("test.txt")
        try "test content".write(to: testFile, atomically: true, encoding: .utf8)
        
        let artifactManifest = try makeTestArtifactManifest()
        let assetEntries = [
            AssetEntry(path: "test.txt", role: "asset", mediaType: "application/octet-stream")
        ]
        
        let bundle = try await ImmutableBundle.seal(
            assetsDirectory: tempDir,
            assetEntries: assetEntries,
            artifactManifest: artifactManifest,
            buildProvenance: makeTestBuildProvenance(),
            context: makeTestBundleContext(),
            epoch: 1
        )
        
        // Append data to file (changes size but hash would also change, so this test
        // might catch hash mismatch first, but documents the size check)
        let handle = try FileHandle(forWritingTo: testFile)
        try handle.seekToEnd()
        try handle.write(contentsOf: "extra".data(using: .utf8)!)
        try handle.close()
        
        // Verify should fail
        do {
            _ = try await bundle.verify(assetsDirectory: tempDir, mode: .full)
            XCTFail("Expected BundleError for size mismatch")
        } catch {
            XCTAssertTrue(error is BundleError,
                         "Should throw BundleError for size mismatch")
        }
    }
    
    // MARK: - Progressive Verification Tests
    
    func testVerifyProgressive() async throws {
        let tempDir = createTempDirectory()
        defer { cleanup(tempDir) }
        
        // Create multiple files
        let file1 = tempDir.appendingPathComponent("critical.txt")
        let file2 = tempDir.appendingPathComponent("normal.txt")
        try "critical content".write(to: file1, atomically: true, encoding: .utf8)
        try "normal content".write(to: file2, atomically: true, encoding: .utf8)
        
        let artifactManifest = try makeTestArtifactManifest()
        // Use "asset" role (allowedRoles doesn't include LOD tier constants as roles)
        let assetEntries = [
            AssetEntry(path: "critical.txt", role: "asset", mediaType: "application/octet-stream"),
            AssetEntry(path: "normal.txt", role: "asset", mediaType: "application/octet-stream")
        ]
        
        let bundle = try await ImmutableBundle.seal(
            assetsDirectory: tempDir,
            assetEntries: assetEntries,
            artifactManifest: artifactManifest,
            buildProvenance: makeTestBuildProvenance(),
            context: makeTestBundleContext(),
            epoch: 1
        )
        
        // Progressive verification should pass
        let isValid = try await bundle.verify(assetsDirectory: tempDir, mode: .progressive)
        XCTAssertTrue(isValid,
                      "verify(.progressive) must return true for untampered bundle")
    }
    
    // MARK: - Probabilistic Verification Tests
    
    func testVerifyProbabilistic() async throws {
        let tempDir = createTempDirectory()
        defer { cleanup(tempDir) }
        
        // Create multiple files for probabilistic sampling
        for i in 0..<10 {
            let testFile = tempDir.appendingPathComponent("file\(i).txt")
            try "content\(i)".write(to: testFile, atomically: true, encoding: .utf8)
        }
        
        let artifactManifest = try makeTestArtifactManifest()
        var assetEntries: [AssetEntry] = []
        for i in 0..<10 {
            assetEntries.append(AssetEntry(path: "file\(i).txt", role: "asset", mediaType: "application/octet-stream"))
        }
        
        let bundle = try await ImmutableBundle.seal(
            assetsDirectory: tempDir,
            assetEntries: assetEntries,
            artifactManifest: artifactManifest,
            buildProvenance: makeTestBuildProvenance(),
            context: makeTestBundleContext(),
            epoch: 1
        )
        
        // Probabilistic verification should pass
        let isValid = try await bundle.verify(assetsDirectory: tempDir, mode: .probabilistic(delta: 0.001))
        XCTAssertTrue(isValid,
                      "verify(.probabilistic) must return true for untampered bundle")
    }
    
    // MARK: - Context Binding Tests
    
    func testContextBindingPreventsSubstitution() async throws {
        let tempDir = createTempDirectory()
        defer { cleanup(tempDir) }
        
        let testFile = tempDir.appendingPathComponent("test.txt")
        try "test content".write(to: testFile, atomically: true, encoding: .utf8)
        
        let artifactManifest = try makeTestArtifactManifest()
        let assetEntries = [
            AssetEntry(path: "test.txt", role: "asset", mediaType: "application/octet-stream")
        ]
        
        let context1 = BundleContext(
            projectId: "project1",
            recipientId: "recipient1",
            purpose: "capture",
            nonce: UUID().uuidString
        )
        
        let bundle1 = try await ImmutableBundle.seal(
            assetsDirectory: tempDir,
            assetEntries: assetEntries,
            artifactManifest: artifactManifest,
            buildProvenance: makeTestBuildProvenance(),
            context: context1,
            epoch: 1
        )
        
        // Try to verify with different context (should fail at bundleHash level)
        // Note: This is tested indirectly through bundleHash mismatch
        let context2 = BundleContext(
            projectId: "project2",
            recipientId: "recipient2",
            purpose: "capture",
            nonce: UUID().uuidString
        )
        
        // Bundle was sealed with context1, so verify should pass (context is in manifest)
        // But if we try to create a new bundle with same assets but context2, hash will differ
        let bundle2 = try await ImmutableBundle.seal(
            assetsDirectory: tempDir,
            assetEntries: assetEntries,
            artifactManifest: artifactManifest,
            buildProvenance: makeTestBuildProvenance(),
            context: context2,
            epoch: 1
        )
        
        // Different contexts must produce different bundleHash
        XCTAssertNotEqual(bundle1.manifest.bundleHash, bundle2.manifest.bundleHash,
                          "Different contexts must produce different bundleHash (anti-substitution)")
    }
    
    // MARK: - Epoch Tests
    
    func testEpochMustBePositive() async throws {
        let tempDir = createTempDirectory()
        defer { cleanup(tempDir) }
        
        let testFile = tempDir.appendingPathComponent("test.txt")
        try "test content".write(to: testFile, atomically: true, encoding: .utf8)
        
        let artifactManifest = try makeTestArtifactManifest()
        let assetEntries = [
            AssetEntry(path: "test.txt", role: "asset", mediaType: "application/octet-stream")
        ]
        
        do {
            _ = try await ImmutableBundle.seal(
                assetsDirectory: tempDir,
                assetEntries: assetEntries,
                artifactManifest: artifactManifest,
                buildProvenance: makeTestBuildProvenance(),
                context: makeTestBundleContext(),
                epoch: 0 // Invalid - must be > 0
            )
            XCTFail("Expected BundleError for zero epoch")
        } catch {
            XCTAssertTrue(error is BundleError,
                         "Should throw BundleError for zero epoch, got \(error)")
        }
    }
    
    // MARK: - Single Asset Merkle Root Tests
    
    func testSingleAssetMerkleRootMatchesDirectComputation() async throws {
        let tempDir = createTempDirectory()
        defer { cleanup(tempDir) }
        
        let testFile = tempDir.appendingPathComponent("test.txt")
        let content = "test content"
        try content.write(to: testFile, atomically: true, encoding: .utf8)
        
        let artifactManifest = try makeTestArtifactManifest()
        let assetEntries = [
            AssetEntry(path: "test.txt", role: "asset", mediaType: "application/octet-stream")
        ]
        
        let bundle = try await ImmutableBundle.seal(
            assetsDirectory: tempDir,
            assetEntries: assetEntries,
            artifactManifest: artifactManifest,
            buildProvenance: makeTestBuildProvenance(),
            context: makeTestBundleContext(),
            epoch: 1
        )
        
        // Compute Merkle root directly
        let fileData = try Data(contentsOf: testFile)
        let fileHash = HashCalculator.sha256(of: fileData)
        let rawDigest = Data(try CryptoHashFacade.hexStringToBytes(fileHash))
        let directRoot = MerkleTreeHash.hashLeaf(rawDigest)
        let directRootHex = _hexLowercase(Array(directRoot))
        
        // Single asset Merkle root should match direct computation
        XCTAssertEqual(bundle.manifest.merkleRoot, directRootHex,
                       "Single asset Merkle root must match direct hashLeaf computation")
    }
    
    // MARK: - Dual Asset Merkle Root Tests
    
    func testDualAssetMerkleRootMatchesManualComputation() async throws {
        let tempDir = createTempDirectory()
        defer { cleanup(tempDir) }
        
        let file1 = tempDir.appendingPathComponent("file1.txt")
        let file2 = tempDir.appendingPathComponent("file2.txt")
        try "content1".write(to: file1, atomically: true, encoding: .utf8)
        try "content2".write(to: file2, atomically: true, encoding: .utf8)
        
        let artifactManifest = try makeTestArtifactManifest()
        let assetEntries = [
            AssetEntry(path: "file1.txt", role: "asset", mediaType: "application/octet-stream"),
            AssetEntry(path: "file2.txt", role: "asset", mediaType: "application/octet-stream")
        ]
        
        let bundle = try await ImmutableBundle.seal(
            assetsDirectory: tempDir,
            assetEntries: assetEntries,
            artifactManifest: artifactManifest,
            buildProvenance: makeTestBuildProvenance(),
            context: makeTestBundleContext(),
            epoch: 1
        )
        
        // Compute Merkle root manually
        let data1 = try Data(contentsOf: file1)
        let hash1 = HashCalculator.sha256(of: data1)
        let raw1 = Data(try CryptoHashFacade.hexStringToBytes(hash1))
        let leaf1 = MerkleTreeHash.hashLeaf(raw1)
        
        let data2 = try Data(contentsOf: file2)
        let hash2 = HashCalculator.sha256(of: data2)
        let raw2 = Data(try CryptoHashFacade.hexStringToBytes(hash2))
        let leaf2 = MerkleTreeHash.hashLeaf(raw2)
        
        let manualRoot = MerkleTreeHash.hashNodes(leaf1, leaf2)
        let manualRootHex = _hexLowercase(Array(manualRoot))
        
        // Dual asset Merkle root should match manual computation
        XCTAssertEqual(bundle.manifest.merkleRoot, manualRootHex,
                       "Dual asset Merkle root must match manual hashNodes computation")
    }
    
    // MARK: - Export Manifest Tests
    
    func testExportManifestProducesValidJSON() async throws {
        let tempDir = createTempDirectory()
        defer { cleanup(tempDir) }
        
        let testFile = tempDir.appendingPathComponent("test.txt")
        try "test content".write(to: testFile, atomically: true, encoding: .utf8)
        
        let artifactManifest = try makeTestArtifactManifest()
        let assetEntries = [
            AssetEntry(path: "test.txt", role: "asset", mediaType: "application/octet-stream")
        ]
        
        let bundle = try await ImmutableBundle.seal(
            assetsDirectory: tempDir,
            assetEntries: assetEntries,
            artifactManifest: artifactManifest,
            buildProvenance: makeTestBuildProvenance(),
            context: makeTestBundleContext(),
            epoch: 1
        )
        
        let manifestData = bundle.exportManifest()
        XCTAssertFalse(manifestData.isEmpty,
                       "exportManifest() must return non-empty data")
        
        // Should be valid JSON
        let json = try JSONSerialization.jsonObject(with: manifestData)
        XCTAssertNotNil(json,
                        "exportManifest() must produce valid JSON")
    }
    
    // MARK: - DualDigest Tests
    
    func testDualDigestCompute() {
        let data = "test data".data(using: .utf8)!
        let dual = DualDigest.compute(data: data)
        
        XCTAssertEqual(dual.sha256.count, 64,
                       "sha256 must be 64 hex characters")
        XCTAssertEqual(dual.sha3_256, DualDigest.SHA3_PENDING,
                       "sha3_256 must be placeholder in v1.0.0")
    }
    
    func testDualDigestVerify() {
        let data = "test data".data(using: .utf8)!
        let dual = DualDigest.compute(data: data)
        
        // Verify should pass for same data
        XCTAssertTrue(dual.verify(against: data),
                      "DualDigest.verify() must return true for matching data")
        
        // Verify should fail for different data
        let differentData = "different".data(using: .utf8)!
        XCTAssertFalse(dual.verify(against: differentData),
                       "DualDigest.verify() must return false for different data")
    }
    
    // MARK: - ACI Tests
    
    func testACIFromSHA256Hex() {
        let hex = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let aci = ACI.fromSHA256Hex(hex)
        
        XCTAssertEqual(aci.version, 1)
        XCTAssertEqual(aci.algorithm, "sha256")
        XCTAssertEqual(aci.digest, hex)
    }
    
    func testACIParse() throws {
        let aciString = "aci:1:sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let aci = try ACI.parse(aciString)
        
        XCTAssertEqual(aci.version, 1)
        XCTAssertEqual(aci.algorithm, "sha256")
        XCTAssertEqual(aci.digest, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(aci.description, aciString,
                       "ACI.description must match parsed string")
    }
    
    func testACIParseInvalidFormat() {
        let invalid = "invalid:format"
        XCTAssertThrowsError(try ACI.parse(invalid)) { error in
            XCTAssertTrue(error is BundleError,
                         "Should throw BundleError for invalid ACI format")
        }
    }
    
    func testACIDescription() {
        let hex = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let aci = ACI.fromSHA256Hex(hex)
        let expected = "aci:1:sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        XCTAssertEqual(aci.description, expected,
                       "ACI.description must match expected format")
    }
}
