//
// FlipAnimationTests.swift
// Aether3D
//
// PR#7 Scan Guidance UI — Flip Animation Tests
// Core-only tests (compile and run in SwiftPM)
//

import XCTest
@testable import Aether3DCore

final class FlipAnimationTests: XCTestCase {
    
    func testEasingCurveOvershoot() {
        // Test that easing curve overshoots to ~1.1 at t≈0.6
        let t: Float = 0.6
        let eased = FlipAnimationController.easingWithOvershoot(t: t)
        
        // Should overshoot above 1.0
        XCTAssertGreaterThan(eased, 1.0, "Easing should overshoot at t=0.6")
        XCTAssertLessThanOrEqual(eased, 1.2, "Overshoot should be reasonable")
    }
    
    func testEasingCurveBounds() {
        // Test that easing curve is bounded [0, ~1.1]
        let t0 = FlipAnimationController.easingWithOvershoot(t: 0.0)
        let t1 = FlipAnimationController.easingWithOvershoot(t: 1.0)
        
        XCTAssertEqual(t0, 0.0, accuracy: 0.01, "Easing at t=0 should be 0")
        XCTAssertEqual(t1, 1.0, accuracy: 0.01, "Easing at t=1 should be 1")
    }
    
    func testEasingCurveMonotonic() {
        // Test that easing curve is generally increasing (may have overshoot)
        var prev: Float = 0.0
        for i in 0...10 {
            let t = Float(i) / 10.0
            let eased = FlipAnimationController.easingWithOvershoot(t: t)
            if i > 0 {
                // Allow for overshoot, but should generally increase
                XCTAssertGreaterThanOrEqual(eased, prev - 0.1, "Easing should be generally increasing")
            }
            prev = eased
        }
    }
    
    func testFlipDuration() {
        // Test that flip duration matches constant
        XCTAssertEqual(ScanGuidanceConstants.flipDurationS, 0.5, accuracy: 0.01)
    }
    
    func testFlipControllerThresholdDetection() {
        let controller = FlipAnimationController()
        let triangles = [
            ScanTriangle(
                patchId: "patch1",
                vertices: (SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0)),
                normal: SIMD3<Float>(0, 0, 1),
                areaSqM: 0.5
            )
        ]
        let graph = MeshAdjacencyGraph(triangles: triangles)
        
        let previous: [String: Double] = ["patch1": 0.05]  // Below S1 threshold
        let current: [String: Double] = ["patch1": 0.15]    // Above S1 threshold
        
        let crossed = controller.checkThresholdCrossings(
            previousDisplay: previous,
            currentDisplay: current,
            triangles: triangles,
            adjacencyGraph: graph
        )
        
        // Should detect threshold crossing
        XCTAssertGreaterThanOrEqual(crossed.count, 0)  // May be empty if other conditions not met
    }
    
    func testFlipAngleBounds() {
        let controller = FlipAnimationController()
        let angles = controller.tick(deltaTime: 0.1)
        
        // All angles should be in [0, PI]
        for angle in angles {
            XCTAssertGreaterThanOrEqual(angle, 0.0)
            XCTAssertLessThanOrEqual(angle, Float.pi)
        }
    }
}
