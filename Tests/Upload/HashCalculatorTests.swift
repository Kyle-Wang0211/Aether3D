//
//  HashCalculatorTests.swift
//  Aether3D
//
//  PR#8: Immutable Bundle Format - Hash Calculator Tests
//

import XCTest
@testable import Aether3DCore

final class HashCalculatorTests: XCTestCase {
    
    // MARK: - Golden Vector Tests
    
    func testSHA256EmptyString() {
        // SHA-256("") = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
        let emptyData = Data()
        let hash = HashCalculator.sha256(of: emptyData)
        let expected = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        XCTAssertEqual(hash, expected,
                       "SHA-256 of empty string must match NIST test vector")
    }
    
    func testSHA256ABC() {
        // SHA-256("abc") = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
        let abcData = "abc".data(using: .utf8)!
        let hash = HashCalculator.sha256(of: abcData)
        let expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        XCTAssertEqual(hash, expected,
                       "SHA-256 of 'abc' must match NIST test vector")
    }
    
    // MARK: - Streaming File Hash Tests
    
    func testStreamingHashMatchesMemoryHash() throws {
        // Create a temporary file with known content
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempFile) }
        
        let testContent = "Hello, World! This is a test file for streaming hash."
        try testContent.write(to: tempFile, atomically: true, encoding: .utf8)
        
        // Compute hash via streaming
        let streamingResult = try HashCalculator.sha256OfFile(at: tempFile)
        
        // Compute hash via memory
        let fileData = try Data(contentsOf: tempFile)
        let memoryHash = HashCalculator.sha256(of: fileData)
        
        // They must match
        XCTAssertEqual(streamingResult.sha256Hex, memoryHash,
                       "Streaming hash must match memory hash for deterministic results")
        
        // Byte count must match
        XCTAssertEqual(streamingResult.byteCount, Int64(fileData.count),
                       "Streaming byte count must match actual file size")
    }
    
    func testStreamingHashLargeFile() throws {
        // Create a temporary file larger than chunk size
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempFile) }
        
        // Create file with multiple chunks
        let chunkSize = BundleConstants.HASH_STREAM_CHUNK_BYTES
        let testData = Data(repeating: 0x42, count: chunkSize * 3)
        try testData.write(to: tempFile)
        
        // Compute hash via streaming
        let streamingResult = try HashCalculator.sha256OfFile(at: tempFile)
        
        // Compute hash via memory
        let memoryHash = HashCalculator.sha256(of: testData)
        
        // They must match
        XCTAssertEqual(streamingResult.sha256Hex, memoryHash,
                       "Streaming hash must match memory hash for large files")
        XCTAssertEqual(streamingResult.byteCount, Int64(testData.count),
                       "Streaming byte count must match actual file size")
    }
    
    func testFileHashResultByteCount() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempFile) }
        
        let testContent = "Test content"
        try testContent.write(to: tempFile, atomically: true, encoding: .utf8)
        
        let result = try HashCalculator.sha256OfFile(at: tempFile)
        
        // Byte count must match file size
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: tempFile.path)
        let fileSize = fileAttributes[.size] as! Int64
        
        XCTAssertEqual(result.byteCount, fileSize,
                       "FileHashResult.byteCount must match actual file size")
    }
    
    // MARK: - Domain Separation Tests
    
    func testDomainSeparationProducesDifferentHashes() {
        let testData = "test data".data(using: .utf8)!
        
        let hash1 = HashCalculator.sha256WithDomain(
            BundleConstants.BUNDLE_HASH_DOMAIN_TAG,
            data: testData
        )
        
        let hash2 = HashCalculator.sha256WithDomain(
            BundleConstants.MANIFEST_HASH_DOMAIN_TAG,
            data: testData
        )
        
        // Different domain tags must produce different hashes
        XCTAssertNotEqual(hash1, hash2,
                         "Different domain tags must produce different hashes")
        
        // Same domain tag + same data = same hash
        let hash3 = HashCalculator.sha256WithDomain(
            BundleConstants.BUNDLE_HASH_DOMAIN_TAG,
            data: testData
        )
        XCTAssertEqual(hash1, hash3,
                       "Same domain tag + same data must produce same hash")
    }
    
    func testDomainSeparationWithEmptyData() {
        let emptyData = Data()
        
        let hash1 = HashCalculator.sha256WithDomain(
            BundleConstants.BUNDLE_HASH_DOMAIN_TAG,
            data: emptyData
        )
        
        let hash2 = HashCalculator.sha256WithDomain(
            BundleConstants.MANIFEST_HASH_DOMAIN_TAG,
            data: emptyData
        )
        
        // Even with empty data, different domains produce different hashes
        XCTAssertNotEqual(hash1, hash2,
                         "Different domain tags must produce different hashes even with empty data")
    }
    
    // MARK: - OCI Digest Format Tests
    
    func testOCIDigestFromHex() {
        let hex = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let digest = HashCalculator.ociDigest(fromHex: hex)
        let expected = "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        XCTAssertEqual(digest, expected,
                       "OCI digest format must be 'sha256:<64hex>'")
    }
    
    func testHexFromOCIDigest() throws {
        let digest = "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let hex = try HashCalculator.hexFromOCIDigest(digest)
        let expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        XCTAssertEqual(hex, expected,
                       "hexFromOCIDigest must extract hex from OCI format")
    }
    
    func testOCIDigestRoundTrip() throws {
        let originalHex = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let digest = HashCalculator.ociDigest(fromHex: originalHex)
        let extractedHex = try HashCalculator.hexFromOCIDigest(digest)
        XCTAssertEqual(extractedHex, originalHex,
                       "OCI digest round trip must preserve original hex")
    }
    
    func testHexFromOCIDigestInvalidPrefix() {
        let invalidDigest = "invalid:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        XCTAssertThrowsError(try HashCalculator.hexFromOCIDigest(invalidDigest)) { error in
            guard case BundleError.invalidDigestFormat = error else {
                XCTFail("Expected invalidDigestFormat error")
                return
            }
        }
    }
    
    func testHexFromOCIDigestInvalidHex() {
        let invalidDigest = "sha256:invalidhex"
        XCTAssertThrowsError(try HashCalculator.hexFromOCIDigest(invalidDigest)) { error in
            // Should throw validation error
            XCTAssertTrue(error is BundleError || error is ArtifactError,
                         "Should throw validation error for invalid hex")
        }
    }
    
    // MARK: - Timing-Safe Comparison Tests
    
    func testTimingSafeEqualSameData() {
        let data1 = "test data".data(using: .utf8)!
        let data2 = "test data".data(using: .utf8)!
        
        XCTAssertTrue(HashCalculator.timingSafeEqual(data1, data2),
                      "timingSafeEqual must return true for identical data")
    }
    
    func testTimingSafeEqualDifferentData() {
        let data1 = "test data".data(using: .utf8)!
        let data2 = "different".data(using: .utf8)!
        
        XCTAssertFalse(HashCalculator.timingSafeEqual(data1, data2),
                       "timingSafeEqual must return false for different data")
    }
    
    func testTimingSafeEqualEmptyData() {
        let empty1 = Data()
        let empty2 = Data()
        
        XCTAssertTrue(HashCalculator.timingSafeEqual(empty1, empty2),
                      "timingSafeEqual must return true for empty data")
    }
    
    func testTimingSafeEqualHexSameString() {
        let hex1 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let hex2 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        
        XCTAssertTrue(HashCalculator.timingSafeEqualHex(hex1, hex2),
                      "timingSafeEqualHex must return true for identical hex strings")
    }
    
    func testTimingSafeEqualHexCaseInsensitive() {
        let hex1 = "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD"
        let hex2 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        
        XCTAssertTrue(HashCalculator.timingSafeEqualHex(hex1, hex2),
                      "timingSafeEqualHex must be case-insensitive")
    }
    
    func testTimingSafeEqualHexDifferentString() {
        let hex1 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let hex2 = "0000000000000000000000000000000000000000000000000000000000000000"
        
        XCTAssertFalse(HashCalculator.timingSafeEqualHex(hex1, hex2),
                       "timingSafeEqualHex must return false for different hex strings")
    }
    
    func testTimingSafeEqualHexInvalidHex() {
        let hex1 = "invalid"
        let hex2 = "invalid"
        
        // Invalid hex should return false (conversion fails)
        XCTAssertFalse(HashCalculator.timingSafeEqualHex(hex1, hex2),
                       "timingSafeEqualHex must return false for invalid hex strings")
    }
    
    // MARK: - File Verification Tests
    
    func testVerifyFileUntampered() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempFile) }
        
        let testContent = "Test file content"
        try testContent.write(to: tempFile, atomically: true, encoding: .utf8)
        
        // Compute expected hash
        let fileData = try Data(contentsOf: tempFile)
        let expectedHash = HashCalculator.sha256(of: fileData)
        
        // Verify file
        let isValid = try HashCalculator.verifyFile(at: tempFile, expectedSHA256Hex: expectedHash)
        XCTAssertTrue(isValid,
                      "verifyFile must return true for untampered file")
    }
    
    func testVerifyFileTampered() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempFile) }
        
        let testContent = "Test file content"
        try testContent.write(to: tempFile, atomically: true, encoding: .utf8)
        
        // Compute expected hash
        let fileData = try Data(contentsOf: tempFile)
        let expectedHash = HashCalculator.sha256(of: fileData)
        
        // Tamper with file
        try "Tampered content".write(to: tempFile, atomically: true, encoding: .utf8)
        
        // Verify file (should fail)
        let isValid = try HashCalculator.verifyFile(at: tempFile, expectedSHA256Hex: expectedHash)
        XCTAssertFalse(isValid,
                      "verifyFile must return false for tampered file")
    }
    
    func testVerifyFileNonexistent() {
        let tempDir = FileManager.default.temporaryDirectory
        let nonexistentFile = tempDir.appendingPathComponent(UUID().uuidString)
        
        let fakeHash = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        
        XCTAssertThrowsError(try HashCalculator.verifyFile(at: nonexistentFile, expectedSHA256Hex: fakeHash)) { error in
            // Should throw file system error
            XCTAssertTrue(error is CocoaError || error is NSError,
                         "Should throw file system error for nonexistent file")
        }
    }
    
    // MARK: - Edge Cases
    
    func testEmptyFileHash() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempFile) }
        
        // Create empty file
        try Data().write(to: tempFile)
        
        let result = try HashCalculator.sha256OfFile(at: tempFile)
        
        // Empty file hash should match golden vector
        let expected = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        XCTAssertEqual(result.sha256Hex, expected,
                       "Empty file hash must match SHA-256('') golden vector")
        XCTAssertEqual(result.byteCount, 0,
                       "Empty file byte count must be 0")
    }
}
