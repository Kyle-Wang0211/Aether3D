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
        // Try Bundle.module first (SwiftPM resources), fallback to direct file path
        let fixtureURL: URL
        if let bundleURL = Bundle.module.url(forResource: "CoverageDeltaEndiannessFixture", withExtension: "json", subdirectory: "QualityPreCheck/Fixtures") {
            fixtureURL = bundleURL
        } else if let directURL = Bundle(for: type(of: self)).url(forResource: "CoverageDeltaEndiannessFixture", withExtension: "json", subdirectory: "QualityPreCheck/Fixtures") {
            fixtureURL = directURL
        } else {
            // Fallback: construct path relative to test file
            let testFileURL = URL(fileURLWithPath: #file)
            let testDir = testFileURL.deletingLastPathComponent()
            fixtureURL = testDir.appendingPathComponent("Fixtures/CoverageDeltaEndiannessFixture.json")
        }
        
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
        // Try Bundle.module first (SwiftPM resources), fallback to direct file path
        let fixtureURL: URL
        if let bundleURL = Bundle.module.url(forResource: "CanonicalJSONFloatFixture", withExtension: "json", subdirectory: "QualityPreCheck/Fixtures") {
            fixtureURL = bundleURL
        } else if let directURL = Bundle(for: type(of: self)).url(forResource: "CanonicalJSONFloatFixture", withExtension: "json", subdirectory: "QualityPreCheck/Fixtures") {
            fixtureURL = directURL
        } else {
            // Fallback: construct path relative to test file
            let testFileURL = URL(fileURLWithPath: #file)
            let testDir = testFileURL.deletingLastPathComponent()
            fixtureURL = testDir.appendingPathComponent("Fixtures/CanonicalJSONFloatFixture.json")
        }
        
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
        // Try Bundle.module first (SwiftPM resources), fallback to direct file path
        let fixtureURL: URL
        if let bundleURL = Bundle.module.url(forResource: "CoverageGridPackingFixture", withExtension: "json", subdirectory: "QualityPreCheck/Fixtures") {
            fixtureURL = bundleURL
        } else if let directURL = Bundle(for: type(of: self)).url(forResource: "CoverageGridPackingFixture", withExtension: "json", subdirectory: "QualityPreCheck/Fixtures") {
            fixtureURL = directURL
        } else {
            // Fallback: construct path relative to test file
            let testFileURL = URL(fileURLWithPath: #file)
            let testDir = testFileURL.deletingLastPathComponent()
            fixtureURL = testDir.appendingPathComponent("Fixtures/CoverageGridPackingFixture.json")
        }
        
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
}

extension Character {
    var isHexDigit: Bool {
        return ("0"..."9").contains(self) || ("a"..."f").contains(self) || ("A"..."F").contains(self)
    }
}

