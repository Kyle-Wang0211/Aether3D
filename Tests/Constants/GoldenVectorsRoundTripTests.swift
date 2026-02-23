// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// GoldenVectorsRoundTripTests.swift
// Aether3D
//
// PR#1 SSOT Foundation v1.1 - Golden Vectors Round-Trip Tests
//
// This test file ensures encoding/quantization/color vectors are stable.
//

import XCTest
@testable import Aether3DCore

/// Tests for golden vector stability.
///
/// **Rule ID:** D38, D39, CL2
/// **Status:** IMMUTABLE
///
/// These tests ensure:
/// - Golden vectors remain stable across library upgrades
/// - Encoding vectors produce exact bytes
/// - Quantization vectors produce exact results
/// - Color vectors produce results within tolerance
final class GoldenVectorsRoundTripTests: XCTestCase {
    
    func test_encodingVectors_stable() throws {
        struct EncodingVector: Decodable {
            let name: String
            let input: String?
            let inputInt: Int?
            let expectedBytes: String
        }
        
        struct EncodingVectors: Decodable {
            let testVectors: [EncodingVector]
        }
        
        let vectors = try JSONTestHelpers.decode(filename: "GOLDEN_VECTORS_ENCODING.json", as: EncodingVectors.self)
        
        for vector in vectors.testVectors {
            var actualBytes: Data
            
            if let input = vector.input {
                if input.isEmpty {
                    actualBytes = DeterministicEncoding.encodeEmptyString()
                } else {
                    actualBytes = try DeterministicEncoding.encodeString(input)
                }
            } else if let inputInt = vector.inputInt {
                actualBytes = DeterministicEncoding.encodeUInt32BE(UInt32(inputInt))
            } else {
                continue
            }
            
            let expectedBytes = try HexTestHelpers.fromHex(vector.expectedBytes)
            
            XCTAssertEqual(actualBytes, expectedBytes,
                "Encoding vector '\(vector.name)' must produce exact bytes. Any change indicates breaking change.")
        }
    }
    
    func test_quantizationVectors_stable() throws {
        struct QuantizationVector: Decodable {
            let name: String
            let input: Double
            let precision: Double
            let expectedQuantized: Int64
        }
        
        struct QuantizationVectors: Decodable {
            let testVectors: [QuantizationVector]
        }
        
        let vectors = try JSONTestHelpers.decode(filename: "GOLDEN_VECTORS_QUANTIZATION.json", as: QuantizationVectors.self)
        
        for vector in vectors.testVectors {
            let result: QuantizationResult
            
            if abs(vector.precision - DeterministicQuantization.QUANT_POS_GEOM_ID) < 1e-10 {
                result = DeterministicQuantization.quantizeForGeomId(vector.input)
            } else if abs(vector.precision - DeterministicQuantization.QUANT_POS_PATCH_ID) < 1e-10 {
                result = DeterministicQuantization.quantizeForPatchId(vector.input)
            } else {
                continue
            }
            
            XCTAssertEqual(result.quantized, vector.expectedQuantized,
                "Quantization vector '\(vector.name)' must produce exact result. Any change indicates breaking change.")
        }
    }
    
    func test_colorVectors_stable() throws {
        struct RGBInput: Decodable {
            let r: Double
            let g: Double
            let b: Double
        }
        
        struct LabOutput: Decodable {
            let l: Double
            let a: Double
            let b: Double
        }
        
        struct ColorVector: Decodable {
            let name: String
            let input: RGBInput
            let expectedLab: LabOutput
            let tolerance: [String: Double]
        }
        
        struct ColorVectors: Decodable {
            let testVectors: [ColorVector]
        }
        
        let vectors = try JSONTestHelpers.decode(filename: "GOLDEN_VECTORS_COLOR.json", as: ColorVectors.self)
        let tolerance = CrossPlatformConstants.TOLERANCE_LAB_COLOR_ABSOLUTE
        
        for vector in vectors.testVectors {
            // Use same conversion logic as CrossPlatformConsistencyTests
            let matrix = ColorSpaceConstants.SRGB_TO_XYZ_MATRIX
            let x = matrix[0][0] * vector.input.r + matrix[0][1] * vector.input.g + matrix[0][2] * vector.input.b
            let y = matrix[1][0] * vector.input.r + matrix[1][1] * vector.input.g + matrix[1][2] * vector.input.b
            let z = matrix[2][0] * vector.input.r + matrix[2][1] * vector.input.g + matrix[2][2] * vector.input.b
            
            let xn = ColorSpaceConstants.XYZ_REFERENCE_WHITE_XN
            let yn = ColorSpaceConstants.XYZ_REFERENCE_WHITE_YN
            let zn = ColorSpaceConstants.XYZ_REFERENCE_WHITE_ZN
            
            func f(_ t: Double) -> Double {
                let delta = ColorSpaceConstants.LAB_DELTA
                let deltaCubed = ColorSpaceConstants.LAB_DELTA_CUBED
                if t > deltaCubed {
                    return pow(t, 1.0/3.0)
                } else {
                    return t / (3.0 * delta * delta) + 4.0 / 29.0
                }
            }
            
            let fx = f(x / xn)
            let fy = f(y / yn)
            let fz = f(z / zn)
            
            let lab = (l: 116.0 * fy - 16.0, a: 500.0 * (fx - fy), b: 200.0 * (fy - fz))
            
            let lDiff = abs(lab.l - vector.expectedLab.l)
            let aDiff = abs(lab.a - vector.expectedLab.a)
            let bDiff = abs(lab.b - vector.expectedLab.b)
            
            XCTAssertLessThanOrEqual(lDiff, tolerance,
                "Color vector '\(vector.name)' L* channel must be within tolerance. Any drift indicates breaking change.")
            XCTAssertLessThanOrEqual(aDiff, tolerance,
                "Color vector '\(vector.name)' a* channel must be within tolerance.")
            XCTAssertLessThanOrEqual(bDiff, tolerance,
                "Color vector '\(vector.name)' b* channel must be within tolerance.")
        }
    }
}
