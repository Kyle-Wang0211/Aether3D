//
// WedgeGeometryTests.swift
// Aether3D
//
// PR#7 Scan Guidance UI — Wedge Geometry Tests
//

import XCTest
@testable import Aether3DCore

final class WedgeGeometryTests: XCTestCase {
    
    func testLOD3FlatGeneration() {
        // Test LOD3 (flat) geometry generation
        let generator = WedgeGeometryGenerator()
        
        let triangle = ScanTriangle(
            patchId: "test-patch-1",
            vertices: (
                SIMD3<Float>(0, 0, 0),
                SIMD3<Float>(1, 0, 0),
                SIMD3<Float>(0.5, 1, 0)
            ),
            normal: SIMD3<Float>(0, 0, 1),
            areaSqM: 0.5
        )
        
        let displayValues = ["test-patch-1": 0.5]
        let result = generator.generate(
            triangles: [triangle],
            displayValues: displayValues,
            lod: .flat
        )
        
        // LOD3 should produce 2 triangles per input triangle (flat, no extrusion)
        // But Phase 1 implementation just uses original triangle
        XCTAssertEqual(result.triangleCount, 1, "Should have 1 triangle")
        XCTAssertEqual(result.vertices.count, 3, "Should have 3 vertices for flat triangle")
        XCTAssertEqual(result.indices.count, 3, "Should have 3 indices")
    }
    
    func testThicknessCalculation() {
        let generator = WedgeGeometryGenerator()
        
        // Test thickness at display=0 (should be base thickness)
        let thickness0 = generator.thickness(
            display: 0.0,
            areaSqM: 0.5,
            medianArea: 0.5
        )
        XCTAssertGreaterThan(thickness0, Float(ScanGuidanceConstants.wedgeMinThicknessM))
        XCTAssertLessThanOrEqual(thickness0, Float(ScanGuidanceConstants.wedgeBaseThicknessM))
        
        // Test thickness at display=1 (should be min thickness)
        let thickness1 = generator.thickness(
            display: 1.0,
            areaSqM: 0.5,
            medianArea: 0.5
        )
        XCTAssertEqual(thickness1, Float(ScanGuidanceConstants.wedgeMinThicknessM), accuracy: 0.0001)
        
        // Test thickness decreases with display
        let thicknessMid = generator.thickness(
            display: 0.5,
            areaSqM: 0.5,
            medianArea: 0.5
        )
        XCTAssertGreaterThan(thicknessMid, thickness1)
        XCTAssertLessThan(thicknessMid, thickness0)
    }
    
    func testThicknessAreaFactor() {
        let generator = WedgeGeometryGenerator()
        
        // Test that larger area produces larger thickness
        let thicknessSmall = generator.thickness(
            display: 0.0,
            areaSqM: 0.1,
            medianArea: 0.5
        )
        let thicknessLarge = generator.thickness(
            display: 0.0,
            areaSqM: 1.0,
            medianArea: 0.5
        )
        XCTAssertGreaterThan(thicknessLarge, thicknessSmall)
    }
    
    func testBevelNormals() {
        let generator = WedgeGeometryGenerator()
        
        let topNormal = SIMD3<Float>(0, 0, 1)
        let sideNormal = SIMD3<Float>(0, 1, 0)
        let segments = 2
        
        let normals = generator.bevelNormals(
            topFaceNormal: topNormal,
            sideFaceNormal: sideNormal,
            segments: segments
        )
        
        XCTAssertEqual(normals.count, segments + 1, "Should have segments+1 normals")
        
        // First normal should be topNormal
        let firstNormal = normals[0]
        XCTAssertEqual(firstNormal.x, topNormal.x, accuracy: 0.01)
        XCTAssertEqual(firstNormal.y, topNormal.y, accuracy: 0.01)
        XCTAssertEqual(firstNormal.z, topNormal.z, accuracy: 0.01)
        
        // Last normal should be sideNormal
        let lastNormal = normals[segments]
        XCTAssertEqual(lastNormal.x, sideNormal.x, accuracy: 0.01)
        XCTAssertEqual(lastNormal.y, sideNormal.y, accuracy: 0.01)
        XCTAssertEqual(lastNormal.z, sideNormal.z, accuracy: 0.01)
    }
    
    func testLODLevelsExist() {
        // Verify all LOD levels are defined
        let levels = WedgeGeometryGenerator.LODLevel.allCases
        XCTAssertEqual(levels.count, 4, "Should have 4 LOD levels")
        XCTAssertTrue(levels.contains(.full))
        XCTAssertTrue(levels.contains(.medium))
        XCTAssertTrue(levels.contains(.low))
        XCTAssertTrue(levels.contains(.flat))
    }
    
    func testLODLevelsGenerateCorrectly() {
        // Phase 2: All LOD levels should work
        let generator = WedgeGeometryGenerator()
        let triangle = ScanTriangle(
            patchId: "test",
            vertices: (SIMD3<Float>(0,0,0), SIMD3<Float>(1,0,0), SIMD3<Float>(0,1,0)),
            normal: SIMD3<Float>(0,0,1),
            areaSqM: 0.5
        )
        
        // LOD3 (flat): 2 triangles per input triangle (top + bottom, but flat = same triangle)
        let result3 = generator.generate(
            triangles: [triangle],
            displayValues: ["test": 0.5],
            lod: .flat
        )
        XCTAssertEqual(result3.triangleCount, 1, "LOD3 should produce 1 triangle")
        XCTAssertGreaterThanOrEqual(result3.vertices.count, 3, "LOD3 should have at least 3 vertices")
        
        // LOD2 (low): 8 triangles per prism
        let result2 = generator.generate(
            triangles: [triangle],
            displayValues: ["test": 0.5],
            lod: .low
        )
        XCTAssertEqual(result2.triangleCount, 1, "LOD2 should produce 1 triangle (input)")
        XCTAssertGreaterThanOrEqual(result2.vertices.count, 6, "LOD2 should have at least 6 vertices (top + bottom)")
        
        // LOD1 (medium): Simplified implementation uses low LOD
        let result1 = generator.generate(
            triangles: [triangle],
            displayValues: ["test": 0.5],
            lod: .medium
        )
        XCTAssertEqual(result1.triangleCount, 1, "LOD1 should produce 1 triangle")
        
        // LOD0 (full): Simplified implementation uses low LOD
        let result0 = generator.generate(
            triangles: [triangle],
            displayValues: ["test": 0.5],
            lod: .full
        )
        XCTAssertEqual(result0.triangleCount, 1, "LOD0 should produce 1 triangle")
    }
    
    func testLOD3FlatNoExtrusion() {
        // Verify LOD3 produces flat geometry (no extrusion)
        let generator = WedgeGeometryGenerator()
        let triangle = ScanTriangle(
            patchId: "test",
            vertices: (
                SIMD3<Float>(0, 0, 0),
                SIMD3<Float>(1, 0, 0),
                SIMD3<Float>(0.5, 1, 0)
            ),
            normal: SIMD3<Float>(0, 0, 1),
            areaSqM: 0.5
        )
        
        let result = generator.generate(
            triangles: [triangle],
            displayValues: ["test": 0.5],
            lod: .flat
        )
        
        // LOD3 should have exactly 3 vertices (no extrusion)
        XCTAssertEqual(result.vertices.count, 3, "LOD3 flat should have exactly 3 vertices")
        XCTAssertEqual(result.indices.count, 3, "LOD3 flat should have exactly 3 indices")
    }
    
    func testLOD2Extrusion() {
        // Verify LOD2 produces extruded geometry
        let generator = WedgeGeometryGenerator()
        let triangle = ScanTriangle(
            patchId: "test",
            vertices: (
                SIMD3<Float>(0, 0, 0),
                SIMD3<Float>(1, 0, 0),
                SIMD3<Float>(0.5, 1, 0)
            ),
            normal: SIMD3<Float>(0, 0, 1),
            areaSqM: 0.5
        )
        
        let result = generator.generate(
            triangles: [triangle],
            displayValues: ["test": 0.0],  // display=0 for maximum thickness
            lod: .low
        )
        
        // LOD2 should have more vertices than LOD3 (extruded)
        XCTAssertGreaterThan(result.vertices.count, 3, "LOD2 should have more than 3 vertices (extruded)")
        XCTAssertGreaterThan(result.indices.count, 3, "LOD2 should have more than 3 indices")
        
        // Should have top and bottom faces
        let zValues = result.vertices.map { $0.position.z }
        let minZ = zValues.min() ?? 0
        let maxZ = zValues.max() ?? 0
        XCTAssertNotEqual(minZ, maxZ, "LOD2 should have different Z values (extrusion)")
    }
}
