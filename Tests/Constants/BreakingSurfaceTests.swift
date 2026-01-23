//
// BreakingSurfaceTests.swift
// Aether3D
//
// PR#1 SSOT Foundation v1.1.1 - Breaking Surface Tests
//
// This test file validates breaking change surface definitions and RFC gates.
//

import XCTest
@testable import Aether3DCore

/// Tests for breaking change surface validation (C1).
///
/// **Rule ID:** C1
/// **Status:** IMMUTABLE
///
/// These tests ensure:
/// - All breaking surfaces are enumerated
/// - RFC gates are enforced
/// - Breaking surfaces reference required fields
final class BreakingSurfaceTests: XCTestCase {
    
    func test_breakingSurface_allRequiredSurfacesPresent() throws {
        let breakingSurface = try JSONTestHelpers.loadJSONDictionary(filename: "BREAKING_CHANGE_SURFACE.json")
        
        guard let surfaces = breakingSurface["breakingSurfaces"] as? [[String: Any]] else {
            XCTFail("BREAKING_CHANGE_SURFACE.json must have 'breakingSurfaces' array")
            return
        }
        
        let requiredSurfaces = [
            "encoding.byte_order",
            "encoding.string_format",
            "encoding.unicode_normalization",
            "quant.geom_precision",
            "quant.patch_precision",
            "rounding_mode",
            "hash_algorithm",
            "domain_separation_prefixes",
            "color.white_point",
            "color.matrix",
            "cross_platform_tolerances",
            "guaranteed_output_fields"
        ]
        
        let surfaceIds = Set(surfaces.compactMap { $0["id"] as? String })
        
        for requiredSurface in requiredSurfaces {
            XCTAssertTrue(surfaceIds.contains(requiredSurface),
                "BREAKING_CHANGE_SURFACE.json must include '\(requiredSurface)' (C1)")
        }
    }
    
    func test_breakingSurface_rfcRequirement() throws {
        let breakingSurface = try JSONTestHelpers.loadJSONDictionary(filename: "BREAKING_CHANGE_SURFACE.json")
        
        guard let surfaces = breakingSurface["breakingSurfaces"] as? [[String: Any]] else {
            XCTFail("BREAKING_CHANGE_SURFACE.json must have 'breakingSurfaces' array")
            return
        }
        
        for (_, surface) in surfaces.enumerated() {
            guard let surfaceId = surface["id"] as? String else {
                XCTFail("Breaking surface \(index) missing 'id' field")
                continue
            }
            
            if let requires = surface["requires"] as? [String] {
                XCTAssertTrue(requires.contains("RFC"),
                    "Breaking surface '\(surfaceId)' must require RFC (C1)")
                XCTAssertTrue(requires.contains("contractVersion_bump"),
                    "Breaking surface '\(surfaceId)' must require contractVersion_bump (C1)")
            } else {
                XCTFail("Breaking surface '\(surfaceId)' missing 'requires' field")
            }
        }
    }
    
    func test_breakingSurface_impactDescription() throws {
        let breakingSurface = try JSONTestHelpers.loadJSONDictionary(filename: "BREAKING_CHANGE_SURFACE.json")
        
        guard let surfaces = breakingSurface["breakingSurfaces"] as? [[String: Any]] else {
            XCTFail("BREAKING_CHANGE_SURFACE.json must have 'breakingSurfaces' array")
            return
        }
        
        for (_, surface) in surfaces.enumerated() {
            guard let surfaceId = surface["id"] as? String else { continue }
            
            XCTAssertNotNil(surface["description"] as? String,
                "Breaking surface '\(surfaceId)' must have 'description' field")
            XCTAssertNotNil(surface["impact"] as? String,
                "Breaking surface '\(surfaceId)' must have 'impact' field")
        }
    }
    
    func test_breakingSurface_matchesConstants() {
        // Verify breaking surfaces match actual constants
        
        // encoding.byte_order -> CrossPlatformConstants.BYTE_ORDER
        XCTAssertEqual(CrossPlatformConstants.BYTE_ORDER, "BIG_ENDIAN",
            "BYTE_ORDER constant must match breaking surface definition")
        
        // quant.geom_precision -> DeterministicQuantization.QUANT_POS_GEOM_ID
        XCTAssertEqual(DeterministicQuantization.QUANT_POS_GEOM_ID, 1e-3,
            "QUANT_POS_GEOM_ID constant must match breaking surface definition")
        
        // quant.patch_precision -> DeterministicQuantization.QUANT_POS_PATCH_ID
        XCTAssertEqual(DeterministicQuantization.QUANT_POS_PATCH_ID, 1e-4,
            "QUANT_POS_PATCH_ID constant must match breaking surface definition")
        
        // color.white_point -> ColorSpaceConstants.WHITE_POINT
        XCTAssertEqual(ColorSpaceConstants.WHITE_POINT, "D65",
            "WHITE_POINT constant must match breaking surface definition")
        
        // hash_algorithm -> CrossPlatformConstants.HASH_ALGO_ID
        XCTAssertEqual(CrossPlatformConstants.HASH_ALGO_ID, "SHA256",
            "HASH_ALGO_ID constant must match breaking surface definition")
    }
}
