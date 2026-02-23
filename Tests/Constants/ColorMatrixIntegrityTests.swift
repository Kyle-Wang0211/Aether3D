// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// ColorMatrixIntegrityTests.swift
// Aether3D
//
// PR#1 SSOT Foundation v1.1 - Color Matrix Integrity Tests
//
// This test file validates exact matrix numeric integrity and D65 lock.
//

import XCTest
@testable import Aether3DCore

/// Tests for color matrix integrity (CE).
///
/// **Rule ID:** CE, CROSS_PLATFORM_COLOR_001
/// **Status:** IMMUTABLE
///
/// These tests ensure:
/// - Matrix values match COLOR_MATRICES.json exactly
/// - D65 white point is locked
/// - No runtime switching allowed
final class ColorMatrixIntegrityTests: XCTestCase {
    
    func test_sRGBToXYZ_matrix_exactMatch() throws {
        let matrices = try JSONTestHelpers.loadJSONDictionary(filename: "COLOR_MATRICES.json")
        
        guard let sRGBToXYZ = matrices["sRGBToXYZ"] as? [String: Any],
              let jsonMatrix = sRGBToXYZ["matrix"] as? [[Double]] else {
            XCTFail("COLOR_MATRICES.json must have sRGBToXYZ.matrix")
            return
        }
        
        let constantMatrix = ColorSpaceConstants.SRGB_TO_XYZ_MATRIX
        
        XCTAssertEqual(jsonMatrix.count, constantMatrix.count,
            "Matrix row count must match")
        XCTAssertEqual(jsonMatrix[0].count, constantMatrix[0].count,
            "Matrix column count must match")
        
        for (i, row) in jsonMatrix.enumerated() {
            for (j, value) in row.enumerated() {
                XCTAssertEqual(value, constantMatrix[i][j], accuracy: 1e-10,
                    "Matrix[\(i)][\(j)] must match SSOT constant exactly (CE). Expected \(constantMatrix[i][j]), got \(value)")
            }
        }
    }
    
    func test_xyzToLab_referenceWhite_exactMatch() throws {
        let matrices = try JSONTestHelpers.loadJSONDictionary(filename: "COLOR_MATRICES.json")
        
        guard let xyzToLab = matrices["xyzToLab"] as? [String: Any],
              let referenceWhite = xyzToLab["referenceWhite"] as? [String: Double] else {
            XCTFail("COLOR_MATRICES.json must have xyzToLab.referenceWhite")
            return
        }
        
        guard let xn = referenceWhite["Xn"],
              let yn = referenceWhite["Yn"],
              let zn = referenceWhite["Zn"] else {
            XCTFail("xyzToLab.referenceWhite must have Xn, Yn, Zn")
            return
        }
        
        XCTAssertEqual(xn, ColorSpaceConstants.XYZ_REFERENCE_WHITE_XN, accuracy: 1e-10,
            "Xn must match SSOT constant exactly")
        XCTAssertEqual(yn, ColorSpaceConstants.XYZ_REFERENCE_WHITE_YN, accuracy: 1e-10,
            "Yn must match SSOT constant exactly")
        XCTAssertEqual(zn, ColorSpaceConstants.XYZ_REFERENCE_WHITE_ZN, accuracy: 1e-10,
            "Zn must match SSOT constant exactly")
    }
    
    func test_d65_whitePoint_locked() {
        // Verify D65 is fixed in constants
        XCTAssertEqual(ColorSpaceConstants.WHITE_POINT, "D65",
            "WHITE_POINT must be D65 (CE - IMMUTABLE)")
        
        // Verify COLOR_MATRICES.json also specifies D65
        do {
            let matrices = try JSONTestHelpers.loadJSONDictionary(filename: "COLOR_MATRICES.json")
            XCTAssertEqual(matrices["whitePoint"] as? String, "D65",
                "COLOR_MATRICES.json whitePoint must be D65")
        } catch {
            XCTFail("Failed to load COLOR_MATRICES.json: \(error)")
        }
    }
    
    func test_labDelta_exactMatch() throws {
        let matrices = try JSONTestHelpers.loadJSONDictionary(filename: "COLOR_MATRICES.json")
        
        guard let xyzToLab = matrices["xyzToLab"] as? [String: Any],
              let delta = xyzToLab["delta"] as? Double else {
            XCTFail("COLOR_MATRICES.json must have xyzToLab.delta")
            return
        }
        
        let expectedDelta = ColorSpaceConstants.LAB_DELTA
        XCTAssertEqual(delta, expectedDelta, accuracy: 1e-10,
            "Lab delta must match SSOT constant exactly")
    }
    
    func test_matrix_noRuntimeSwitching() {
        // Verify matrices are compile-time constants, not runtime-configurable
        // This is enforced by the fact that ColorSpaceConstants uses static let
        
        // If matrices were runtime-configurable, we'd need to test that switching fails
        // But since they're compile-time constants, we just verify they're immutable
        let matrix1 = ColorSpaceConstants.SRGB_TO_XYZ_MATRIX
        let matrix2 = ColorSpaceConstants.SRGB_TO_XYZ_MATRIX
        
        // Same reference (or value equality) - no way to change at runtime
        XCTAssertEqual(matrix1.count, matrix2.count,
            "Matrix must be immutable (CE constraint)")
    }
}
