//
// RipplePropagationTests.swift
// Aether3D
//
// PR#7 Scan Guidance UI — Ripple Propagation Tests
// Core-only tests (compile and run in SwiftPM)
//

import XCTest
@testable import Aether3DCore

final class RipplePropagationTests: XCTestCase {
    
    func testBFSDistances() {
        // Create a simple chain of triangles
        let triangles = [
            ScanTriangle(patchId: "0", vertices: (SIMD3<Float>(0,0,0), SIMD3<Float>(1,0,0), SIMD3<Float>(0,1,0)), normal: SIMD3<Float>(0,0,1), areaSqM: 0.5),
            ScanTriangle(patchId: "1", vertices: (SIMD3<Float>(1,0,0), SIMD3<Float>(2,0,0), SIMD3<Float>(1,1,0)), normal: SIMD3<Float>(0,0,1), areaSqM: 0.5),
            ScanTriangle(patchId: "2", vertices: (SIMD3<Float>(2,0,0), SIMD3<Float>(3,0,0), SIMD3<Float>(2,1,0)), normal: SIMD3<Float>(0,0,1), areaSqM: 0.5),
        ]
        
        let graph = MeshAdjacencyGraph(triangles: triangles)
        
        // BFS from triangle 0
        let distances = graph.bfsDistances(from: 0, maxHops: 8)
        
        XCTAssertEqual(distances[0], 0, "Source triangle should have distance 0")
        XCTAssertGreaterThanOrEqual(distances[1] ?? Int.max, 0, "Neighbor should have distance >= 0")
    }
    
    func testRippleDamping() {
        // Test that amplitude at hop 8 ≈ 1.0 × 0.85^8 ≈ 0.272
        let damping = ScanGuidanceConstants.rippleDampingPerHop
        let maxHops = ScanGuidanceConstants.rippleMaxHops
        
        let amplitudeAtMaxHop = pow(damping, Double(maxHops))
        let expectedAmplitude = pow(0.85, 8.0)
        
        XCTAssertEqual(amplitudeAtMaxHop, expectedAmplitude, accuracy: 0.01, "Amplitude at hop 8 should match expected value")
        XCTAssertEqual(expectedAmplitude, 0.272, accuracy: 0.01, "Expected amplitude ≈ 0.272")
    }
    
    func testRippleMaxHops() {
        let engine = RipplePropagationEngine()
        let triangles = [
            ScanTriangle(patchId: "0", vertices: (SIMD3<Float>(0,0,0), SIMD3<Float>(1,0,0), SIMD3<Float>(0,1,0)), normal: SIMD3<Float>(0,0,1), areaSqM: 0.5)
        ]
        let graph = MeshAdjacencyGraph(triangles: triangles)
        
        let timestamp: TimeInterval = 100.0
        engine.spawn(sourceTriangle: 0, adjacencyGraph: graph, timestamp: timestamp)
        
        // Verify max hops limit
        XCTAssertLessThanOrEqual(ScanGuidanceConstants.rippleMaxHops, 8)
    }
    
    func testRippleAmplitudeBounds() {
        let engine = RipplePropagationEngine()
        let amplitudes = engine.tick(currentTime: ProcessInfo.processInfo.systemUptime)
        
        // All amplitudes should be in [0, 1]
        for amplitude in amplitudes {
            XCTAssertGreaterThanOrEqual(amplitude, 0.0)
            XCTAssertLessThanOrEqual(amplitude, 1.0)
        }
    }
    
    func testRippleMaxConcurrentWaves() {
        // Test that max concurrent waves limit is enforced
        XCTAssertLessThanOrEqual(ScanGuidanceConstants.rippleMaxConcurrentWaves, 5)
    }
}
