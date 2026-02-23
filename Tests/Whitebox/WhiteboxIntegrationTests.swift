// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  WhiteboxIntegrationTests.swift
//  progect2
//
//  Created for PR#13 Whitebox Integration v6
//

import XCTest
@testable import Aether3DCore
import Foundation

final class WhiteboxIntegrationTests: XCTestCase {
    
    func createTempDir() -> URL {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        return tempRoot
    }
    
    func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
    
    func createTestRequest() -> BuildRequest {
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".mov")
        try! "test video content".write(to: tempFile, atomically: true, encoding: .utf8)
        return BuildRequest(
            source: .file(url: tempFile),
            requestedMode: .enter,
            deviceTier: .medium
        )
    }
    
    func loadManifest(from packageRoot: URL) throws -> WhiteboxArtifactManifest {
        let manifestURL = packageRoot.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: manifestURL)
        return try JSONDecoder().decode(WhiteboxArtifactManifest.self, from: data)
    }
    
    func findPackageRoot(in outputRoot: URL) throws -> URL {
        let fm = FileManager.default
        let items = try fm.contentsOfDirectory(at: outputRoot, includingPropertiesForKeys: nil)
        for item in items {
            let name = item.lastPathComponent
            if !name.hasPrefix(".staging-") && fm.directoryExists(atPath: item.path) {
                return item
            }
        }
        throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Package root not found"])
    }
    
    func test_generate_outputs_valid_manifest() async throws {
        let tempRoot = createTempDir()
        defer { cleanup(tempRoot) }
        
        let result = await PipelineRunner(remoteClient: FakeRemoteB1Client())
            .runGenerate(request: createTestRequest(), outputRoot: tempRoot)
        
        guard case .success(_, _) = result else {
            XCTFail("Pipeline must succeed")
            return
        }
        
        let packageRoot = try findPackageRoot(in: tempRoot)
        let manifestURL = packageRoot.appendingPathComponent("manifest.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path))
        
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(WhiteboxArtifactManifest.self, from: data)
        
        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.artifactId, String(manifest.artifactHash.prefix(8)))
        XCTAssertEqual(manifest.artifactId.count, 8)
        XCTAssertEqual(manifest.artifactHash.count, 64)
        XCTAssertEqual(manifest.policyHash.count, 64)
        XCTAssertTrue(manifest.artifactHash.allSatisfy { $0.isHexDigit })
        
        for file in manifest.files {
            let fileURL = packageRoot.appendingPathComponent(file.path)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
            
            let fileData = try Data(contentsOf: fileURL)
            XCTAssertEqual(fileData.count, file.bytes)
            
            let hash = _hexLowercase(_SHA256.hash(data: fileData))
            XCTAssertEqual(hash, file.sha256)
        }
        
        XCTAssertNoThrow(try validatePackage(at: packageRoot, manifest: manifest))
    }
    
    func test_determinism_byte_identical() async throws {
        let tempA = createTempDir()
        defer { cleanup(tempA) }
        
        let resultA = await PipelineRunner(remoteClient: FakeRemoteB1Client())
            .runGenerate(request: createTestRequest(), outputRoot: tempA)
        guard case .success(_, _) = resultA else {
            XCTFail("Run A failed")
            return
        }
        
        let pathA = try findPackageRoot(in: tempA)
        let bytesA = try Data(contentsOf: pathA.appendingPathComponent("manifest.json"))
        
        let tempB = createTempDir()
        defer { cleanup(tempB) }
        
        XCTAssertNotEqual(tempA.path, tempB.path)
        
        let resultB = await PipelineRunner(remoteClient: FakeRemoteB1Client())
            .runGenerate(request: createTestRequest(), outputRoot: tempB)
        guard case .success(_, _) = resultB else {
            XCTFail("Run B failed")
            return
        }
        
        let pathB = try findPackageRoot(in: tempB)
        let bytesB = try Data(contentsOf: pathB.appendingPathComponent("manifest.json"))
        
        XCTAssertEqual(bytesA, bytesB, "Manifest must be byte-identical")
        
        let mA = try JSONDecoder().decode(WhiteboxArtifactManifest.self, from: bytesA)
        let mB = try JSONDecoder().decode(WhiteboxArtifactManifest.self, from: bytesB)
        XCTAssertEqual(mA.artifactHash, mB.artifactHash)
        XCTAssertEqual(mA.artifactId, mB.artifactId)
        
        for file in mA.files {
            let dataA = try Data(contentsOf: pathA.appendingPathComponent(file.path))
            let dataB = try Data(contentsOf: pathB.appendingPathComponent(file.path))
            XCTAssertEqual(dataA, dataB, "File \(file.path) must be identical")
        }
        
        let filesA = Set(mA.files.map { $0.path })
        let filesB = Set(mB.files.map { $0.path })
        XCTAssertEqual(filesA, filesB)
    }
    
    func test_hash_manual_computation() async throws {
        let tempRoot = createTempDir()
        defer { cleanup(tempRoot) }
        
        let result = await PipelineRunner(remoteClient: FakeRemoteB1Client())
            .runGenerate(request: createTestRequest(), outputRoot: tempRoot)
        guard case .success(_, _) = result else {
            XCTFail("Failed")
            return
        }
        
        let packageRoot = try findPackageRoot(in: tempRoot)
        let data = try Data(contentsOf: packageRoot.appendingPathComponent("manifest.json"))
        let manifest = try JSONDecoder().decode(WhiteboxArtifactManifest.self, from: data)
        
        var hashInput = Data()
        hashInput.append("A3D_ARTIFACT_V1\n".data(using: .utf8)!)
        hashInput.append((manifest.policyHash + "\n").data(using: .utf8)!)
        hashInput.append("1\n".data(using: .utf8)!)
        hashInput.append("\(manifest.files.count)\n".data(using: .utf8)!)
        
        for file in manifest.files.sorted(by: { $0.path < $1.path }) {
            hashInput.append((file.path + "\n").data(using: .utf8)!)
            hashInput.append((file.sha256 + "\n").data(using: .utf8)!)
        }
        
        let computed = _hexLowercase(_SHA256.hash(data: hashInput))
        
        XCTAssertEqual(computed, manifest.artifactHash)
        XCTAssertEqual(String(computed.prefix(8)), manifest.artifactId)
    }
    
    func test_canonical_format() async throws {
        let tempRoot = createTempDir()
        defer { cleanup(tempRoot) }
        
        let result = await PipelineRunner(remoteClient: FakeRemoteB1Client())
            .runGenerate(request: createTestRequest(), outputRoot: tempRoot)
        guard case .success(_, _) = result else {
            XCTFail("Failed")
            return
        }
        
        let packageRoot = try findPackageRoot(in: tempRoot)
        let bytes = try Data(contentsOf: packageRoot.appendingPathComponent("manifest.json"))
        
        XCTAssertEqual(bytes.last, 0x0A)
        XCTAssertFalse(bytes.contains(0x0D))
        
        let withoutTrailing = bytes.dropLast()
        XCTAssertFalse(withoutTrailing.contains(0x0A))
        
        let manifest = try JSONDecoder().decode(WhiteboxArtifactManifest.self, from: bytes)
        let reencoded = CanonicalEncoder.encode(manifest)
        XCTAssertEqual(bytes, reencoded)
    }
    
    func test_validation_rejects_invalid() async throws {
        let tempRoot = createTempDir()
        defer { cleanup(tempRoot) }
        
        let result = await PipelineRunner(remoteClient: FakeRemoteB1Client())
            .runGenerate(request: createTestRequest(), outputRoot: tempRoot)
        guard case .success(_, _) = result else {
            XCTFail("Failed to create valid package")
            return
        }
        
        let packageRoot = try findPackageRoot(in: tempRoot)
        let manifest = try loadManifest(from: packageRoot)
        
        try "extra".write(
            to: packageRoot.appendingPathComponent("extra.txt"),
            atomically: true,
            encoding: .utf8
        )
        
        XCTAssertThrowsError(try validatePackage(at: packageRoot, manifest: manifest)) { error in
            guard case WhiteboxArtifactError.unreferencedFile("extra.txt") = error else {
                XCTFail("Expected unreferencedFile error, got \(error)")
                return
            }
        }
    }
    
    func test_validation_rejects_invalid_manifest() throws {
        let manifest = WhiteboxArtifactManifest(
            schemaVersion: 2,
            artifactId: "12345678",
            policyHash: "0000000000000000000000000000000000000000000000000000000000000000",
            artifactHash: "0000000000000000000000000000000000000000000000000000000000000000",
            files: []
        )
        
        XCTAssertThrowsError(try validateManifest(manifest)) { error in
            guard case WhiteboxArtifactError.invalidSchemaVersion(2) = error else {
                XCTFail("Expected invalidSchemaVersion error")
                return
            }
        }
    }
}

extension FileManager {
    func directoryExists(atPath path: String) -> Bool {
        var isDir: ObjCBool = false
        return fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}

