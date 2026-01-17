//
//  DeterministicTriangulatorPlatformTests.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Cross-platform DeterministicTriangulator Tests
//  Validates DeterministicTriangulator works on all platforms (with/without CoreGraphics)
//

import XCTest
@testable import Aether3DCore

final class DeterministicTriangulatorPlatformTests: XCTestCase {
    
    /// Test QPoint initialization and basic operations (works on all platforms)
    func testQPointInitialization() throws {
        let point = QPoint(x: 1.5, y: 2.5)
        
        XCTAssertEqual(point.x, 1.5, accuracy: 0.001)
        XCTAssertEqual(point.y, 2.5, accuracy: 0.001)
    }
    
    /// Test QPoint equality (works on all platforms)
    func testQPointEquality() throws {
        let p1 = QPoint(x: 1.0, y: 2.0)
        let p2 = QPoint(x: 1.0, y: 2.0)
        let p3 = QPoint(x: 1.0, y: 3.0)
        
        XCTAssertEqual(p1, p2)
        XCTAssertNotEqual(p1, p3)
    }
    
    #if canImport(CoreGraphics)
    /// Test QPoint <-> CGPoint bridging on Apple platforms
    func testQPointCGPointBridging() throws {
        let cgPoint = CGPoint(x: 1.5, y: 2.5)
        let qPoint = QPoint(cgPoint)
        
        XCTAssertEqual(qPoint.x, 1.5, accuracy: 0.001)
        XCTAssertEqual(qPoint.y, 2.5, accuracy: 0.001)
        
        let backToCG = qPoint.cgPoint
        XCTAssertEqual(backToCG.x, 1.5, accuracy: 0.001)
        XCTAssertEqual(backToCG.y, 2.5, accuracy: 0.001)
    }
    #endif
    
    /// Test deterministic triangulation of a simple quad (works on all platforms)
    func testDeterministicTriangulation() throws {
        // Create a simple square quad
        let v0 = QPoint(x: 0.0, y: 0.0)
        let v1 = QPoint(x: 1.0, y: 0.0)
        let v2 = QPoint(x: 1.0, y: 1.0)
        let v3 = QPoint(x: 0.0, y: 1.0)
        
        let triangles = DeterministicTriangulator.triangulateQuad(v0: v0, v1: v1, v2: v2, v3: v3)
        
        // Should produce exactly 2 triangles
        XCTAssertEqual(triangles.count, 2, "Quad triangulation must produce exactly 2 triangles")
        
        // Each triangle should have 3 vertices
        for triangle in triangles {
            XCTAssertNotNil(triangle.0)
            XCTAssertNotNil(triangle.1)
            XCTAssertNotNil(triangle.2)
        }
        
        // Verify determinism: same input should produce same output
        let triangles2 = DeterministicTriangulator.triangulateQuad(v0: v0, v1: v1, v2: v2, v3: v3)
        XCTAssertEqual(triangles.count, triangles2.count, "Triangulation must be deterministic")
        
        // Verify triangle vertices match (deterministic output)
        for i in 0..<triangles.count {
            XCTAssertEqual(triangles[i].0.x, triangles2[i].0.x, accuracy: 0.001)
            XCTAssertEqual(triangles[i].0.y, triangles2[i].0.y, accuracy: 0.001)
            XCTAssertEqual(triangles[i].1.x, triangles2[i].1.x, accuracy: 0.001)
            XCTAssertEqual(triangles[i].1.y, triangles2[i].1.y, accuracy: 0.001)
            XCTAssertEqual(triangles[i].2.x, triangles2[i].2.x, accuracy: 0.001)
            XCTAssertEqual(triangles[i].2.y, triangles2[i].2.y, accuracy: 0.001)
        }
    }
    
    /// Test deterministic sorting of triangles (works on all platforms)
    func testDeterministicTriangleSorting() throws {
        // Create two triangles
        let t1 = (QPoint(x: 0.0, y: 0.0), QPoint(x: 1.0, y: 0.0), QPoint(x: 0.5, y: 1.0))
        let t2 = (QPoint(x: 2.0, y: 0.0), QPoint(x: 3.0, y: 0.0), QPoint(x: 2.5, y: 1.0))
        
        let triangles = [t2, t1] // Unsorted order
        let sorted = DeterministicTriangulator.sortTriangles(triangles)
        
        // Should be sorted deterministically
        XCTAssertEqual(sorted.count, 2)
        
        // Verify determinism: same input should produce same sorted output
        let sorted2 = DeterministicTriangulator.sortTriangles(triangles)
        XCTAssertEqual(sorted.count, sorted2.count)
        
        for i in 0..<sorted.count {
            XCTAssertEqual(sorted[i].0.x, sorted2[i].0.x, accuracy: 0.001)
            XCTAssertEqual(sorted[i].0.y, sorted2[i].0.y, accuracy: 0.001)
        }
    }
    
    /// Test triangulation with different quad shapes (works on all platforms)
    func testTriangulationVariousShapes() throws {
        // Test cases: square, rectangle, trapezoid
        let testCases: [(QPoint, QPoint, QPoint, QPoint)] = [
            // Square
            (QPoint(x: 0.0, y: 0.0), QPoint(x: 1.0, y: 0.0), QPoint(x: 1.0, y: 1.0), QPoint(x: 0.0, y: 1.0)),
            // Rectangle
            (QPoint(x: 0.0, y: 0.0), QPoint(x: 2.0, y: 0.0), QPoint(x: 2.0, y: 1.0), QPoint(x: 0.0, y: 1.0)),
            // Trapezoid
            (QPoint(x: 0.0, y: 0.0), QPoint(x: 2.0, y: 0.0), QPoint(x: 1.5, y: 1.0), QPoint(x: 0.5, y: 1.0)),
        ]
        
        for (v0, v1, v2, v3) in testCases {
            let triangles = DeterministicTriangulator.triangulateQuad(v0: v0, v1: v1, v2: v2, v3: v3)
            
            // Should always produce 2 triangles
            XCTAssertEqual(triangles.count, 2, "Quad triangulation must produce exactly 2 triangles")
            
            // Verify determinism: run twice, get same result
            let triangles2 = DeterministicTriangulator.triangulateQuad(v0: v0, v1: v1, v2: v2, v3: v3)
            XCTAssertEqual(triangles.count, triangles2.count)
            
            // Verify vertices match
            for i in 0..<triangles.count {
                XCTAssertEqual(triangles[i].0.x, triangles2[i].0.x, accuracy: 0.001)
                XCTAssertEqual(triangles[i].0.y, triangles2[i].0.y, accuracy: 0.001)
            }
        }
    }
}

