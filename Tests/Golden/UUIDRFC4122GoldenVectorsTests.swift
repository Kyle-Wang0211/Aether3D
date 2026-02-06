//
// UUIDRFC4122GoldenVectorsTests.swift
// Aether3D
//
// PR1 v2.4 Addendum - UUID RFC4122 Golden Vectors Tests (>=128 cases)
//
// Loads fixture and verifies all UUID vectors
//

import XCTest
import Foundation
@testable import Aether3DCore

final class UUIDRFC4122GoldenVectorsTests: XCTestCase {
    /// Test all UUID RFC4122 vectors from fixture (>=128 cases)
    func testUUIDRFC4122_AllGoldenVectors() throws {
        let fixturePath = try findFixturePath("uuid_rfc4122_vectors_v1.txt")
        let content = try String(contentsOf: fixturePath, encoding: .utf8)
        let vectors = try parseFixtureFile(content)
        
        var checks = 0
        var caseNum = 1
        
        // Process all UUID vectors
        while true {
            guard let uuidString = vectors["UUID_STRING_\(caseNum)"],
                  let expectedHex = vectors["EXPECTED_BYTES_HEX_\(caseNum)"] else {
                break
            }
            
            // Parse UUID
            guard let uuid = UUID(uuidString: uuidString) else {
                XCTFail("Invalid UUID string: \(uuidString)")
                caseNum += 1
                continue
            }
            
            // Compute RFC4122 bytes
            let actualBytes = try UUIDRFC4122.uuidRFC4122Bytes(uuid)
            let expectedBytes = try hexStringToBytes(expectedHex)
            
            // Verify length
            CheckCounter.increment()
            checks += 1
            XCTAssertEqual(actualBytes.count, 16, "UUID RFC4122 must be exactly 16 bytes")
            
            // Verify bytes match
            CheckCounter.increment()
            checks += 1
            XCTAssertEqual(actualBytes, expectedBytes, "UUID RFC4122 bytes must match expected for case \(caseNum)")
            
            // Verify cross-platform consistency (run twice)
            let actualBytes2 = try UUIDRFC4122.uuidRFC4122Bytes(uuid)
            CheckCounter.increment()
            checks += 1
            XCTAssertEqual(actualBytes, actualBytes2, "UUID RFC4122 must be deterministic")
            
            caseNum += 1
        }
        
        // Verify we got at least 128 cases
        CheckCounter.increment()
        checks += 1
        XCTAssertGreaterThanOrEqual(caseNum - 1, 128, "Must have at least 128 UUID test cases")
        
        print("UUID RFC4122 Golden Vectors: \(caseNum - 1) cases, \(checks) checks")
    }
    
    /// Helper: Find fixture path
    private func findFixturePath(_ filename: String) throws -> URL {
        let possiblePaths = [
            Bundle.module.path(forResource: filename.replacingOccurrences(of: ".txt", with: ""), ofType: "txt", inDirectory: "Fixtures"),
            Bundle.module.path(forResource: filename.replacingOccurrences(of: ".txt", with: ""), ofType: "txt"),
            #file.replacingOccurrences(of: "UUIDRFC4122GoldenVectorsTests.swift", with: "../Fixtures/\(filename)")
        ]
        
        for path in possiblePaths {
            if let path = path, FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        
        // Try relative to project root
        var currentDir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        while currentDir.path != "/" {
            let fixturePath = currentDir.appendingPathComponent("Fixtures/\(filename)")
            if FileManager.default.fileExists(atPath: fixturePath.path) {
                return fixturePath
            }
            currentDir = currentDir.deletingLastPathComponent()
        }
        
        throw NSError(domain: "UUIDRFC4122GoldenVectorsTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Fixture file not found: \(filename)"])
    }
    
    /// Helper: Parse fixture file (KEY=VALUE format)
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
                throw NSError(domain: "UUIDRFC4122GoldenVectorsTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid hex string"])
            }
            bytes.append(byte)
            index = nextIndex
        }
        
        return bytes
    }
}
