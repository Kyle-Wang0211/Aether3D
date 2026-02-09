// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// CanonicalDigestTests.swift
// Aether3D
//
// Tests for CanonicalDigest (H1: Encoder-driven canonical JSON)
//

import XCTest
@testable import Aether3DCore

final class CanonicalDigestTests: XCTestCase {
    
    // MARK: - Basic Encoding Tests
    
    func testEncodeSimpleStruct() throws {
        struct TestStruct: Codable {
            let name: String
            let value: Int64
            let flag: Bool
        }
        
        let input = TestStruct(name: "test", value: 42, flag: true)
        let digest = try CanonicalDigest.computeDigest(input)
        
        XCTAssertFalse(digest.isEmpty)
        XCTAssertEqual(digest.count, 64)  // SHA-256 hex string length
        
        // Also test encode returns non-empty data
        let bytes = try CanonicalDigest.encode(input)
        XCTAssertFalse(bytes.isEmpty)
    }
    
    func testEncodeMinimalStruct() throws {
        // Minimal smoke test: simple struct with Int and String
        struct MinimalStruct: Codable {
            let a: Int
            let b: String
        }
        
        let input = MinimalStruct(a: 1, b: "test")
        let bytes = try CanonicalDigest.encode(input)
        XCTAssertFalse(bytes.isEmpty, "Encoding must return non-empty data")
        
        let digest = try CanonicalDigest.computeDigest(input)
        XCTAssertFalse(digest.isEmpty, "Digest must be computed")
        XCTAssertEqual(digest.count, 64, "SHA-256 hex string must be 64 characters")
    }
    
    func testEncodeNestedStruct() throws {
        struct Nested: Codable {
            let inner: String
        }
        struct Outer: Codable {
            let outer: String
            let nested: Nested
        }
        
        let input = Outer(outer: "outer", nested: Nested(inner: "inner"))
        let digest = try CanonicalDigest.computeDigest(input)
        
        XCTAssertFalse(digest.isEmpty)
        
        // Verify nested encoding doesn't throw missingValue
        let bytes = try CanonicalDigest.encode(input)
        XCTAssertFalse(bytes.isEmpty)
    }
    
    func testEncodeNestedObjectAndArray() throws {
        // Test nested containers (object containing array, array containing objects)
        struct Item: Codable {
            let id: Int64
            let name: String
        }
        struct Container: Codable {
            let items: [Item]
            let metadata: Metadata
        }
        struct Metadata: Codable {
            let count: Int64
            let tags: [String]
        }
        
        let input = Container(
            items: [
                Item(id: 1, name: "first"),
                Item(id: 2, name: "second")
            ],
            metadata: Metadata(
                count: 2,
                tags: ["tag1", "tag2"]
            )
        )
        
        // Should not throw missingValue
        let digest = try CanonicalDigest.computeDigest(input)
        XCTAssertFalse(digest.isEmpty)
        
        let bytes = try CanonicalDigest.encode(input)
        XCTAssertFalse(bytes.isEmpty)
    }
    
    func testEncodeArray() throws {
        struct WithArray: Codable {
            let items: [Int64]
        }
        
        let input = WithArray(items: [1, 2, 3])
        let digest = try CanonicalDigest.computeDigest(input)
        
        XCTAssertFalse(digest.isEmpty)
    }
    
    // MARK: - Float Rejection Tests (Negative Tests)
    
    func testRejectDouble() throws {
        struct WithDouble: Codable {
            let value: Double
        }
        
        let input = WithDouble(value: 3.14)
        
        XCTAssertThrowsError(try CanonicalDigest.computeDigest(input)) { error in
            if case CanonicalDigestError.floatForbidden = error {
                // Expected
            } else {
                XCTFail("Expected floatForbidden error, got: \(error)")
            }
        }
    }
    
    func testRejectFloat() throws {
        struct WithFloat: Codable {
            let value: Float
        }
        
        let input = WithFloat(value: 3.14)
        
        XCTAssertThrowsError(try CanonicalDigest.computeDigest(input)) { error in
            if case CanonicalDigestError.floatForbidden = error {
                // Expected
            } else {
                XCTFail("Expected floatForbidden error, got: \(error)")
            }
        }
    }
    
    // MARK: - Determinism Tests
    
    func testDeterministicEncoding() throws {
        struct TestStruct: Codable {
            let a: Int64
            let b: String
            let c: Bool
        }
        
        let input = TestStruct(a: 42, b: "test", c: true)
        let digest1 = try CanonicalDigest.computeDigest(input)
        let digest2 = try CanonicalDigest.computeDigest(input)
        
        XCTAssertEqual(digest1, digest2, "Digests must be deterministic")
    }
    
    func testKeyOrdering() throws {
        // Keys should be sorted lexicographically
        struct TestStruct: Codable {
            let z: Int64
            let a: Int64
            let m: Int64
        }
        
        let input = TestStruct(z: 3, a: 1, m: 2)
        let bytes1 = try CanonicalDigest.encode(input)
        
        // Reorder fields (should produce same output due to sorting)
        struct TestStruct2: Codable {
            let a: Int64
            let m: Int64
            let z: Int64
        }
        
        let input2 = TestStruct2(a: 1, m: 2, z: 3)
        let bytes2 = try CanonicalDigest.encode(input2)
        
        XCTAssertEqual(bytes1, bytes2, "Key ordering should not affect output")
    }
    
    func testDeterminismRegression() throws {
        // Regression test: compute digest 20 times and assert byte-for-byte equality
        struct TestStruct: Codable {
            let a: Int64
            let b: String
            let nested: Nested
        }
        struct Nested: Codable {
            let items: [Int64]
            let flag: Bool
        }
        
        let input = TestStruct(
            a: 100,
            b: "test string with special chars: \"quotes\" and \\backslash",
            nested: Nested(items: [1, 2, 3, 42], flag: true)
        )
        
        var previousDigest: String?
        var previousBytes: Data?
        
        for i in 1...20 {
            let digest = try CanonicalDigest.computeDigest(input)
            let bytes = try CanonicalDigest.encode(input)
            
            if let prevDigest = previousDigest {
                XCTAssertEqual(digest, prevDigest, "Digest must be identical on iteration \(i)")
            }
            if let prevBytes = previousBytes {
                XCTAssertEqual(bytes, prevBytes, "Bytes must be byte-for-byte identical on iteration \(i)")
            }
            
            previousDigest = digest
            previousBytes = bytes
        }
    }
}
