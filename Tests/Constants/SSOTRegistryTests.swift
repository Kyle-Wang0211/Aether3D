//
// SSOTRegistryTests.swift
// Aether3D
//
// Tests for SSOTRegistry completeness and validity.
//

import XCTest
@testable import Aether3DCore

final class SSOTRegistryTests: XCTestCase {
    func testRegistrySelfCheckPasses() {
        let errors = SSOTRegistry.selfCheck()
        XCTAssertTrue(errors.isEmpty, "Registry self-check failed: \(errors.joined(separator: "; "))")
    }
    
    func testAllConstantSpecsRegistered() {
        let registrySpecs = SSOTRegistry.allConstantSpecs
        let systemSpecs = SystemConstants.allSpecs
        let conversionSpecs = ConversionConstants.allSpecs
        let qualitySpecs = QualityThresholds.allSpecs
        let retrySpecs = RetryConstants.allSpecs
        let samplingSpecs = SamplingConstants.allSpecs
        let frameQualitySpecs = FrameQualityConstants.allSpecs
        let continuitySpecs = ContinuityConstants.allSpecs
        let coverageSpecs = CoverageVisualizationConstants.allSpecs
        let storageSpecs = StorageConstants.allSpecs
        
        let expectedCount = systemSpecs.count + conversionSpecs.count + qualitySpecs.count
            + retrySpecs.count + samplingSpecs.count + frameQualitySpecs.count
            + continuitySpecs.count + coverageSpecs.count + storageSpecs.count
        XCTAssertEqual(registrySpecs.count, expectedCount, "Registry should contain all specs")
    }
    
    func testFindConstantSpec() {
        let spec = SSOTRegistry.findConstantSpec(ssotId: "SystemConstants.maxFrames")
        XCTAssertNotNil(spec, "Should find maxFrames spec")
        
        if case .systemConstant(let s) = spec {
            XCTAssertEqual(s.value, 5000)
        } else {
            XCTFail("maxFrames should be SystemConstantSpec")
        }
    }
    
    func testFindErrorCodeByStableName() {
        let code = SSOTRegistry.findErrorCode(stableName: "SSOT_INVALID_SPEC")
        XCTAssertNotNil(code, "Should find error code by stable name")
        XCTAssertEqual(code?.code, 1000)
    }
    
    func testFindErrorCodeByDomainAndCode() {
        let code = SSOTRegistry.findErrorCode(domain: "SSOT", code: 1000)
        XCTAssertNotNil(code, "Should find error code by domain and code")
        XCTAssertEqual(code?.stableName, "SSOT_INVALID_SPEC")
    }
    
    func testRegistryNoDuplicates() {
        let specs = SSOTRegistry.allConstantSpecs
        var seenIds: Set<String> = []
        
        for spec in specs {
            XCTAssertFalse(seenIds.contains(spec.ssotId), "Duplicate spec ID: \(spec.ssotId)")
            seenIds.insert(spec.ssotId)
        }
        
        let codes = SSOTRegistry.allErrorCodes
        var seenStableNames: Set<String> = []
        
        for code in codes {
            XCTAssertFalse(seenStableNames.contains(code.stableName), "Duplicate stable name: \(code.stableName)")
            seenStableNames.insert(code.stableName)
        }
    }
}

