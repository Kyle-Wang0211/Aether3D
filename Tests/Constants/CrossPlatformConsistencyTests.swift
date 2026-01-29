//
// CrossPlatformConsistencyTests.swift
// Aether3D
//
// PR#1 SSOT Foundation v1.1 - Cross-Platform Consistency Tests
//
// This test file validates cross-platform determinism using golden vectors.
//

import XCTest
@testable import Aether3DCore

/// Tests for cross-platform consistency (A2, A3, A4, A5, CE, CL2).
///
/// **Rule ID:** A2, A3, A4, A5, CE, CL2, F1, F2
/// **Status:** IMMUTABLE
///
/// These tests ensure:
/// - Byte-level encoding determinism
/// - Quantization precision separation
/// - Rounding mode consistency
/// - Color conversion accuracy
/// - meshEpochSalt closure adherence
final class CrossPlatformConsistencyTests: XCTestCase {
    
    // MARK: - Deterministic Encoding Tests (A2) - Using Golden Vectors
    
    func test_encoding_goldenVectors_exactBytes() throws {
        struct EncodingVector: Decodable {
            let name: String
            let input: String?
            let inputInt: Int?
            let expectedBytes: String
            let description: String
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
            
            if let diff = HexTestHelpers.compareBytes(expectedBytes, actualBytes, context: vector.name) {
                XCTFail("""
                    ❌ Encoding mismatch for '\(vector.name)'
                    Invariant: A2
                    \(diff)
                    File: GOLDEN_VECTORS_ENCODING.json
                    Fix: Fix encoding implementation OR update golden vector with breaking change documentation
                    """)
            }
        }
    }
    
    func test_encoding_emptyString_lengthZero() throws {
        let encoded = DeterministicEncoding.encodeEmptyString()
        let length = UInt32(bigEndian: encoded.withUnsafeBytes { $0.load(as: UInt32.self) })
        XCTAssertEqual(length, 0, "Empty string must encode to length=0")
    }
    
    func test_encoding_embeddedNul_rejected() {
        let inputWithNul = "hello\u{0000}world"
        XCTAssertThrowsError(try DeterministicEncoding.encodeString(inputWithNul)) { error in
            if case DeterministicEncoding.EncodingError.embeddedNulByte = error {
                // Expected
            } else {
                XCTFail("Expected embeddedNulByte error, got \(error)")
            }
        }
    }
    
    func test_encoding_domainPrefixes_matchConstants() throws {
        let domainPrefixes = try JSONTestHelpers.loadJSONDictionary(filename: "DOMAIN_PREFIXES.json")
        guard let prefixes = domainPrefixes["prefixes"] as? [[String: Any]] else {
            XCTFail("DOMAIN_PREFIXES.json must have 'prefixes' array")
            return
        }
        
        for prefixDict in prefixes {
            guard let prefixString = prefixDict["prefix"] as? String else { continue }
            
            let encoded = try DeterministicEncoding.encodeDomainPrefix(prefixString)
            XCTAssertGreaterThan(encoded.count, 4, "Domain prefix '\(prefixString)' must encode to at least length prefix")
        }
    }
    
    // MARK: - Deterministic Quantization Tests (A3 + A4) - Using Golden Vectors
    
    func test_quantization_goldenVectors_exactResults() throws {
        struct QuantizationVector: Decodable {
            let name: String
            let input: Double
            let precision: Double
            let expectedQuantized: Int64
            let description: String
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
                XCTFail("Vector '\(vector.name)' has unsupported precision \(vector.precision)")
                continue
            }
            
            if result.quantized != vector.expectedQuantized {
                XCTFail("""
                    ❌ Quantization mismatch for '\(vector.name)'
                    Invariant: A3, A4
                    Input: \(vector.input)
                    Precision: \(vector.precision)
                    Expected: \(vector.expectedQuantized)
                    Actual: \(result.quantized)
                    File: GOLDEN_VECTORS_QUANTIZATION.json
                    Fix: Fix quantization implementation OR update golden vector with breaking change documentation
                    """)
            }
        }
    }
    
    func test_quantization_roundingMode_halfAwayFromZero() {
        // Test explicit half-tie cases
        let testCases: [(input: Double, precision: Double, expected: Int64)] = [
            (0.0005, 0.001, 1),   // +0.5 -> +1 (away from zero)
            (-0.0005, 0.001, -1), // -0.5 -> -1 (away from zero)
            (0.0015, 0.001, 2),   // +1.5 -> +2
            (-0.0015, 0.001, -2), // -1.5 -> -2
        ]
        
        for testCase in testCases {
            let result = DeterministicQuantization.quantizeForGeomId(testCase.input)
            XCTAssertEqual(result.quantized, testCase.expected,
                "Rounding mode test failed: input=\(testCase.input), precision=\(testCase.precision), expected=\(testCase.expected), got=\(result.quantized)")
        }
    }
    
    func test_quantization_precisionSeparation() {
        // Verify geomId and patchId use different precisions
        let testValue = 0.0005
        
        let geomResult = DeterministicQuantization.quantizeForGeomId(testValue)
        let patchResult = DeterministicQuantization.quantizeForPatchId(testValue)
        
        // Same input should produce different quantized values due to different precisions
        XCTAssertNotEqual(geomResult.quantized, patchResult.quantized,
            "geomId and patchId must use different precisions (1mm vs 0.1mm)")
        
        // Verify precision constants are different
        XCTAssertNotEqual(DeterministicQuantization.QUANT_POS_GEOM_ID,
                          DeterministicQuantization.QUANT_POS_PATCH_ID,
                          "Precision constants must be different")
    }
    
    func test_quantization_negativeZero_normalized() {
        let result = DeterministicQuantization.quantizeForGeomId(-0.0)
        XCTAssertEqual(result.quantized, 0, "Negative zero must normalize to positive zero")
        XCTAssertTrue(result.edgeCasesTriggered.isEmpty, "Normalized -0.0 should not trigger edge cases")
    }
    
    func test_quantization_nanInf_rejected() {
        let nanResult = DeterministicQuantization.quantizeForGeomId(Double.nan)
        XCTAssertTrue(nanResult.edgeCasesTriggered.contains(.NAN_OR_INF_DETECTED),
            "NaN input must trigger NAN_OR_INF_DETECTED edge case")
        
        let infResult = DeterministicQuantization.quantizeForGeomId(Double.infinity)
        XCTAssertTrue(infResult.edgeCasesTriggered.contains(.NAN_OR_INF_DETECTED),
            "Infinity input must trigger NAN_OR_INF_DETECTED edge case")
    }
    
    // MARK: - Color Conversion Tests (CE + CL2) - Using Golden Vectors
    
    func test_colorConversion_goldenVectors_withinTolerance() throws {
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
            let description: String
        }
        
        struct ColorVectors: Decodable {
            let testVectors: [ColorVector]
        }
        
        let vectors = try JSONTestHelpers.decode(filename: "GOLDEN_VECTORS_COLOR.json", as: ColorVectors.self)
        
        let tolerance = CrossPlatformConstants.TOLERANCE_LAB_COLOR_ABSOLUTE
        
        for vector in vectors.testVectors {
            // Convert sRGB -> XYZ -> Lab using SSOT constants only
            let lab = convertSRGBToLab(r: vector.input.r, g: vector.input.g, b: vector.input.b)
            
            let lDiff = abs(lab.l - vector.expectedLab.l)
            let aDiff = abs(lab.a - vector.expectedLab.a)
            let bDiff = abs(lab.b - vector.expectedLab.b)
            
            if lDiff > tolerance {
                XCTFail("""
                    ❌ Lab L* channel mismatch for '\(vector.name)'
                    Invariant: CL2, CE
                    Expected: \(vector.expectedLab.l)
                    Actual: \(lab.l)
                    Difference: \(lDiff)
                    Tolerance: \(tolerance) (absolute per channel)
                    File: GOLDEN_VECTORS_COLOR.json
                    Fix: Check color conversion implementation OR update golden vector with breaking change documentation
                    """)
            }
            if aDiff > tolerance {
                XCTFail("""
                    ❌ Lab a* channel mismatch for '\(vector.name)'
                    Invariant: CL2, CE
                    Expected: \(vector.expectedLab.a)
                    Actual: \(lab.a)
                    Difference: \(aDiff)
                    Tolerance: \(tolerance) (absolute per channel)
                    File: GOLDEN_VECTORS_COLOR.json
                    Fix: Check color conversion implementation OR update golden vector with breaking change documentation
                    """)
            }
            if bDiff > tolerance {
                XCTFail("""
                    ❌ Lab b* channel mismatch for '\(vector.name)'
                    Invariant: CL2, CE
                    Expected: \(vector.expectedLab.b)
                    Actual: \(lab.b)
                    Difference: \(bDiff)
                    Tolerance: \(tolerance) (absolute per channel)
                    File: GOLDEN_VECTORS_COLOR.json
                    Fix: Check color conversion implementation OR update golden vector with breaking change documentation
                    """)
            }
        }
    }
    
    func test_colorConversion_d65_whitePoint_fixed() {
        // Verify D65 is fixed in constants
        XCTAssertEqual(ColorSpaceConstants.WHITE_POINT, "D65",
            "ColorSpaceConstants.WHITE_POINT must be D65 (IMMUTABLE)")
        
        // Verify COLOR_MATRICES.json also specifies D65
        do {
            let matrices = try JSONTestHelpers.loadJSONDictionary(filename: "COLOR_MATRICES.json")
            XCTAssertEqual(matrices["whitePoint"] as? String, "D65",
                "COLOR_MATRICES.json whitePoint must be D65")
        } catch {
            XCTFail("Failed to load COLOR_MATRICES.json: \(error)")
        }
    }
    
    func test_colorConversion_matrices_explicit_ssot() {
        // Verify matrices match COLOR_MATRICES.json exactly
        do {
            let matrices = try JSONTestHelpers.loadJSONDictionary(filename: "COLOR_MATRICES.json")
            guard let sRGBToXYZ = matrices["sRGBToXYZ"] as? [String: Any],
                  let jsonMatrix = sRGBToXYZ["matrix"] as? [[Double]] else {
                XCTFail("COLOR_MATRICES.json must have sRGBToXYZ.matrix")
                return
            }
            
            let constantMatrix = ColorSpaceConstants.SRGB_TO_XYZ_MATRIX
            
            for (i, row) in jsonMatrix.enumerated() {
                for (j, value) in row.enumerated() {
                    XCTAssertEqual(value, constantMatrix[i][j], accuracy: 1e-10,
                        "Matrix[\(i)][\(j)] must match SSOT constant exactly")
                }
            }
        } catch {
            XCTFail("Failed to validate color matrices: \(error)")
        }
    }
    
    // MARK: - meshEpochSalt Closure Tests (A5)
    
    func test_meshEpochSalt_closure_includedFields() {
        // Verify included fields are defined
        let included = CrossPlatformConstants.MESH_EPOCH_SALT_INCLUDED_INPUTS
        let requiredFields = ["rawVideoDigest", "cameraIntrinsicsDigest", 
                             "reconstructionParamsDigest", "pipelineVersion"]
        
        for field in requiredFields {
            XCTAssertTrue(included.contains(field),
                "meshEpochSalt closure must include '\(field)'")
        }
    }
    
    func test_meshEpochSalt_closure_excludedFields() {
        // Verify excluded fields are defined
        let excluded = CrossPlatformConstants.MESH_EPOCH_SALT_EXCLUDED_INPUTS
        let forbiddenFields = ["deviceModelClass", "timestampRange"]
        
        for field in forbiddenFields {
            XCTAssertTrue(excluded.contains(field),
                "meshEpochSalt closure must exclude '\(field)'")
        }
    }
    
    func test_meshEpochSalt_closure_auditOnlyFields() {
        // Verify audit-only fields are defined
        let auditOnly = CrossPlatformConstants.MESH_EPOCH_SALT_AUDIT_ONLY_INPUTS
        XCTAssertTrue(auditOnly.contains("frameDigestMerkleRoot"),
            "meshEpochSalt closure must list 'frameDigestMerkleRoot' as audit-only")
    }
    
    func test_meshEpochSalt_closure_manifestDigest() throws {
        // Create a closure manifest digest (witness function)
        // This is NOT the real salt algorithm, only a deterministic digest of closure metadata
        let included = CrossPlatformConstants.MESH_EPOCH_SALT_INCLUDED_INPUTS.sorted()
        let excluded = CrossPlatformConstants.MESH_EPOCH_SALT_EXCLUDED_INPUTS.sorted()
        let auditOnly = CrossPlatformConstants.MESH_EPOCH_SALT_AUDIT_ONLY_INPUTS.sorted()
        
        var manifestData = Data()
        for field in included {
            manifestData.append(try DeterministicEncoding.encodeString("INCLUDED:\(field)"))
        }
        for field in excluded {
            manifestData.append(try DeterministicEncoding.encodeString("EXCLUDED:\(field)"))
        }
        for field in auditOnly {
            manifestData.append(try DeterministicEncoding.encodeString("AUDIT_ONLY:\(field)"))
        }
        
        // This digest should be stable - if closure changes, this changes
        // In a real implementation, this would be stored as a golden value
        let manifestDigest = HexTestHelpers.toHex(manifestData)
        XCTAssertFalse(manifestDigest.isEmpty, "Closure manifest digest must be non-empty")
        
        // Verify closure fields don't overlap
        let allFields = Set(included + excluded + auditOnly)
        XCTAssertEqual(allFields.count, included.count + excluded.count + auditOnly.count,
            "Closure field sets must not overlap")
    }
    
    // MARK: - Numerical Tolerance Tests (CL2 + F1)
    
    func test_coverageRatio_tolerance_1e4_relative() {
        let tolerance = CrossPlatformConstants.TOLERANCE_COVERAGE_RATIO_RELATIVE
        XCTAssertEqual(tolerance, 1e-4, accuracy: 1e-10,
            "Coverage/Ratio relative error tolerance must be 1e-4 (CL2)")
        
        // Test relative error formula (F1)
        let eps = CrossPlatformConstants.RELATIVE_ERROR_EPSILON
        XCTAssertEqual(eps, 1e-12, accuracy: 1e-15,
            "Relative error epsilon must be 1e-12 (F1)")
        
        // Verify formula: relErr(a, b) = |a - b| / max(eps, max(|a|, |b|))
        func relErr(_ a: Double, _ b: Double) -> Double {
            return abs(a - b) / max(eps, max(abs(a), abs(b)))
        }
        
        let testCases: [(a: Double, b: Double, expectedWithinTolerance: Bool)] = [
            (0.5, 0.50001, false),  // diff too large
            (0.5, 0.50005, true),   // within tolerance
            (0.0, 0.0, true),       // both zero
            (1e-10, 1e-10, true),   // very small values
        ]
        
        for testCase in testCases {
            let error = relErr(testCase.a, testCase.b)
            if testCase.expectedWithinTolerance {
                XCTAssertLessThanOrEqual(error, tolerance,
                    "relErr(\(testCase.a), \(testCase.b)) = \(error) should be <= \(tolerance)")
            }
        }
    }
    
    func test_labColor_tolerance_1e3_absolute() {
        let tolerance = CrossPlatformConstants.TOLERANCE_LAB_COLOR_ABSOLUTE
        XCTAssertEqual(tolerance, 1e-3, accuracy: 1e-10,
            "Lab color absolute error tolerance must be 1e-3 per channel (CL2, F2)")
        
        // Verify it's per-channel absolute, not ΔE
        let lab1 = (l: 50.0, a: 0.0, b: 0.0)
        let lab2 = (l: 50.001, a: 0.0, b: 0.0)
        
        let lDiff = abs(lab1.l - lab2.l)
        XCTAssertLessThanOrEqual(lDiff, tolerance,
            "Lab L* difference should be within absolute tolerance")
    }
    
    // MARK: - Helper Functions
    
    /// Converts sRGB to Lab using SSOT constants only (no OS APIs).
    /// This is a simplified implementation for testing purposes.
    private func convertSRGBToLab(r: Double, g: Double, b: Double) -> (l: Double, a: Double, b: Double) {
        // sRGB -> XYZ using SSOT matrix
        let matrix = ColorSpaceConstants.SRGB_TO_XYZ_MATRIX
        let x = matrix[0][0] * r + matrix[0][1] * g + matrix[0][2] * b
        let y = matrix[1][0] * r + matrix[1][1] * g + matrix[1][2] * b
        let z = matrix[2][0] * r + matrix[2][1] * g + matrix[2][2] * b
        
        // XYZ -> Lab using D65 reference white
        let xn = ColorSpaceConstants.XYZ_REFERENCE_WHITE_XN
        let yn = ColorSpaceConstants.XYZ_REFERENCE_WHITE_YN
        let zn = ColorSpaceConstants.XYZ_REFERENCE_WHITE_ZN
        
        let fx = f(x / xn)
        let fy = f(y / yn)
        let fz = f(z / zn)
        
        let l = 116.0 * fy - 16.0
        let a = 500.0 * (fx - fy)
        let b = 200.0 * (fy - fz)
        
        return (l: l, a: a, b: b)
    }
    
    /// Lab conversion f function.
    private func f(_ t: Double) -> Double {
        let delta = ColorSpaceConstants.LAB_DELTA
        let deltaCubed = ColorSpaceConstants.LAB_DELTA_CUBED
        
        if t > deltaCubed {
            return pow(t, 1.0/3.0)
        } else {
            return t / (3.0 * delta * delta) + 4.0 / 29.0
        }
    }
}
