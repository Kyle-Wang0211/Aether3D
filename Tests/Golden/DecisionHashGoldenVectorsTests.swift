// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// DecisionHashGoldenVectorsTests.swift
// Aether3D
//
// PR1 v2.4 Addendum - DecisionHash Golden Vectors Tests (>=128 cases)
//
// Loads fixture and verifies all DecisionHash vectors
//

import XCTest
import Foundation
@testable import Aether3DCore

final class DecisionHashGoldenVectorsTests: XCTestCase {
    /// Test all DecisionHash vectors from fixture (>=128 cases)
    func testDecisionHash_AllGoldenVectors() throws {
        let fixturePath = try findFixturePath("decision_hash_v1.txt")
        let content = try String(contentsOf: fixturePath, encoding: .utf8)
        let vectors = try parseFixtureFile(content)
        
        var checks = 0
        var caseNum = 1
        
        // Process all DecisionHash vectors
        while true {
            guard let canonicalInputHex = vectors["CANONICAL_INPUT_HEX_\(caseNum)"],
                  let expectedHashHex = vectors["EXPECTED_DECISION_HASH_HEX_\(caseNum)"] else {
                break
            }
            
            // Parse canonical input bytes
            let canonicalInputBytes = try hexStringToBytes(canonicalInputHex)
            let canonicalInputData = Data(canonicalInputBytes)
            
            // Compute DecisionHash
            let decisionHash = try DecisionHashV1.compute(from: canonicalInputData)
            let expectedHash = try hexStringToBytes(expectedHashHex)
            
            // Verify length
            CheckCounter.increment()
            checks += 1
            XCTAssertEqual(decisionHash.bytes.count, 32, "DecisionHash must be exactly 32 bytes")
            
            // Verify hash matches
            CheckCounter.increment()
            checks += 1
            XCTAssertEqual(decisionHash.bytes, expectedHash, "DecisionHash must match expected for case \(caseNum)")
            
            // Verify deterministic (run twice)
            let decisionHash2 = try DecisionHashV1.compute(from: canonicalInputData)
            CheckCounter.increment()
            checks += 1
            XCTAssertEqual(decisionHash.bytes, decisionHash2.bytes, "DecisionHash must be deterministic")
            
            // Verify hex string format
            CheckCounter.increment()
            checks += 1
            XCTAssertEqual(decisionHash.hexString.count, 64, "DecisionHash hex must be 64 characters")
            XCTAssertEqual(decisionHash.hexString.lowercased(), decisionHash.hexString, "DecisionHash hex must be lowercase")
            
            caseNum += 1
        }
        
        // Verify we got at least 128 cases
        CheckCounter.increment()
        checks += 1
        XCTAssertGreaterThanOrEqual(caseNum - 1, 128, "Must have at least 128 DecisionHash test cases")
        
        print("DecisionHash Golden Vectors: \(caseNum - 1) cases, \(checks) checks")
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
        throw NSError(domain: "DecisionHashGoldenVectorsTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Fixture file not found: \(filename)"])
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
                throw NSError(domain: "DecisionHashGoldenVectorsTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid hex string"])
            }
            bytes.append(byte)
            index = nextIndex
        }
        return bytes
    }
}
