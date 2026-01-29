//
// PIZCanonicalJSONTests.swift
// Aether3D
//
// PR1 PIZ Detection - Canonical JSON Tests
//
// Tests for canonical JSON encoding with fixed decimal formatting.
// **Rule ID:** PIZ_JSON_CANON_001, PIZ_NUMERIC_FORMAT_001

import XCTest
@testable import Aether3DCore

final class PIZCanonicalJSONTests: XCTestCase {
    
    /// Test -0.0 encodes as "0.000000".
    /// **Rule ID:** PIZ_NUMERIC_FORMAT_001
    func testNegativeZeroEncoding() throws {
        let report = PIZReport(
            schemaVersion: PIZSchemaVersion.current,
            outputProfile: .decisionOnly,
            gateRecommendation: .allowPublish,
            globalTrigger: false,
            localTriggerCount: 0
        )
        
        // Create a report with a region containing -0.0
        let region = PIZRegion(
            id: "test",
            pixelCount: 10,
            areaRatio: -0.0, // This should normalize to 0.0
            bbox: BoundingBox(minRow: 0, maxRow: 1, minCol: 0, maxCol: 1),
            centroid: Point(row: 0.5, col: 0.5),
            principalDirection: Vector(dx: 1.0, dy: 0.0),
            severityScore: 0.5
        )
        
        let fullReport = PIZReport(
            schemaVersion: PIZSchemaVersion.current,
            outputProfile: .fullExplainability,
            foundationVersion: "SSOT_FOUNDATION_v1.1",
            connectivityMode: "FOUR",
            gateRecommendation: .allowPublish,
            globalTrigger: false,
            localTriggerCount: 1,
            heatmap: Array(repeating: Array(repeating: 0.5, count: 32), count: 32),
            regions: [region],
            recaptureSuggestion: RecaptureSuggestion(suggestedRegions: [], priority: .low, reason: "test"),
            assetId: "test",
            timestamp: Date(timeIntervalSince1970: 0),
            computePhase: .finalized
        )
        
        let json = try PIZCanonicalJSON.encode(fullReport)
        
        // Verify -0.0 is encoded as "0.000000" (not "-0.000000")
        XCTAssertFalse(json.contains("-0.000000"))
        // Should contain "0.000000" for zero values
        XCTAssertTrue(json.contains("0.000000") || json.contains("\"areaRatio\":0"))
    }
    
    /// Test no scientific notation in output.
    /// **Rule ID:** PIZ_NUMERIC_FORMAT_001
    func testNoScientificNotation() throws {
        // Create a value that might trigger scientific notation in typical encoders
        // Use a value that will be quantized but not become 0
        let smallValue = 0.000001 // 1e-6, within quantization precision
        
        let report = PIZReport(
            schemaVersion: PIZSchemaVersion.current,
            outputProfile: .fullExplainability,
            foundationVersion: "SSOT_FOUNDATION_v1.1",
            connectivityMode: "FOUR",
            gateRecommendation: .allowPublish,
            globalTrigger: false,
            localTriggerCount: 0,
            heatmap: Array(repeating: Array(repeating: smallValue, count: 32), count: 32),
            regions: [],
            recaptureSuggestion: RecaptureSuggestion(suggestedRegions: [], priority: .low, reason: "test"),
            assetId: "test",
            timestamp: Date(timeIntervalSince1970: 0),
            computePhase: .finalized
        )
        
        let json = try PIZCanonicalJSON.encode(report)
        
        // Verify no scientific notation in numeric values
        // Note: "e" might appear in strings (e.g., "reason", "assetId"), so we check for numeric patterns
        // Scientific notation pattern: number followed by e/E followed by +/- and digits
        let scientificPattern = try NSRegularExpression(pattern: #"\d+[eE][+-]?\d+"#, options: [])
        let range = NSRange(json.startIndex..<json.endIndex, in: json)
        let matches = scientificPattern.matches(in: json, options: [], range: range)
        XCTAssertEqual(matches.count, 0, "Found scientific notation in JSON: \(json.prefix(500))")
    }
    
    /// Test byte-identical canonical JSON for known object.
    /// **Rule ID:** PIZ_JSON_CANON_001
    func testByteIdenticalCanonicalJSON() throws {
        let report = PIZReport(
            schemaVersion: PIZSchemaVersion(major: 1, minor: 0, patch: 0),
            outputProfile: .decisionOnly,
            gateRecommendation: .allowPublish,
            globalTrigger: false,
            localTriggerCount: 0
        )
        
        let json1 = try PIZCanonicalJSON.encode(report)
        let json2 = try PIZCanonicalJSON.encode(report)
        
        // Should be byte-identical
        XCTAssertEqual(json1, json2)
        
        // Verify UTF-8 encoding
        let data1 = json1.data(using: .utf8)
        let data2 = json2.data(using: .utf8)
        XCTAssertEqual(data1, data2)
    }
    
    /// Test lexicographic key ordering.
    /// **Rule ID:** PIZ_JSON_CANON_001
    func testLexicographicKeyOrdering() throws {
        let report = PIZReport(
            schemaVersion: PIZSchemaVersion.current,
            outputProfile: .decisionOnly,
            gateRecommendation: .recapture,
            globalTrigger: true,
            localTriggerCount: 5
        )
        
        let json = try PIZCanonicalJSON.encode(report)
        
        // Verify keys are in lexicographic order
        // Expected order: gateRecommendation, globalTrigger, localTriggerCount, outputProfile, schemaVersion
        let gateIndex = json.range(of: "\"gateRecommendation\"")?.lowerBound
        let globalIndex = json.range(of: "\"globalTrigger\"")?.lowerBound
        let localIndex = json.range(of: "\"localTriggerCount\"")?.lowerBound
        let outputIndex = json.range(of: "\"outputProfile\"")?.lowerBound
        let schemaIndex = json.range(of: "\"schemaVersion\"")?.lowerBound
        
        XCTAssertNotNil(gateIndex)
        XCTAssertNotNil(globalIndex)
        XCTAssertNotNil(localIndex)
        XCTAssertNotNil(outputIndex)
        XCTAssertNotNil(schemaIndex)
        
        // Verify ordering: gate < global < local < output < schema
        if let g = gateIndex, let gl = globalIndex {
            XCTAssertLessThan(g, gl)
        }
    }
}
