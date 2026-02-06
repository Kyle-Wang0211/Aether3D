//
//  QualityPreCheckDeterminismTests.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Determinism Tests
//  Validates deterministic serialization contracts (CanonicalJSON, CoverageDelta encoding)
//

import XCTest
@testable import Aether3DCore

final class QualityPreCheckDeterminismTests: XCTestCase {
    
    /// Test CanonicalJSON float formatting: negative zero normalization
    func testCanonicalJSONNegativeZeroNormalization() throws {
        // P23: Negative zero must normalize to "0.000000"
        // Test through AuditRecord which uses CanonicalJSON internally
        let negativeZero: Double = -0.0
        
        let auditRecord = AuditRecord(
            ruleIds: [.WHITE_COMMIT_SUCCESS],
            metricSnapshot: MetricSnapshotMinimal(brightness: negativeZero),
            decisionPathDigest: "test",
            thresholdVersion: "1.0",
            buildGitSha: "test"
        )
        
        let jsonData = try auditRecord.toCanonicalJSONBytes()
        let jsonString = String(data: jsonData, encoding: .utf8) ?? ""
        
        // CanonicalJSON should normalize -0.0 to 0.0
        // Verify the output contains "0.000000" and not "-0.000000"
        XCTAssertTrue(jsonString.contains("0.000000"), "Negative zero must be normalized to '0.000000'")
        XCTAssertFalse(jsonString.contains("-0"), "Negative zero must not appear in canonical JSON output")
    }
    
    /// Test CanonicalJSON float formatting: no scientific notation
    func testCanonicalJSONNoScientificNotation() throws {
        // P23/H1: Scientific notation is forbidden
        // Test with numbers that NumberFormatter might format with scientific notation
        // Use a number that's large but still representable in fixed decimal format
        let testNumbers: [Double] = [999.999999, 1000.0, 9999.999999]
        
        for largeNumber in testNumbers {
            let auditRecord = AuditRecord(
                ruleIds: [.WHITE_COMMIT_SUCCESS],
                metricSnapshot: MetricSnapshotMinimal(brightness: largeNumber),
                decisionPathDigest: "test",
                thresholdVersion: "1.0",
                buildGitSha: "test"
            )
            
            let jsonData = try auditRecord.toCanonicalJSONBytes()
            let jsonString = String(data: jsonData, encoding: .utf8) ?? ""
            
            // Check for scientific notation in number format (e.g., "1.23e10" or "1.23E10")
            // Pattern: digit or decimal point, followed by 'e' or 'E', followed by optional +/- and digits
            // This pattern specifically matches scientific notation in numbers, not "e" in words like "brightness"
            let scientificNotationPattern = #"\d+\.?\d*[eE][+-]?\d+"#
            let range = jsonString.range(of: scientificNotationPattern, options: .regularExpression)
            XCTAssertNil(range, "Scientific notation must not appear in canonical JSON for value \(largeNumber). JSON: \(jsonString)")
            
            // Verify the number appears in decimal format
            // Extract brightness value from JSON and verify it's not scientific notation
            if let brightnessRange = jsonString.range(of: #""brightness":([^,}]+)"#, options: .regularExpression) {
                let brightnessMatch = String(jsonString[brightnessRange])
                // Extract just the numeric value part (after the colon)
                if let valueStart = brightnessMatch.range(of: ":") {
                    let valuePart = String(brightnessMatch[valueStart.upperBound...])
                    // Check if the value part contains scientific notation (digit.eE pattern)
                    let valueHasScientific = valuePart.range(of: scientificNotationPattern, options: .regularExpression) != nil
                    XCTAssertFalse(valueHasScientific, "Brightness value must not use scientific notation. Value: \(valuePart)")
                }
            }
        }
    }
    
    /// Test CanonicalJSON float formatting: fixed 6 decimal places
    func testCanonicalJSONFixedDecimalPlaces() throws {
        // H1: All floats use fixed 6 decimal format
        let testCases: [(Double, String)] = [
            (0.123456, "0.123456"),
            (0.1234565, "0.123457"), // Rounding boundary
            (0.1234564, "0.123456"), // Rounding boundary
        ]
        
        for (input, expected) in testCases {
            let auditRecord = AuditRecord(
                ruleIds: [.WHITE_COMMIT_SUCCESS],
                metricSnapshot: MetricSnapshotMinimal(brightness: input),
                decisionPathDigest: "test",
                thresholdVersion: "1.0",
                buildGitSha: "test"
            )
            
            let jsonData = try auditRecord.toCanonicalJSONBytes()
            let jsonString = String(data: jsonData, encoding: .utf8) ?? ""
            
            // Verify the formatted value appears in the JSON
            XCTAssertTrue(jsonString.contains(expected), "Float \(input) must be formatted as \(expected) in canonical JSON")
        }
    }
    
    /// Test CoverageDelta encoding endianness: all integers are big-endian (v6.0)
    func testCoverageDeltaEndianness() throws {
        // v6.0: All integer fields in CoverageDelta must be BIG-ENDIAN
        // for consistency with CanonicalBinaryCodec and project-wide standards
        // Test case: single cell change
        let delta = CoverageDelta(changes: [
            CoverageDelta.CellChange(cellIndex: 100, newState: 1)
        ])

        let encoded = try delta.encode()

        // Validate structure: changedCount (u32 BE) + cellIndex (u32 BE) + newState (u8)
        XCTAssertGreaterThanOrEqual(encoded.count, 4, "Encoded delta must have at least 4 bytes (changedCount)")

        // Read changedCount (first 4 bytes, big-endian)
        let changedCount = encoded.prefix(4).withUnsafeBytes { bytes in
            UInt32(bigEndian: bytes.load(as: UInt32.self))
        }
        XCTAssertEqual(changedCount, 1, "changedCount must be 1 for single change")

        if encoded.count >= 9 {
            // Read cellIndex (bytes 4-7, big-endian)
            let cellIndex = encoded.subdata(in: 4..<8).withUnsafeBytes { bytes in
                UInt32(bigEndian: bytes.load(as: UInt32.self))
            }
            XCTAssertEqual(cellIndex, 100, "cellIndex must be 100")

            // Read newState (byte 8)
            let newState = encoded[8]
            XCTAssertEqual(newState, 1, "newState must be 1")
        }
    }
    
    /// Test CoverageDelta encoding matches fixture: single_cell_gray (v6.0 BE)
    func testCoverageDeltaMatchesFixtureSingleCellGray() throws {
        // v6.0: Updated to BIG-ENDIAN encoding
        let delta = CoverageDelta(changes: [
            CoverageDelta.CellChange(cellIndex: 100, newState: 1)
        ])

        let encoded = try delta.encode()
        // v6.0 BE: changedCount=1 (00 00 00 01), cellIndex=100 (00 00 00 64), newState=1 (01)
        let expectedHex = "000000010000006401"

        let actualHex = encoded.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(actualHex, expectedHex, "Encoded delta must match fixture expectedBytesHex")

        // Verify SHA256 matches fixture (updated for BE encoding)
        let sha256 = try delta.computeSHA256()
        let expectedSHA256 = "a1b16aec4a00d60afc0dd754d308b2be6f63149b3249632f8190ecf08d783778"
        XCTAssertEqual(sha256, expectedSHA256, "SHA256 must match fixture expectedSHA256")
    }
    
    /// Test CoverageDelta encoding matches fixture: two_cells_mixed (v6.0 BE)
    func testCoverageDeltaMatchesFixtureTwoCellsMixed() throws {
        // v6.0: Updated to BIG-ENDIAN encoding
        // Note: Changes are sorted and deduplicated, so order matters
        let delta = CoverageDelta(changes: [
            CoverageDelta.CellChange(cellIndex: 256, newState: 2),
            CoverageDelta.CellChange(cellIndex: 512, newState: 1)
        ])

        let encoded = try delta.encode()
        // v6.0 BE: changedCount=2 (00 00 00 02), cellIndex=256 (00 00 01 00), newState=2 (02),
        //          cellIndex=512 (00 00 02 00), newState=1 (01)
        let expectedHex = "0000000200000100020000020001"

        let actualHex = encoded.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(actualHex, expectedHex, "Encoded delta must match fixture expectedBytesHex")

        // Verify SHA256 matches fixture (updated for BE encoding)
        let sha256 = try delta.computeSHA256()
        let expectedSHA256 = "0db65f91164be2739cf2c4d6942103603d97e4969ef54aef429920cacc6d04f6"
        XCTAssertEqual(sha256, expectedSHA256, "SHA256 must match fixture expectedSHA256")
    }
    
    /// Test CoverageDelta deduplication: last-write-wins (v6.0 BE)
    func testCoverageDeltaDeduplication() throws {
        // H1: Deduplication uses last-write-wins
        let delta = CoverageDelta(changes: [
            CoverageDelta.CellChange(cellIndex: 100, newState: 1),
            CoverageDelta.CellChange(cellIndex: 100, newState: 2) // Duplicate cellIndex, should keep last (state=2)
        ])

        let encoded = try delta.encode()

        // Should have only one change (deduplicated)
        // v6.0: Read as big-endian
        let changedCount = encoded.prefix(4).withUnsafeBytes { bytes in
            UInt32(bigEndian: bytes.load(as: UInt32.self))
        }
        XCTAssertEqual(changedCount, 1, "Deduplicated delta must have changedCount=1")

        if encoded.count >= 9 {
            let newState = encoded[8]
            XCTAssertEqual(newState, 2, "Last write must win (newState=2)")
        }
    }
}

