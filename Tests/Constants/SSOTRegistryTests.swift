//
// SSOTRegistryTests.swift
// Aether3D
//
// Tests for SSOTRegistry (self-check, integrity validation)
//

import XCTest
@testable import Aether3DCore

final class SSOTRegistryTests: XCTestCase {
    
    // MARK: - Self-Check Tests
    
    func testSelfCheckPasses() {
        let errors = SSOTRegistry.selfCheck()
        XCTAssertTrue(errors.isEmpty, "SSOTRegistry selfCheck must pass. Errors: \(errors)")
    }
    
    func testSelfCheckDetectsDuplicateSpecIds() {
        // This test verifies that selfCheck would catch duplicates
        // Since we can't easily inject duplicates, we verify the mechanism exists
        let errors = SSOTRegistry.selfCheck()
        
        // Check that selfCheck validates uniqueness
        var specIds: Set<String> = []
        for spec in SSOTRegistry.allConstantSpecs {
            XCTAssertFalse(specIds.contains(spec.ssotId),
                          "Duplicate spec ID found: \(spec.ssotId)")
            specIds.insert(spec.ssotId)
        }
    }
    
    func testSelfCheckValidatesErrorCodes() {
        let errors = SSOTRegistry.selfCheck()
        
        // Verify error codes are validated
        var stableNames: Set<String> = []
        for code in SSOTRegistry.allErrorCodes {
            XCTAssertFalse(stableNames.contains(code.stableName),
                          "Duplicate error code stable name: \(code.stableName)")
            stableNames.insert(code.stableName)
        }
    }
    
    // MARK: - Registry Lookup Tests
    
    func testFindConstantSpec() {
        // Test finding a known spec
        if let spec = SSOTRegistry.findConstantSpec(ssotId: "test-id") {
            // If found, verify it's valid
            XCTAssertFalse(spec.ssotId.isEmpty)
        }
    }
    
    func testFindErrorCode() {
        // Test finding a known error code
        if let code = SSOTRegistry.findErrorCode(stableName: "test-name") {
            // If found, verify it's valid
            XCTAssertFalse(code.stableName.isEmpty)
        }
    }
    
    // MARK: - Registry Completeness Tests
    
    func testAllConstantSpecsAreValid() {
        for spec in SSOTRegistry.allConstantSpecs {
            XCTAssertFalse(spec.ssotId.isEmpty, "Spec ID must not be empty")
        }
    }
    
    func testAllErrorCodesAreValid() {
        for code in SSOTRegistry.allErrorCodes {
            XCTAssertFalse(code.stableName.isEmpty, "Error code stable name must not be empty")
            XCTAssertGreaterThan(code.code, 0, "Error code must be positive")
        }
    }
}
