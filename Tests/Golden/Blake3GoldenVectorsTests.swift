// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// Blake3GoldenVectorsTests.swift
// Aether3D
//
// PR1 v2.4 Addendum - BLAKE3 Golden Vectors Tests (>=128 cases)
//
// Loads fixture and verifies all BLAKE3 vectors
//

import XCTest
import Foundation
@testable import Aether3DCore

final class Blake3GoldenVectorsTests: XCTestCase {
    /// Test all BLAKE3 vectors from fixture (>=128 cases)
    func testBlake3_AllGoldenVectors() throws {
        let fixturePath = try findFixturePath("blake3_vectors_v1.txt")
        let content = try String(contentsOf: fixturePath, encoding: .utf8)
        let vectors = try parseFixtureFile(content)
        
        var checks = 0
        var caseNum = 1
        
        // Process all BLAKE3 vectors
        while true {
            guard let inputHex = vectors["INPUT_HEX_\(caseNum)"],
                  let expectedHashHex = vectors["EXPECTED_HASH_HEX_\(caseNum)"] else {
                break
            }
            
            // Parse input bytes
            let inputBytes = try hexStringToBytes(inputHex)
            let inputData = Data(inputBytes)
            
            // Compute BLAKE3-256
            let actualHash = try Blake3Facade.blake3_256(data: inputData)
            let expectedHash = try hexStringToBytes(expectedHashHex)
            
            // Verify length
            CheckCounter.increment()
            checks += 1
            XCTAssertEqual(actualHash.count, 32, "BLAKE3-256 must be exactly 32 bytes")
            
            // Verify hash matches
            CheckCounter.increment()
            checks += 1
            XCTAssertEqual(actualHash, expectedHash, "BLAKE3-256 must match expected for case \(caseNum)")
            
            // Verify deterministic (run twice)
            let actualHash2 = try Blake3Facade.blake3_256(data: inputData)
            CheckCounter.increment()
            checks += 1
            XCTAssertEqual(actualHash, actualHash2, "BLAKE3-256 must be deterministic")
            
            caseNum += 1
        }
        
        // Verify we got at least 128 cases
        CheckCounter.increment()
        checks += 1
        XCTAssertGreaterThanOrEqual(caseNum - 1, 128, "Must have at least 128 BLAKE3 test cases")
        
        print("BLAKE3 Golden Vectors: \(caseNum - 1) cases, \(checks) checks")
    }
    
    /// Helper: Find fixture path
    private func findFixturePath(_ filename: String) throws -> URL {
        var currentDir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        while currentDir.path != "/" {
            let fixturePath = currentDir.appendingPathComponent("Fixtures/\(filename)")
            if FileManager.default.fileExists(atPath: fixturePath.path) {
                return fixturePath
            }
            currentDir = currentDir.deletingLastPathComponent()
        }
        throw NSError(domain: "Blake3GoldenVectorsTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Fixture file not found: \(filename)"])
    }
    
    /// Helper: Parse fixture file
    private func parseFixtureFile(_ content: String) throws -> [String: String] {
        var vectors: [String: String] = [:]
        let lines = content.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }
            let parts = trimmed.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                vectors[String(parts[0])] = String(parts[1])
            }
        }
        return vectors
    }
    
    /// Helper: Convert hex string to bytes
    private func hexStringToBytes(_ hex: String) throws -> [UInt8] {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else {
                throw NSError(domain: "Blake3GoldenVectorsTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid hex string"])
            }
            bytes.append(byte)
            index = nextIndex
        }
        return bytes
    }
}
