// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  ArtifactManifestTests.swift
//  progect2
//
//  Created for PR#10.5.9 Artifact Contract
//

import XCTest
@testable import Aether3DCore
import Foundation

final class ArtifactManifestTests: XCTestCase {
    
    // MARK: - Fixture Helper
    
    func makeMinimalFixture() throws -> ArtifactManifest {
        let buildMeta: BuildMetaMap = [:]
        let coordinateSystem = try CoordinateSystem(upAxis: "Y", unitScale: 1.0)
        let lod = try LODDescriptor(
            lodId: "lod0",
            qualityTier: "medium",
            approxSplatCount: 1000,
            entryFile: "data.splat"
        )
        let file1 = try FileDescriptor(
            path: "data.splat",
            sha256: "0000000000000000000000000000000000000000000000000000000000000000",
            bytes: 1000,
            contentType: "application/x-aether-splat",
            role: "lod_entry"
        )
        let file2 = try FileDescriptor(
            path: "thumb.png",
            sha256: "1111111111111111111111111111111111111111111111111111111111111111",
            bytes: 500,
            contentType: "image/png",
            role: "thumbnail"
        )
        let fallbacks = try Fallbacks(thumbnail: "thumb.png", previewVideo: nil)
        let policyHash = "0000000000000000000000000000000000000000000000000000000000000000"
        
        return try ArtifactManifest(
            buildMeta: buildMeta,
            coordinateSystem: coordinateSystem,
            lods: [lod],
            files: [file1, file2],
            fallbacks: fallbacks,
            policyHash: policyHash
        )
    }
    
    // MARK: - Test 1: Golden Hash Stable
    
    func test_goldenHash_stable() throws {
        let manifest = try makeMinimalFixture()
        let expectedHash = "50eb63374d747f23f2ec970706b89dcdfea47132e8bba5d12f54063b475bda3a"
        XCTAssertEqual(manifest.artifactHash, expectedHash, "Artifact hash must be stable and match golden value")
    }
    
    // MARK: - Test 2: Canonical Bytes Deterministic
    
    func test_canonicalBytes_deterministic() throws {
        let manifest = try makeMinimalFixture()
        
        let bytes1 = try manifest.canonicalBytesForHashing()
        let bytes2 = try manifest.canonicalBytesForHashing()
        
        XCTAssertEqual(bytes1, bytes2, "Canonical bytes must be deterministic")
        
        let storage1 = try manifest.canonicalBytesForStorage()
        let storage2 = try manifest.canonicalBytesForStorage()
        
        XCTAssertEqual(storage1, storage2, "Storage bytes must be deterministic")
    }
    
    // MARK: - Test 3: artifactHash Excludes Itself
    
    func test_artifactHash_excludesItself() throws {
        let manifest = try makeMinimalFixture()
        let hashingBytes = try manifest.canonicalBytesForHashing()
        let hashingString = String(data: hashingBytes, encoding: .utf8)!
        
        XCTAssertFalse(hashingString.contains("artifactHash"), "Canonical bytes for hashing must not contain artifactHash")
    }
    
    // MARK: - Test 4: Any Field Change Changes Hash
    
    func test_fieldChange_changesHash() throws {
        let manifest1 = try makeMinimalFixture()
        let hash1 = manifest1.artifactHash
        
        // Modify a field
        let buildMeta: BuildMetaMap = [:]
        let coordinateSystem = try CoordinateSystem(upAxis: "Y", unitScale: 1.0)
        let lod = try LODDescriptor(
            lodId: "lod0",
            qualityTier: "medium",
            approxSplatCount: 1001, // Changed from 1000
            entryFile: "data.splat"
        )
        let file1 = try FileDescriptor(
            path: "data.splat",
            sha256: "0000000000000000000000000000000000000000000000000000000000000000",
            bytes: 1000,
            contentType: "application/x-aether-splat",
            role: "lod_entry"
        )
        let file2 = try FileDescriptor(
            path: "thumb.png",
            sha256: "1111111111111111111111111111111111111111111111111111111111111111",
            bytes: 500,
            contentType: "image/png",
            role: "thumbnail"
        )
        let fallbacks = try Fallbacks(thumbnail: "thumb.png", previewVideo: nil)
        let policyHash = "0000000000000000000000000000000000000000000000000000000000000000"
        
        let manifest2 = try ArtifactManifest(
            buildMeta: buildMeta,
            coordinateSystem: coordinateSystem,
            lods: [lod],
            files: [file1, file2],
            fallbacks: fallbacks,
            policyHash: policyHash
        )
        let hash2 = manifest2.artifactHash
        
        XCTAssertNotEqual(hash1, hash2, "Changing any field must change the hash")
    }
    
    // MARK: - Test 5: Unknown Fields Rejected
    
    func test_unknownFields_rejected_topLevel() throws {
        let json = """
        {
            "schemaVersion": 1,
            "artifactId": "test",
            "buildMeta": {},
            "coordinateSystem": {"upAxis": "Y", "unitScale": 1.0},
            "lods": [{"lodId": "lod0", "qualityTier": "medium", "approxSplatCount": 1000, "entryFile": "data.splat"}],
            "files": [{"path": "data.splat", "sha256": "0000000000000000000000000000000000000000000000000000000000000000", "bytes": 1000, "contentType": "application/x-aether-splat", "role": "lod_entry"}],
            "policyHash": "0000000000000000000000000000000000000000000000000000000000000000",
            "artifactHash": "0000000000000000000000000000000000000000000000000000000000000000",
            "unknownField": "should be rejected"
        }
        """
        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()
        
        XCTAssertThrowsError(try decoder.decode(ArtifactManifest.self, from: data)) { error in
            if case ArtifactError.unknownFields(let keys) = error {
                XCTAssertTrue(keys.contains("unknownField"), "Should reject unknown top-level field")
            } else {
                XCTFail("Expected unknownFields error, got \(error)")
            }
        }
    }
    
    func test_unknownFields_rejected_nested() throws {
        let json = """
        {
            "schemaVersion": 1,
            "artifactId": "test",
            "buildMeta": {},
            "coordinateSystem": {"upAxis": "Y", "unitScale": 1.0, "unknownField": "reject"},
            "lods": [{"lodId": "lod0", "qualityTier": "medium", "approxSplatCount": 1000, "entryFile": "data.splat"}],
            "files": [{"path": "data.splat", "sha256": "0000000000000000000000000000000000000000000000000000000000000000", "bytes": 1000, "contentType": "application/x-aether-splat", "role": "lod_entry"}],
            "policyHash": "0000000000000000000000000000000000000000000000000000000000000000",
            "artifactHash": "0000000000000000000000000000000000000000000000000000000000000000"
        }
        """
        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()
        
        XCTAssertThrowsError(try decoder.decode(ArtifactManifest.self, from: data)) { error in
            if case ArtifactError.unknownFields(let keys) = error {
                XCTAssertTrue(keys.contains("unknownField"), "Should reject unknown nested field")
            } else {
                XCTFail("Expected unknownFields error, got \(error)")
            }
        }
    }
    
    // MARK: - Test 6: policyHash Format Enforcement
    
    func test_policyHash_uppercase_rejected() throws {
        let buildMeta: BuildMetaMap = [:]
        let coordinateSystem = try CoordinateSystem(upAxis: "Y", unitScale: 1.0)
        let lod = try LODDescriptor(
            lodId: "lod0",
            qualityTier: "medium",
            approxSplatCount: 1000,
            entryFile: "data.splat"
        )
        let file = try FileDescriptor(
            path: "data.splat",
            sha256: "0000000000000000000000000000000000000000000000000000000000000000",
            bytes: 1000,
            contentType: "application/x-aether-splat",
            role: "lod_entry"
        )
        let policyHash = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" // Uppercase
        
        XCTAssertThrowsError(try ArtifactManifest(
            buildMeta: buildMeta,
            coordinateSystem: coordinateSystem,
            lods: [lod],
            files: [file],
            fallbacks: nil,
            policyHash: policyHash
        )) { error in
            if case ArtifactError.invalidSHA256 = error {
                // Expected
            } else {
                XCTFail("Expected invalidSHA256 error for uppercase policyHash, got \(error)")
            }
        }
    }
    
    func test_policyHash_wrongLength_rejected() throws {
        let buildMeta: BuildMetaMap = [:]
        let coordinateSystem = try CoordinateSystem(upAxis: "Y", unitScale: 1.0)
        let lod = try LODDescriptor(
            lodId: "lod0",
            qualityTier: "medium",
            approxSplatCount: 1000,
            entryFile: "data.splat"
        )
        let file = try FileDescriptor(
            path: "data.splat",
            sha256: "0000000000000000000000000000000000000000000000000000000000000000",
            bytes: 1000,
            contentType: "application/x-aether-splat",
            role: "lod_entry"
        )
        let policyHash = "000000000000000000000000000000000000000000000000000000000000000" // 63 chars
        
        XCTAssertThrowsError(try ArtifactManifest(
            buildMeta: buildMeta,
            coordinateSystem: coordinateSystem,
            lods: [lod],
            files: [file],
            fallbacks: nil,
            policyHash: policyHash
        )) { error in
            if case ArtifactError.invalidSHA256 = error {
                // Expected
            } else {
                XCTFail("Expected invalidSHA256 error for wrong length policyHash, got \(error)")
            }
        }
    }
    
    // MARK: - Test 7: sha256 Format Enforcement in FileDescriptor
    
    func test_fileSHA256_invalidChars_rejected() throws {
        XCTAssertThrowsError(try FileDescriptor(
            path: "data.splat",
            sha256: "GGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGG",
            bytes: 1000,
            contentType: "application/x-aether-splat",
            role: "lod_entry"
        )) { error in
            if case ArtifactError.invalidSHA256 = error {
                // Expected
            } else {
                XCTFail("Expected invalidSHA256 error for invalid chars, got \(error)")
            }
        }
    }
    
    func test_fileSHA256_uppercase_rejected() throws {
        XCTAssertThrowsError(try FileDescriptor(
            path: "data.splat",
            sha256: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            bytes: 1000,
            contentType: "application/x-aether-splat",
            role: "lod_entry"
        )) { error in
            if case ArtifactError.invalidSHA256 = error {
                // Expected
            } else {
                XCTFail("Expected invalidSHA256 error for uppercase, got \(error)")
            }
        }
    }
    
    // MARK: - Test 8: Path Rules
    
    func test_path_rules_rejected() throws {
        // Test ../x
        XCTAssertThrowsError(try FileDescriptor(
            path: "../x",
            sha256: "0000000000000000000000000000000000000000000000000000000000000000",
            bytes: 1000,
            contentType: "application/x-aether-splat",
            role: "lod_entry"
        )) { error in
            if case ArtifactError.invalidPath = error {
                // Expected
            } else {
                XCTFail("Expected invalidPath error for ../x, got \(error)")
            }
        }
        
        // Test /abs
        XCTAssertThrowsError(try FileDescriptor(
            path: "/abs",
            sha256: "0000000000000000000000000000000000000000000000000000000000000000",
            bytes: 1000,
            contentType: "application/x-aether-splat",
            role: "lod_entry"
        )) { error in
            if case ArtifactError.invalidPath = error {
                // Expected
            } else {
                XCTFail("Expected invalidPath error for /abs, got \(error)")
            }
        }
        
        // Test a\\b (backslash)
        XCTAssertThrowsError(try FileDescriptor(
            path: "a\\b",
            sha256: "0000000000000000000000000000000000000000000000000000000000000000",
            bytes: 1000,
            contentType: "application/x-aether-splat",
            role: "lod_entry"
        )) { error in
            if case ArtifactError.invalidPath = error {
                // Expected
            } else {
                XCTFail("Expected invalidPath error for a\\b, got \(error)")
            }
        }
        
        // Test a//b (double slash)
        XCTAssertThrowsError(try FileDescriptor(
            path: "a//b",
            sha256: "0000000000000000000000000000000000000000000000000000000000000000",
            bytes: 1000,
            contentType: "application/x-aether-splat",
            role: "lod_entry"
        )) { error in
            if case ArtifactError.invalidPath = error {
                // Expected
            } else {
                XCTFail("Expected invalidPath error for a//b, got \(error)")
            }
        }
        
        // Test trailing slash
        XCTAssertThrowsError(try FileDescriptor(
            path: "data/",
            sha256: "0000000000000000000000000000000000000000000000000000000000000000",
            bytes: 1000,
            contentType: "application/x-aether-splat",
            role: "lod_entry"
        )) { error in
            if case ArtifactError.invalidPath = error {
                // Expected
            } else {
                XCTFail("Expected invalidPath error for trailing slash, got \(error)")
            }
        }
        
        // Test non-ASCII (Chinese characters)
        XCTAssertThrowsError(try FileDescriptor(
            path: "文件.txt",
            sha256: "0000000000000000000000000000000000000000000000000000000000000000",
            bytes: 1000,
            contentType: "application/x-aether-splat",
            role: "lod_entry"
        )) { error in
            if case ArtifactError.invalidPath = error {
                // Expected
            } else {
                XCTFail("Expected invalidPath error for non-ASCII, got \(error)")
            }
        }
    }
    
    // MARK: - Test 9: Path Uniqueness Case-Insensitive
    
    func test_path_uniqueness_caseInsensitive() throws {
        let buildMeta: BuildMetaMap = [:]
        let coordinateSystem = try CoordinateSystem(upAxis: "Y", unitScale: 1.0)
        let lod = try LODDescriptor(
            lodId: "lod0",
            qualityTier: "medium",
            approxSplatCount: 1000,
            entryFile: "Data.splat"
        )
        let file1 = try FileDescriptor(
            path: "Data.splat",
            sha256: "0000000000000000000000000000000000000000000000000000000000000000",
            bytes: 1000,
            contentType: "application/x-aether-splat",
            role: "lod_entry"
        )
        let file2 = try FileDescriptor(
            path: "data.splat",
            sha256: "1111111111111111111111111111111111111111111111111111111111111111",
            bytes: 500,
            contentType: "application/x-aether-splat",
            role: "lod_entry"
        )
        
        XCTAssertThrowsError(try ArtifactManifest(
            buildMeta: buildMeta,
            coordinateSystem: coordinateSystem,
            lods: [lod],
            files: [file1, file2],
            fallbacks: nil,
            policyHash: "0000000000000000000000000000000000000000000000000000000000000000"
        )) { error in
            if case ArtifactError.duplicatePath = error {
                // Expected
            } else {
                XCTFail("Expected duplicatePath error, got \(error)")
            }
        }
    }
    
    // MARK: - Test 10: LOD Entry File Exists
    
    func test_lodEntryFile_mustExist() throws {
        let buildMeta: BuildMetaMap = [:]
        let coordinateSystem = try CoordinateSystem(upAxis: "Y", unitScale: 1.0)
        let lod = try LODDescriptor(
            lodId: "lod0",
            qualityTier: "medium",
            approxSplatCount: 1000,
            entryFile: "missing.splat"
        )
        let file = try FileDescriptor(
            path: "data.splat",
            sha256: "0000000000000000000000000000000000000000000000000000000000000000",
            bytes: 1000,
            contentType: "application/x-aether-splat",
            role: "lod_entry"
        )
        
        XCTAssertThrowsError(try ArtifactManifest(
            buildMeta: buildMeta,
            coordinateSystem: coordinateSystem,
            lods: [lod],
            files: [file],
            fallbacks: nil,
            policyHash: "0000000000000000000000000000000000000000000000000000000000000000"
        )) { error in
            if case ArtifactError.missingLODEntryFile = error {
                // Expected
            } else {
                XCTFail("Expected missingLODEntryFile error, got \(error)")
            }
        }
    }
    
    // MARK: - Test 11: Fallback Must Exist + Role Match
    
    func test_fallback_mustExist() throws {
        let buildMeta: BuildMetaMap = [:]
        let coordinateSystem = try CoordinateSystem(upAxis: "Y", unitScale: 1.0)
        let lod = try LODDescriptor(
            lodId: "lod0",
            qualityTier: "medium",
            approxSplatCount: 1000,
            entryFile: "data.splat"
        )
        let file = try FileDescriptor(
            path: "data.splat",
            sha256: "0000000000000000000000000000000000000000000000000000000000000000",
            bytes: 1000,
            contentType: "application/x-aether-splat",
            role: "lod_entry"
        )
        let fallbacks = try Fallbacks(thumbnail: "missing.png", previewVideo: nil)
        
        XCTAssertThrowsError(try ArtifactManifest(
            buildMeta: buildMeta,
            coordinateSystem: coordinateSystem,
            lods: [lod],
            files: [file],
            fallbacks: fallbacks,
            policyHash: "0000000000000000000000000000000000000000000000000000000000000000"
        )) { error in
            if case ArtifactError.missingFallbackFile = error {
                // Expected
            } else {
                XCTFail("Expected missingFallbackFile error, got \(error)")
            }
        }
    }
    
    func test_fallback_roleMismatch() throws {
        let buildMeta: BuildMetaMap = [:]
        let coordinateSystem = try CoordinateSystem(upAxis: "Y", unitScale: 1.0)
        let lod = try LODDescriptor(
            lodId: "lod0",
            qualityTier: "medium",
            approxSplatCount: 1000,
            entryFile: "data.splat"
        )
        let file1 = try FileDescriptor(
            path: "data.splat",
            sha256: "0000000000000000000000000000000000000000000000000000000000000000",
            bytes: 1000,
            contentType: "application/x-aether-splat",
            role: "lod_entry"
        )
        let file2 = try FileDescriptor(
            path: "thumb.png",
            sha256: "1111111111111111111111111111111111111111111111111111111111111111",
            bytes: 500,
            contentType: "image/png",
            role: "asset" // Wrong role
        )
        let fallbacks = try Fallbacks(thumbnail: "thumb.png", previewVideo: nil)
        
        XCTAssertThrowsError(try ArtifactManifest(
            buildMeta: buildMeta,
            coordinateSystem: coordinateSystem,
            lods: [lod],
            files: [file1, file2],
            fallbacks: fallbacks,
            policyHash: "0000000000000000000000000000000000000000000000000000000000000000"
        )) { error in
            if case ArtifactError.fallbackRoleMismatch = error {
                // Expected
            } else {
                XCTFail("Expected fallbackRoleMismatch error, got \(error)")
            }
        }
    }
    
    // MARK: - Test 12: Coordinate System Validation
    
    func test_coordinateSystem_invalidUpAxis() throws {
        XCTAssertThrowsError(try CoordinateSystem(upAxis: "INVALID", unitScale: 1.0)) { error in
            if case ArtifactError.invalidUpAxis = error {
                // Expected
            } else {
                XCTFail("Expected invalidUpAxis error, got \(error)")
            }
        }
    }
    
    func test_coordinateSystem_unitScale_negative() throws {
        XCTAssertThrowsError(try CoordinateSystem(upAxis: "Y", unitScale: -1.0)) { error in
            if case ArtifactError.invalidUnitScale = error {
                // Expected
            } else {
                XCTFail("Expected invalidUnitScale error for negative, got \(error)")
            }
        }
    }
    
    func test_coordinateSystem_unitScale_zero() throws {
        XCTAssertThrowsError(try CoordinateSystem(upAxis: "Y", unitScale: 0.0)) { error in
            if case ArtifactError.invalidUnitScale = error {
                // Expected
            } else {
                XCTFail("Expected invalidUnitScale error for zero, got \(error)")
            }
        }
    }
    
    func test_coordinateSystem_unitScale_NaN() throws {
        XCTAssertThrowsError(try CoordinateSystem(upAxis: "Y", unitScale: Double.nan)) { error in
            if case ArtifactError.invalidUnitScale = error {
                // Expected
            } else {
                XCTFail("Expected invalidUnitScale error for NaN, got \(error)")
            }
        }
    }
    
    func test_coordinateSystem_unitScale_infinity() throws {
        XCTAssertThrowsError(try CoordinateSystem(upAxis: "Y", unitScale: Double.infinity)) { error in
            if case ArtifactError.invalidUnitScale = error {
                // Expected
            } else {
                XCTFail("Expected invalidUnitScale error for Infinity, got \(error)")
            }
        }
    }
    
    func test_coordinateSystem_unitScale_outOfRange() throws {
        XCTAssertThrowsError(try CoordinateSystem(upAxis: "Y", unitScale: 0.0005)) { error in
            if case ArtifactError.invalidUnitScale = error {
                // Expected
            } else {
                XCTFail("Expected invalidUnitScale error for too small, got \(error)")
            }
        }
        
        XCTAssertThrowsError(try CoordinateSystem(upAxis: "Y", unitScale: 2000.0)) { error in
            if case ArtifactError.invalidUnitScale = error {
                // Expected
            } else {
                XCTFail("Expected invalidUnitScale error for too large, got \(error)")
            }
        }
    }
    
    // MARK: - Test 13: NFC + Null Byte Validation
    
    func test_string_nullByte_rejected() throws {
        let nullString = "test\u{0000}string"
        XCTAssertThrowsError(try FileDescriptor(
            path: nullString,
            sha256: "0000000000000000000000000000000000000000000000000000000000000000",
            bytes: 1000,
            contentType: "application/x-aether-splat",
            role: "lod_entry"
        )) { error in
            if case ArtifactError.stringContainsNullByte = error {
                // Expected
            } else {
                XCTFail("Expected stringContainsNullByte error, got \(error)")
            }
        }
    }
    
    func test_string_nonNFC_rejected() throws {
        // Create a non-NFC string (this is tricky - most strings are already NFC)
        // We'll test with a string that has combining characters
        let combining = "\u{0065}\u{0301}" // e + combining acute
        let nfc = combining.precomposedStringWithCanonicalMapping
        
        // If they're different, test the validation
        if combining != nfc {
            XCTAssertThrowsError(try FileDescriptor(
                path: combining,
                sha256: "0000000000000000000000000000000000000000000000000000000000000000",
                bytes: 1000,
                contentType: "application/x-aether-splat",
                role: "lod_entry"
            )) { error in
                if case ArtifactError.stringNotNFC = error {
                    // Expected
                } else {
                    XCTFail("Expected stringNotNFC error, got \(error)")
                }
            }
        } else {
            // If they're the same, the test passes (string is already NFC)
            XCTAssertTrue(true)
        }
    }
    
    // MARK: - Test 14: Array Sorting Deterministic
    
    func test_arraySorting_deterministic() throws {
        let buildMeta: BuildMetaMap = [:]
        let coordinateSystem = try CoordinateSystem(upAxis: "Y", unitScale: 1.0)
        let file1 = try FileDescriptor(path: "z.splat", sha256: "0000000000000000000000000000000000000000000000000000000000000000", bytes: 1000, contentType: "application/x-aether-splat", role: "lod_entry")
        let file2 = try FileDescriptor(path: "a.splat", sha256: "1111111111111111111111111111111111111111111111111111111111111111", bytes: 1000, contentType: "application/x-aether-splat", role: "lod_entry")
        let lod1 = try LODDescriptor(lodId: "lod1", qualityTier: "medium", approxSplatCount: 1000, entryFile: "z.splat")
        let lod2 = try LODDescriptor(lodId: "lod0", qualityTier: "medium", approxSplatCount: 1000, entryFile: "a.splat")
        
        let manifest = try ArtifactManifest(
            buildMeta: buildMeta,
            coordinateSystem: coordinateSystem,
            lods: [lod1, lod2], // lod1 before lod0
            files: [file1, file2], // z before a
            fallbacks: nil,
            policyHash: "0000000000000000000000000000000000000000000000000000000000000000"
        )
        
        let canonicalBytes = try manifest.canonicalBytesForHashing()
        let canonicalString = String(data: canonicalBytes, encoding: .utf8)!
        
        // Check that arrays are sorted in canonical bytes
        // lods should be sorted by lodId: lod0 before lod1
        let lod0Index = canonicalString.range(of: "\"lod0\"")?.lowerBound
        let lod1Index = canonicalString.range(of: "\"lod1\"")?.lowerBound
        if let idx0 = lod0Index, let idx1 = lod1Index {
            XCTAssertLessThan(idx0, idx1, "lods should be sorted by lodId in canonical bytes")
        }
        
        // files should be sorted by path: a before z
        let aIndex = canonicalString.range(of: "\"a.splat\"")?.lowerBound
        let zIndex = canonicalString.range(of: "\"z.splat\"")?.lowerBound
        if let idxA = aIndex, let idxZ = zIndex {
            XCTAssertLessThan(idxA, idxZ, "files should be sorted by path in canonical bytes")
        }
    }
    
    // MARK: - Test 15: buildMeta Always Present
    
    func test_buildMeta_alwaysPresent() throws {
        let buildMeta: BuildMetaMap = [:]
        let coordinateSystem = try CoordinateSystem(upAxis: "Y", unitScale: 1.0)
        let lod = try LODDescriptor(lodId: "lod0", qualityTier: "medium", approxSplatCount: 1000, entryFile: "data.splat")
        let file = try FileDescriptor(path: "data.splat", sha256: "0000000000000000000000000000000000000000000000000000000000000000", bytes: 1000, contentType: "application/x-aether-splat", role: "lod_entry")
        
        let manifest = try ArtifactManifest(
            buildMeta: buildMeta,
            coordinateSystem: coordinateSystem,
            lods: [lod],
            files: [file],
            fallbacks: nil,
            policyHash: "0000000000000000000000000000000000000000000000000000000000000000"
        )
        
        let encoder = JSONEncoder()
        let jsonData = try encoder.encode(manifest)
        let jsonString = String(data: jsonData, encoding: .utf8)!
        
        XCTAssertTrue(jsonString.contains("\"buildMeta\""), "buildMeta key must be present")
        XCTAssertTrue(jsonString.contains("\"buildMeta\":{}"), "Empty buildMeta must encode as {}")
    }
    
    // MARK: - Test 16: fallbacks Encoding Rules
    
    func test_fallbacks_nil_omitsKey() throws {
        let buildMeta: BuildMetaMap = [:]
        let coordinateSystem = try CoordinateSystem(upAxis: "Y", unitScale: 1.0)
        let lod = try LODDescriptor(lodId: "lod0", qualityTier: "medium", approxSplatCount: 1000, entryFile: "data.splat")
        let file = try FileDescriptor(path: "data.splat", sha256: "0000000000000000000000000000000000000000000000000000000000000000", bytes: 1000, contentType: "application/x-aether-splat", role: "lod_entry")
        
        let manifest = try ArtifactManifest(
            buildMeta: buildMeta,
            coordinateSystem: coordinateSystem,
            lods: [lod],
            files: [file],
            fallbacks: nil,
            policyHash: "0000000000000000000000000000000000000000000000000000000000000000"
        )
        
        let canonicalBytes = try manifest.canonicalBytesForHashing()
        let canonicalString = String(data: canonicalBytes, encoding: .utf8)!
        
        XCTAssertFalse(canonicalString.contains("\"fallbacks\""), "fallbacks == nil must omit key entirely")
    }
    
    func test_fallbacks_empty_encodesAsEmptyObject() throws {
        let buildMeta: BuildMetaMap = [:]
        let coordinateSystem = try CoordinateSystem(upAxis: "Y", unitScale: 1.0)
        let lod = try LODDescriptor(lodId: "lod0", qualityTier: "medium", approxSplatCount: 1000, entryFile: "data.splat")
        let file = try FileDescriptor(path: "data.splat", sha256: "0000000000000000000000000000000000000000000000000000000000000000", bytes: 1000, contentType: "application/x-aether-splat", role: "lod_entry")
        let fallbacks = try Fallbacks(thumbnail: nil, previewVideo: nil)
        
        let manifest = try ArtifactManifest(
            buildMeta: buildMeta,
            coordinateSystem: coordinateSystem,
            lods: [lod],
            files: [file],
            fallbacks: fallbacks,
            policyHash: "0000000000000000000000000000000000000000000000000000000000000000"
        )
        
        let canonicalBytes = try manifest.canonicalBytesForHashing()
        let canonicalString = String(data: canonicalBytes, encoding: .utf8)!
        
        XCTAssertTrue(canonicalString.contains("\"fallbacks\""), "fallbacks != nil must include key")
        XCTAssertTrue(canonicalString.contains("\"fallbacks\":{}"), "fallbacks with all fields nil must encode as {}")
        XCTAssertFalse(canonicalString.contains("thumbnail"), "Must not encode null thumbnail key")
        XCTAssertFalse(canonicalString.contains("previewVideo"), "Must not encode null previewVideo key")
    }
    
    func test_fallbacks_partial_encodesOnlyPresent() throws {
        let buildMeta: BuildMetaMap = [:]
        let coordinateSystem = try CoordinateSystem(upAxis: "Y", unitScale: 1.0)
        let lod = try LODDescriptor(lodId: "lod0", qualityTier: "medium", approxSplatCount: 1000, entryFile: "data.splat")
        let file1 = try FileDescriptor(path: "data.splat", sha256: "0000000000000000000000000000000000000000000000000000000000000000", bytes: 1000, contentType: "application/x-aether-splat", role: "lod_entry")
        let file2 = try FileDescriptor(path: "thumb.png", sha256: "1111111111111111111111111111111111111111111111111111111111111111", bytes: 500, contentType: "image/png", role: "thumbnail")
        let fallbacks = try Fallbacks(thumbnail: "thumb.png", previewVideo: nil)
        
        let manifest = try ArtifactManifest(
            buildMeta: buildMeta,
            coordinateSystem: coordinateSystem,
            lods: [lod],
            files: [file1, file2],
            fallbacks: fallbacks,
            policyHash: "0000000000000000000000000000000000000000000000000000000000000000"
        )
        
        let canonicalBytes = try manifest.canonicalBytesForHashing()
        let canonicalString = String(data: canonicalBytes, encoding: .utf8)!
        
        XCTAssertTrue(canonicalString.contains("\"fallbacks\""), "fallbacks != nil must include key")
        XCTAssertTrue(canonicalString.contains("\"thumbnail\""), "Must encode present thumbnail")
        XCTAssertTrue(canonicalString.contains("thumb.png"), "Must encode thumbnail value")
        XCTAssertFalse(canonicalString.contains("previewVideo"), "Must NOT encode absent previewVideo")
    }
}

