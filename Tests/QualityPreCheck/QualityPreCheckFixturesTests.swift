// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  QualityPreCheckFixturesTests.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Fixture Tests
//  Validates fixture JSON files are parseable and contain expected structure
//

import XCTest
@testable import Aether3DCore

final class QualityPreCheckFixturesTests: XCTestCase {
    
    /// Test that CoverageDeltaEndiannessFixture.json is valid JSON and contains expected structure
    func testCoverageDeltaEndiannessFixture() throws {
        let fixtureURL = resolveFixtureURL(named: "CoverageDeltaEndiannessFixture")
        
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            XCTFail("CoverageDeltaEndiannessFixture.json not found at \(fixtureURL.path)")
            return
        }
        
        let data = try Data(contentsOf: fixtureURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        
        XCTAssertNotNil(json, "Fixture must be valid JSON")
        
        guard let testCases = json?["testCases"] as? [[String: Any]] else {
            XCTFail("Fixture must contain 'testCases' array")
            return
        }
        
        XCTAssertGreaterThan(testCases.count, 0, "Fixture must contain at least one test case")
        
        for testCase in testCases {
            // Validate test case structure
            XCTAssertNotNil(testCase["name"] as? String, "Test case must have 'name'")
            XCTAssertNotNil(testCase["input"] as? [String: Any], "Test case must have 'input'")
            XCTAssertNotNil(testCase["expectedBytesHex"] as? String, "Test case must have 'expectedBytesHex'")
            XCTAssertNotNil(testCase["expectedSHA256"] as? String, "Test case must have 'expectedSHA256'")
            
            // Validate expectedBytesHex: must be even length (hex pairs)
            if let expectedBytesHex = testCase["expectedBytesHex"] as? String {
                XCTAssertEqual(expectedBytesHex.count % 2, 0, "expectedBytesHex must have even length (hex pairs)")
                XCTAssertTrue(expectedBytesHex.allSatisfy { $0.isHexDigit }, "expectedBytesHex must contain only hex digits")
            }
            
            // Validate expectedSHA256: must be exactly 64 hex characters
            if let expectedSHA256 = testCase["expectedSHA256"] as? String {
                XCTAssertEqual(expectedSHA256.count, 64, "expectedSHA256 must be exactly 64 hex characters")
                XCTAssertTrue(expectedSHA256.allSatisfy { $0.isHexDigit }, "expectedSHA256 must contain only hex digits")
            }
        }
    }
    
    /// Test that CanonicalJSONFloatFixture.json is valid JSON and contains expected structure
    func testCanonicalJSONFloatFixture() throws {
        let fixtureURL = resolveFixtureURL(named: "CanonicalJSONFloatFixture")
        
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            XCTFail("CanonicalJSONFloatFixture.json not found at \(fixtureURL.path)")
            return
        }
        
        let data = try Data(contentsOf: fixtureURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        
        XCTAssertNotNil(json, "Fixture must be valid JSON")
        
        guard let testCases = json?["testCases"] as? [[String: Any]] else {
            XCTFail("Fixture must contain 'testCases' array")
            return
        }
        
        XCTAssertGreaterThan(testCases.count, 0, "Fixture must contain at least one test case")
        
        for testCase in testCases {
            // Validate test case structure
            XCTAssertNotNil(testCase["name"] as? String, "Test case must have 'name'")
            
            // Must have either 'input' + 'expected' OR 'shouldReject' + 'rejectReason'
            if testCase["shouldReject"] as? Bool == true {
                XCTAssertNotNil(testCase["rejectReason"] as? String, "Rejection test case must have 'rejectReason'")
            } else {
                XCTAssertNotNil(testCase["input"], "Test case must have 'input'")
                XCTAssertNotNil(testCase["expected"] as? String, "Test case must have 'expected' string")
            }
        }
    }
    
    /// Test that CoverageGridPackingFixture.json is valid JSON and contains expected structure
    func testCoverageGridPackingFixture() throws {
        let fixtureURL = resolveFixtureURL(named: "CoverageGridPackingFixture")
        
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            XCTFail("CoverageGridPackingFixture.json not found at \(fixtureURL.path)")
            return
        }
        
        let data = try Data(contentsOf: fixtureURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        
        XCTAssertNotNil(json, "Fixture must be valid JSON")
        
        guard let testCases = json?["testCases"] as? [[String: Any]] else {
            XCTFail("Fixture must contain 'testCases' array")
            return
        }
        
        XCTAssertGreaterThan(testCases.count, 0, "Fixture must contain at least one test case")
        
        for testCase in testCases {
            // Validate test case structure
            XCTAssertNotNil(testCase["name"] as? String, "Test case must have 'name'")
            XCTAssertNotNil(testCase["input"] as? [String: Any], "Test case must have 'input'")
            XCTAssertNotNil(testCase["expectedBytesHex"] as? String, "Test case must have 'expectedBytesHex'")
            XCTAssertNotNil(testCase["expectedSHA256"] as? String, "Test case must have 'expectedSHA256'")
            
            // Validate expectedBytesHex: must be even length (hex pairs)
            if let expectedBytesHex = testCase["expectedBytesHex"] as? String {
                XCTAssertEqual(expectedBytesHex.count % 2, 0, "expectedBytesHex must have even length (hex pairs)")
                XCTAssertTrue(expectedBytesHex.allSatisfy { $0.isHexDigit }, "expectedBytesHex must contain only hex digits")
            }
            
            // Validate expectedSHA256: must be exactly 64 hex characters
            if let expectedSHA256 = testCase["expectedSHA256"] as? String {
                XCTAssertEqual(expectedSHA256.count, 64, "expectedSHA256 must be exactly 64 hex characters")
                XCTAssertTrue(expectedSHA256.allSatisfy { $0.isHexDigit }, "expectedSHA256 must contain only hex digits")
            }
        }
    }

    private func resolveFixtureURL(named fixtureName: String) -> URL {
        let fileName = "\(fixtureName).json"
        let fileManager = FileManager.default

        let moduleCandidates = [
            Bundle.module.url(forResource: fixtureName, withExtension: "json", subdirectory: "QualityPreCheck/Fixtures"),
            Bundle.module.url(forResource: fixtureName, withExtension: "json", subdirectory: "Fixtures"),
            Bundle.module.url(forResource: fixtureName, withExtension: "json")
        ].compactMap { $0 }

        if let found = moduleCandidates.first(where: { fileManager.fileExists(atPath: $0.path) }) {
            return found
        }

        let testBundle = Bundle(for: type(of: self))
        let bundleCandidates = [
            testBundle.url(forResource: fixtureName, withExtension: "json", subdirectory: "QualityPreCheck/Fixtures"),
            testBundle.url(forResource: fixtureName, withExtension: "json", subdirectory: "Fixtures"),
            testBundle.url(forResource: fixtureName, withExtension: "json")
        ].compactMap { $0 }

        if let found = bundleCandidates.first(where: { fileManager.fileExists(atPath: $0.path) }) {
            return found
        }

        let sourceDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        let directCandidates = [
            sourceDir.appendingPathComponent("Fixtures/\(fileName)"),
            cwd.appendingPathComponent("Tests/QualityPreCheck/Fixtures/\(fileName)"),
            cwd.appendingPathComponent("QualityPreCheck/Fixtures/\(fileName)"),
            cwd.deletingLastPathComponent().appendingPathComponent("Tests/QualityPreCheck/Fixtures/\(fileName)")
        ]

        return directCandidates.first(where: { fileManager.fileExists(atPath: $0.path) }) ?? directCandidates[0]
    }
}

// Note: isHexDigit extension is defined in Tests/Support/FixtureLoader.swift

