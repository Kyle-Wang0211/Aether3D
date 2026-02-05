//
// UUIDRFC4122GoldenTests_iOS.swift
// Aether3D
//
// PR1 v2.4 Addendum - iOS Golden Tests for UUID RFC4122
//
// Cross-platform golden tests that run on iOS Simulator
//

import XCTest
@testable import Aether3DCore

final class UUIDRFC4122GoldenTests_iOS: XCTestCase {
    /// Test UUID RFC4122 bytes match fixtures (iOS)
    func testUUIDRFC4122_GoldenVectors_iOS() throws {
        #if os(iOS) || os(watchOS) || os(tvOS)
        // Load fixtures from bundle
        let bundle = Bundle(for: type(of: self))
        let fixtureLines = try FixtureLoader.loadFixtureFromBundle(
            bundle: bundle,
            name: "uuid_rfc4122_vectors_v1",
            extension: "txt"
        )
        
        // Parse and verify (subset for iOS - first 32 vectors)
        var checks = 0
        for (index, line) in fixtureLines.prefix(64).enumerated() {
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }
            
            if line.starts(with: "UUID_STRING_") {
                let uuidString = String(line.split(separator: "=", maxSplits: 1)[1])
                guard let uuid = UUID(uuidString: uuidString) else {
                    XCTFail("Invalid UUID string: \(uuidString)")
                    continue
                }
                
                // Find corresponding EXPECTED_BYTES_HEX line
                if index + 1 < fixtureLines.count {
                    let expectedLine = fixtureLines[index + 1]
                    if expectedLine.starts(with: "EXPECTED_BYTES_HEX_") {
                        let expectedHex = String(expectedLine.split(separator: "=", maxSplits: 1)[1])
                        let expectedBytes = try hexStringToBytes(expectedHex)
                        
                        // Compute actual bytes
                        let actualBytes = try UUIDRFC4122.uuidRFC4122Bytes(uuid)
                        
                        // Verify
                        XCTAssertEqual(actualBytes.count, 16, "UUID must be 16 bytes")
                        XCTAssertEqual(actualBytes, expectedBytes, "UUID bytes must match fixture")
                        checks += 1
                    }
                }
            }
        }
        
        XCTAssertGreaterThan(checks, 0, "Must verify at least one UUID vector")
        #else
        throw XCTSkip("iOS test skipped on non-iOS platform")
        #endif
    }
    
    private func hexStringToBytes(_ hex: String) throws -> [UInt8] {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else {
                throw NSError(domain: "FixtureLoader", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid hex"])
            }
            bytes.append(byte)
            index = nextIndex
        }
        return bytes
    }
}
