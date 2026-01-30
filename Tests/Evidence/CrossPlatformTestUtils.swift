//
// CrossPlatformTestUtils.swift
// Aether3D
//
// PR2 Patch V4 - Cross-Platform Test Utilities
// Stable comparisons for deterministic testing
//

import XCTest
@testable import Aether3DCore

/// Test utilities for cross-platform consistency
public enum CrossPlatformTestUtils {
    
    /// Compare dictionaries with deterministic ordering
    public static func assertDictionariesEqual<K: Comparable, V: Equatable>(
        _ dict1: [K: V],
        _ dict2: [K: V],
        file: StaticString = #file,
        line: UInt = #line
    ) {
        let keys1 = dict1.keys.sorted()
        let keys2 = dict2.keys.sorted()
        
        XCTAssertEqual(keys1, keys2, "Keys mismatch", file: file, line: line)
        
        for key in keys1 {
            XCTAssertEqual(dict1[key], dict2[key], "Value mismatch for key \(key)", file: file, line: line)
        }
    }
    
    /// Assert JSON encoding is deterministic
    public static func assertDeterministicJSON<T: Encodable>(
        _ value: T,
        iterations: Int = 100,
        file: StaticString = #file,
        line: UInt = #line
    ) throws {
        var outputs: Set<Data> = []
        
        for _ in 0..<iterations {
            let data = try TrueDeterministicJSONEncoder.encode(value)
            outputs.insert(data)
        }
        
        XCTAssertEqual(
            outputs.count, 1,
            "JSON encoding produced \(outputs.count) different outputs",
            file: file, line: line
        )
    }
    
    /// Assert patch order in array (for tests that iterate)
    public static func sortedPatches(_ patches: [String: PatchEntrySnapshot]) -> [(String, PatchEntrySnapshot)] {
        return patches.sorted { $0.key < $1.key }
    }
}
