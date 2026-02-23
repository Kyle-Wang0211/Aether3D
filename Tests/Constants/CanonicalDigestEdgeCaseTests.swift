// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// CanonicalDigestEdgeCaseTests.swift
// Aether3D
//
// Tests for CanonicalDigest edge cases (string escaping, numeric boundaries, structural edge cases)
//

import XCTest
@testable import Aether3DCore

final class CanonicalDigestEdgeCaseTests: XCTestCase {
    
    // MARK: - String Edge Cases
    
    func testStringWithQuotes() throws {
        struct TestStruct: Codable {
            let value: String
        }
        
        let input = TestStruct(value: "test\"quoted\"string")
        let bytes = try CanonicalDigest.encode(input)
        XCTAssertFalse(bytes.isEmpty)
        
        // Verify quotes are escaped
        let jsonString = String(data: bytes, encoding: .utf8) ?? ""
        XCTAssertTrue(jsonString.contains("\\\""), "Quotes must be escaped")
    }
    
    func testStringWithBackslashes() throws {
        struct TestStruct: Codable {
            let value: String
        }
        
        let input = TestStruct(value: "test\\backslash\\string")
        let bytes = try CanonicalDigest.encode(input)
        XCTAssertFalse(bytes.isEmpty)
        
        // Verify backslashes are escaped
        let jsonString = String(data: bytes, encoding: .utf8) ?? ""
        XCTAssertTrue(jsonString.contains("\\\\"), "Backslashes must be escaped")
    }
    
    func testStringWithNewlines() throws {
        struct TestStruct: Codable {
            let value: String
        }
        
        let input = TestStruct(value: "line1\nline2\rline3")
        let bytes = try CanonicalDigest.encode(input)
        XCTAssertFalse(bytes.isEmpty)
        
        // Verify newlines are escaped
        let jsonString = String(data: bytes, encoding: .utf8) ?? ""
        XCTAssertTrue(jsonString.contains("\\n"), "Newlines must be escaped")
        XCTAssertTrue(jsonString.contains("\\r"), "Carriage returns must be escaped")
    }
    
    func testStringWithUnicode() throws {
        struct TestStruct: Codable {
            let value: String
        }
        
        // Test with emoji and CJK characters
        let input = TestStruct(value: "test 🎉 测试 テスト")
        let bytes = try CanonicalDigest.encode(input)
        XCTAssertFalse(bytes.isEmpty)
        
        // Verify UTF-8 encoding works
        let jsonString = String(data: bytes, encoding: .utf8) ?? ""
        XCTAssertTrue(jsonString.contains("test"), "Must preserve ASCII")
    }
    
    func testStringWithControlCharacters() throws {
        struct TestStruct: Codable {
            let value: String
        }
        
        // Test with control characters (tab, etc.)
        let input = TestStruct(value: "test\ttab")
        let bytes = try CanonicalDigest.encode(input)
        XCTAssertFalse(bytes.isEmpty)
        
        let jsonString = String(data: bytes, encoding: .utf8) ?? ""
        XCTAssertTrue(jsonString.contains("\\t"), "Tabs must be escaped")
    }
    
    // MARK: - Numeric Boundary Tests
    
    func testInt64Min() throws {
        struct TestStruct: Codable {
            let value: Int64
        }
        
        let input = TestStruct(value: Int64.min)
        let bytes = try CanonicalDigest.encode(input)
        XCTAssertFalse(bytes.isEmpty)
        
        let digest = try CanonicalDigest.computeDigest(input)
        XCTAssertFalse(digest.isEmpty)
    }
    
    func testInt64Max() throws {
        struct TestStruct: Codable {
            let value: Int64
        }
        
        let input = TestStruct(value: Int64.max)
        let bytes = try CanonicalDigest.encode(input)
        XCTAssertFalse(bytes.isEmpty)
        
        let digest = try CanonicalDigest.computeDigest(input)
        XCTAssertFalse(digest.isEmpty)
    }
    
    func testInt64BoundaryValues() throws {
        struct TestStruct: Codable {
            let min: Int64
            let max: Int64
            let zero: Int64
            let one: Int64
            let negOne: Int64
        }
        
        let input = TestStruct(
            min: Int64.min,
            max: Int64.max,
            zero: 0,
            one: 1,
            negOne: -1
        )
        
        let digest = try CanonicalDigest.computeDigest(input)
        XCTAssertFalse(digest.isEmpty)
    }
    
    // MARK: - Structural Edge Cases
    
    func testEmptyObject() throws {
        struct EmptyStruct: Codable {}
        
        let input = EmptyStruct()
        let bytes = try CanonicalDigest.encode(input)
        XCTAssertFalse(bytes.isEmpty)
        
        let jsonString = String(data: bytes, encoding: .utf8) ?? ""
        XCTAssertEqual(jsonString, "{}", "Empty object must serialize to {}")
    }
    
    func testEmptyArray() throws {
        struct WithEmptyArray: Codable {
            let items: [Int64]
        }
        
        let input = WithEmptyArray(items: [])
        let bytes = try CanonicalDigest.encode(input)
        XCTAssertFalse(bytes.isEmpty)
        
        let jsonString = String(data: bytes, encoding: .utf8) ?? ""
        XCTAssertTrue(jsonString.contains("[]"), "Empty array must serialize to []")
    }
    
    func testNestedEmptyStructures() throws {
        struct Nested: Codable {
            let inner: [String: Int64]
        }
        struct Outer: Codable {
            let nested: Nested
            let items: [String]
        }
        
        let input = Outer(
            nested: Nested(inner: [:]),
            items: []
        )
        
        let digest = try CanonicalDigest.computeDigest(input)
        XCTAssertFalse(digest.isEmpty)
    }
    
    // MARK: - Key Ordering Tests
    
    func testKeyOrderingShuffled() throws {
        // Test that shuffled keys produce identical output
        struct TestStruct1: Codable {
            let z: Int64
            let a: Int64
            let m: Int64
        }
        
        struct TestStruct2: Codable {
            let a: Int64
            let m: Int64
            let z: Int64
        }
        
        let input1 = TestStruct1(z: 3, a: 1, m: 2)
        let input2 = TestStruct2(a: 1, m: 2, z: 3)
        
        let bytes1 = try CanonicalDigest.encode(input1)
        let bytes2 = try CanonicalDigest.encode(input2)
        
        XCTAssertEqual(bytes1, bytes2, "Shuffled keys must produce identical output")
    }
    
    func testKeyOrderingComplex() throws {
        struct TestStruct: Codable {
            let zzz: Int64
            let aaa: Int64
            let mmm: Int64
            let bbb: Int64
        }
        
        let input = TestStruct(zzz: 4, aaa: 1, mmm: 3, bbb: 2)
        let bytes = try CanonicalDigest.encode(input)
        
        // Verify keys are sorted lexicographically
        let jsonString = String(data: bytes, encoding: .utf8) ?? ""
        let aaaIndex = jsonString.range(of: "\"aaa\"")?.lowerBound
        let bbbIndex = jsonString.range(of: "\"bbb\"")?.lowerBound
        let mmmIndex = jsonString.range(of: "\"mmm\"")?.lowerBound
        let zzzIndex = jsonString.range(of: "\"zzz\"")?.lowerBound
        
        if let aaa = aaaIndex, let bbb = bbbIndex, let mmm = mmmIndex, let zzz = zzzIndex {
            XCTAssertLessThan(aaa, bbb, "Keys must be sorted: aaa < bbb")
            XCTAssertLessThan(bbb, mmm, "Keys must be sorted: bbb < mmm")
            XCTAssertLessThan(mmm, zzz, "Keys must be sorted: mmm < zzz")
        }
    }
    
    // MARK: - CodingPath Accuracy Tests
    
    func testCodingPathInFloatError() throws {
        struct Nested: Codable {
            let value: Double
        }
        struct Outer: Codable {
            let nested: Nested
        }
        
        let input = Outer(nested: Nested(value: 3.14))
        
        XCTAssertThrowsError(try CanonicalDigest.computeDigest(input)) { error in
            if case CanonicalDigestError.floatForbidden(let path, _) = error {
                // Path format may vary, but should contain either "nested" or "value"
                XCTAssertTrue(path.contains("nested") || path.contains("value"),
                            "Path must include 'nested' or 'value', got: \(path)")
            } else {
                XCTFail("Expected floatForbidden error, got: \(error)")
            }
        }
    }
    
    func testCodingPathInNestedArray() throws {
        struct Item: Codable {
            let value: Double
        }
        struct Container: Codable {
            let items: [Item]
        }
        
        let input = Container(items: [Item(value: 3.14)])
        
        XCTAssertThrowsError(try CanonicalDigest.computeDigest(input)) { error in
            if case CanonicalDigestError.floatForbidden(let path, _) = error {
                // Path format may vary, but should contain either "items" or "value"
                XCTAssertTrue(path.contains("items") || path.contains("value"),
                            "Path must include 'items' or 'value', got: \(path)")
            } else {
                XCTFail("Expected floatForbidden error, got: \(error)")
            }
        }
    }
    
    // MARK: - Determinism Extended Tests
    
    func testDeterminismExtended() throws {
        struct ComplexStruct: Codable {
            let a: Int64
            let b: String
            let nested: Nested
            let items: [Int64]
        }
        struct Nested: Codable {
            let inner: String
            let value: Int64
        }
        
        let input = ComplexStruct(
            a: 100,
            b: "test with \"quotes\" and \\backslashes",
            nested: Nested(inner: "nested value", value: 42),
            items: [1, 2, 3, Int64.max, Int64.min]
        )
        
        // Run 50 times
        var previousDigest: String?
        var previousBytes: Data?
        
        for i in 1...50 {
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
