// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// ConstantSpecCoverageTests.swift
// Aether3D
//
// Tests that all constants have structured specs and are registered.
//

import XCTest
@testable import Aether3DCore

final class ConstantSpecCoverageTests: XCTestCase {
    func testAllSystemConstantsHaveSpecs() {
        let specs = SystemConstants.allSpecs
        XCTAssertEqual(specs.count, 3, "Expected 3 system constant specs")
        
        // Verify each constant has a spec
        let maxFramesSpec = specs.first { $0.ssotId == "SystemConstants.maxFrames" }
        XCTAssertNotNil(maxFramesSpec, "maxFrames missing spec")
        
        let minFramesSpec = specs.first { $0.ssotId == "SystemConstants.minFrames" }
        XCTAssertNotNil(minFramesSpec, "minFrames missing spec")
        
        let maxGaussiansSpec = specs.first { $0.ssotId == "SystemConstants.maxGaussians" }
        XCTAssertNotNil(maxGaussiansSpec, "maxGaussians missing spec")
    }
    
    func testAllConversionConstantsHaveSpecs() {
        let specs = ConversionConstants.allSpecs
        XCTAssertEqual(specs.count, 2, "Expected 2 conversion constant specs")
        
        // Verify each constant has a spec
        let bytesPerKBSpec = specs.first { $0.ssotId == "ConversionConstants.bytesPerKB" }
        XCTAssertNotNil(bytesPerKBSpec, "bytesPerKB missing spec")
        
        let bytesPerMBSpec = specs.first { $0.ssotId == "ConversionConstants.bytesPerMB" }
        XCTAssertNotNil(bytesPerMBSpec, "bytesPerMB missing spec")
        
        // Verify they are FixedConstantSpec
        if case .fixedConstant(let spec) = bytesPerKBSpec {
            XCTAssertEqual(spec.value, 1024)
        } else {
            XCTFail("bytesPerKB should be FixedConstantSpec")
        }
        
        if case .fixedConstant(let spec) = bytesPerMBSpec {
            XCTAssertEqual(spec.value, 1048576)
        } else {
            XCTFail("bytesPerMB should be FixedConstantSpec")
        }
    }
    
    func testAllQualityThresholdsHaveSpecs() {
        let specs = QualityThresholds.allSpecs
        XCTAssertEqual(specs.count, 12, "Expected 12 quality threshold specs")

        // Verify core thresholds have specs
        let sfmSpec = specs.first { $0.ssotId == "QualityThresholds.sfmRegistrationMinRatio" }
        XCTAssertNotNil(sfmSpec, "sfmRegistrationMinRatio missing spec")

        let psnrSpec = specs.first { $0.ssotId == "QualityThresholds.psnrMinDb" }
        XCTAssertNotNil(psnrSpec, "psnrMinDb missing spec")

        let psnrWarnSpec = specs.first { $0.ssotId == "QualityThresholds.psnrWarnDb" }
        XCTAssertNotNil(psnrWarnSpec, "psnrWarnDb missing spec")

        // Verify new PR1-01 thresholds have specs
        let psnr8BitSpec = specs.first { $0.ssotId == "QualityThresholds.psnrMin8BitDb" }
        XCTAssertNotNil(psnr8BitSpec, "psnrMin8BitDb missing spec")

        let psnr12BitSpec = specs.first { $0.ssotId == "QualityThresholds.psnrMin12BitDb" }
        XCTAssertNotNil(psnr12BitSpec, "psnrMin12BitDb missing spec")

        let ssimSpec = specs.first { $0.ssotId == "QualityThresholds.ssimMin" }
        XCTAssertNotNil(ssimSpec, "ssimMin missing spec")

        let lpipsSpec = specs.first { $0.ssotId == "QualityThresholds.lpipsMax" }
        XCTAssertNotNil(lpipsSpec, "lpipsMax missing spec")
    }
    
    func testAllSpecsRegisteredInRegistry() {
        let registrySpecs = SSOTRegistry.allConstantSpecs
        let allSpecs = SystemConstants.allSpecs 
            + ConversionConstants.allSpecs 
            + QualityThresholds.allSpecs
            + RetryConstants.allSpecs
            + SamplingConstants.allSpecs
            + FrameQualityConstants.allSpecs
            + ContinuityConstants.allSpecs
            + CoverageVisualizationConstants.allSpecs
            + StorageConstants.allSpecs
        
        XCTAssertEqual(registrySpecs.count, allSpecs.count, "Registry should contain all specs")
        
        // Verify each spec is in registry
        for spec in allSpecs {
            let found = registrySpecs.contains { $0.ssotId == spec.ssotId }
            XCTAssertTrue(found, "Spec \(spec.ssotId) not found in registry")
        }
    }
}

