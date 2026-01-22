//
// ErrorCodesCoverageTests.swift
// Aether3D
//
// Tests for error code uniqueness, completeness, and validity.
//

import XCTest
@testable import Aether3DCore

final class ErrorCodesCoverageTests: XCTestCase {
    func testAllErrorCodesUnique() {
        let codes = ErrorCodes.all
        
        // Check stable name uniqueness
        var stableNames: Set<String> = []
        for code in codes {
            XCTAssertFalse(stableNames.contains(code.stableName), "Duplicate stable name: \(code.stableName)")
            stableNames.insert(code.stableName)
        }
        
        // Check domain:code uniqueness
        var codeKeys: Set<String> = []
        for code in codes {
            let key = "\(code.domain.id):\(code.code)"
            XCTAssertFalse(codeKeys.contains(key), "Duplicate error code: \(key)")
            codeKeys.insert(key)
        }
    }
    
    func testAllErrorCodesValid() {
        let codes = ErrorCodes.all
        
        for code in codes {
            let errors = code.validate()
            XCTAssertTrue(errors.isEmpty, "Error code \(code.stableName) validation failed: \(errors.joined(separator: "; "))")
        }
    }
    
    func testErrorCodesInDomainRanges() {
        let codes = ErrorCodes.all
        
        for code in codes {
            XCTAssertTrue(
                code.domain.codeRange.contains(code.code),
                "Error code \(code.code) not in domain range \(code.domain.codeRange)"
            )
        }
    }
    
    func testErrorCodesHaveStableNamePrefix() {
        let codes = ErrorCodes.all
        
        for code in codes {
            XCTAssertTrue(
                code.stableName.hasPrefix(code.domain.stableNamePrefix),
                "Error code \(code.stableName) does not start with domain prefix \(code.domain.stableNamePrefix)"
            )
        }
    }
}

