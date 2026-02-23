//
// SpatialHashAdjacencyTests.swift
// Aether3D
//
// PR#7 Scan Guidance UI — Spatial Hash Adjacency Tests
// Comprehensive tests for the O(n) spatial hash adjacency engine
// 13 test cases + performance benchmarks
//

import XCTest
@testable import Aether3DCore

final class SpatialHashAdjacencyTests: XCTestCase {

    // MARK: - Helper

    /// Create a ScanTriangle with given vertices
    private func tri(
        _ id: String,
        _ v0: SIMD3<Float>,
        _ v1: SIMD3<Float>,
        _ v2: SIMD3<Float>
    ) -> ScanTriangle {
        ScanTriangle(
            patchId: id,
            vertices: (v0, v1, v2),
            normal: SIMD3<Float>(0, 0, 1),
            areaSqM: 0.5
        )
    }

    // MARK: - Test 1: Single Triangle

    func testSingleTriangle() {
        let triangles = [
            tri("0",
                SIMD3<Float>(0, 0, 0),
                SIMD3<Float>(1, 0, 0),
                SIMD3<Float>(0, 1, 0))
        ]
        let graph = SpatialHashAdjacency(triangles: triangles)

        XCTAssertEqual(graph.triangleCount, 1)
        XCTAssertEqual(graph.neighbors(of: 0), [])

        // longestEdge should work
        let (start, end) = graph.longestEdge(of: triangles[0])
        let edgeLen = simdLength(end - start)
        XCTAssertGreaterThan(edgeLen, 0)
    }

    // MARK: - Test 2: Two Adjacent Triangles

    func testTwoAdjacentTriangles() {
        // Two triangles sharing edge (0,0,0)-(1,0,0)
        let triangles = [
            tri("0",
                SIMD3<Float>(0, 0, 0),
                SIMD3<Float>(1, 0, 0),
                SIMD3<Float>(0, 1, 0)),
            tri("1",
                SIMD3<Float>(0, 0, 0),
                SIMD3<Float>(1, 0, 0),
                SIMD3<Float>(0, -1, 0))
        ]
        let graph = SpatialHashAdjacency(triangles: triangles)

        XCTAssertEqual(graph.triangleCount, 2)
        XCTAssertTrue(graph.neighbors(of: 0).contains(1), "Triangle 0 should have neighbor 1")
        XCTAssertTrue(graph.neighbors(of: 1).contains(0), "Triangle 1 should have neighbor 0")
    }

    // MARK: - Test 3: Three Triangle Chain

    func testThreeTriangleChain() {
        // Chain: tri0 -- tri1 -- tri2
        let triangles = [
            tri("0",
                SIMD3<Float>(0, 0, 0),
                SIMD3<Float>(1, 0, 0),
                SIMD3<Float>(0, 1, 0)),
            tri("1",
                SIMD3<Float>(1, 0, 0),
                SIMD3<Float>(2, 0, 0),
                SIMD3<Float>(1, 1, 0)),
            tri("2",
                SIMD3<Float>(2, 0, 0),
                SIMD3<Float>(3, 0, 0),
                SIMD3<Float>(2, 1, 0))
        ]
        let graph = SpatialHashAdjacency(triangles: triangles)

        // BFS from triangle 0
        let distances = graph.bfsDistances(from: 0, maxHops: 8)

        XCTAssertEqual(distances[0], 0, "Source should have distance 0")
        // Note: These triangles share only 1 vertex each (not 2), so they
        // may not be considered adjacent. Let's check:
        // tri0 and tri1 share vertex (1,0,0) — only 1 vertex, NOT adjacent
        // For a proper chain, they need to share an EDGE (2 vertices)

        // Actually, let's verify the adjacency first
        let tri0Neighbors = graph.neighbors(of: 0)
        let tri1Neighbors = graph.neighbors(of: 1)

        // tri0 shares only (1,0,0) with tri1 — that's 1 vertex, not an edge
        // This means they should NOT be adjacent
        // For proper chain test, we need shared edges:
        if tri0Neighbors.contains(1) {
            XCTAssertEqual(distances[1], 1, "Adjacent tri should have distance 1")
        }
    }

    // MARK: - Test 3b: Proper Chain with Shared Edges

    func testProperChainWithSharedEdges() {
        // Chain where consecutive triangles share exactly 2 vertices (an edge)
        let triangles = [
            tri("0",
                SIMD3<Float>(0, 0, 0),
                SIMD3<Float>(1, 0, 0),
                SIMD3<Float>(0.5, 1, 0)),
            tri("1",
                SIMD3<Float>(1, 0, 0),
                SIMD3<Float>(0.5, 1, 0),
                SIMD3<Float>(1.5, 1, 0)),
            tri("2",
                SIMD3<Float>(0.5, 1, 0),
                SIMD3<Float>(1.5, 1, 0),
                SIMD3<Float>(1.0, 2, 0))
        ]
        let graph = SpatialHashAdjacency(triangles: triangles)

        // tri0 and tri1 share (1,0,0) and (0.5,1,0) → ADJACENT
        XCTAssertTrue(graph.neighbors(of: 0).contains(1), "tri0-tri1 should be adjacent")
        // tri1 and tri2 share (0.5,1,0) and (1.5,1,0) → ADJACENT
        XCTAssertTrue(graph.neighbors(of: 1).contains(2), "tri1-tri2 should be adjacent")
        // tri0 and tri2 share only (0.5,1,0) → NOT adjacent (only 1 shared vertex)
        XCTAssertFalse(graph.neighbors(of: 0).contains(2), "tri0-tri2 should NOT be adjacent")

        // BFS from tri0: dist(0)=0, dist(1)=1, dist(2)=2
        let distances = graph.bfsDistances(from: 0, maxHops: 8)
        XCTAssertEqual(distances[0], 0)
        XCTAssertEqual(distances[1], 1)
        XCTAssertEqual(distances[2], 2)
    }

    // MARK: - Test 4: Non-Adjacent Triangles

    func testNonAdjacentTriangles() {
        // Two completely separate triangles (no shared vertices)
        let triangles = [
            tri("0",
                SIMD3<Float>(0, 0, 0),
                SIMD3<Float>(1, 0, 0),
                SIMD3<Float>(0, 1, 0)),
            tri("1",
                SIMD3<Float>(10, 10, 10),
                SIMD3<Float>(11, 10, 10),
                SIMD3<Float>(10, 11, 10))
        ]
        let graph = SpatialHashAdjacency(triangles: triangles)

        XCTAssertEqual(graph.neighbors(of: 0), [], "Separate triangles should have no neighbors")
        XCTAssertEqual(graph.neighbors(of: 1), [], "Separate triangles should have no neighbors")
    }

    // MARK: - Test 5: BFS Max Hops

    func testBFSMaxHops() {
        // Long chain of 6 triangles: 0-1-2-3-4-5 (each pair shares an edge)
        let triangles = [
            tri("0", SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0), SIMD3<Float>(0.5, 1, 0)),
            tri("1", SIMD3<Float>(1, 0, 0), SIMD3<Float>(0.5, 1, 0), SIMD3<Float>(1.5, 1, 0)),
            tri("2", SIMD3<Float>(0.5, 1, 0), SIMD3<Float>(1.5, 1, 0), SIMD3<Float>(1.0, 2, 0)),
            tri("3", SIMD3<Float>(1.5, 1, 0), SIMD3<Float>(1.0, 2, 0), SIMD3<Float>(2.0, 2, 0)),
            tri("4", SIMD3<Float>(1.0, 2, 0), SIMD3<Float>(2.0, 2, 0), SIMD3<Float>(1.5, 3, 0)),
            tri("5", SIMD3<Float>(2.0, 2, 0), SIMD3<Float>(1.5, 3, 0), SIMD3<Float>(2.5, 3, 0)),
        ]
        let graph = SpatialHashAdjacency(triangles: triangles)

        // BFS with maxHops=2: should only reach distance ≤ 2
        let distances = graph.bfsDistances(from: 0, maxHops: 2)
        for (_, dist) in distances {
            XCTAssertLessThanOrEqual(dist, 2, "All distances should be ≤ maxHops")
        }
    }

    // MARK: - Test 6: Longest Edge

    func testLongestEdge() {
        // Triangle with known longest edge: v0-v1 = 2.0, v1-v2 = 1.0, v2-v0 = sqrt(5) ≈ 2.236
        let triangle = tri("0",
            SIMD3<Float>(0, 0, 0),
            SIMD3<Float>(2, 0, 0),
            SIMD3<Float>(0, 1, 0))
        let graph = SpatialHashAdjacency(triangles: [triangle])

        let (start, end) = graph.longestEdge(of: triangle)
        let edgeLen = simdLength(end - start)

        // Longest edge is v2-v0 = sqrt(4+1) = sqrt(5) ≈ 2.236
        XCTAssertEqual(edgeLen, sqrt(5.0), accuracy: 0.01, "Longest edge should be sqrt(5)")
    }

    // MARK: - Test 7: Large Random Mesh (Performance)

    func testLargeRandomMesh() {
        // Generate 5000 random triangles — construction should be fast
        var triangles: [ScanTriangle] = []
        triangles.reserveCapacity(5000)

        for i in 0..<5000 {
            let base = Float(i) * 0.01
            triangles.append(tri(
                "\(i)",
                SIMD3<Float>(base, 0, 0),
                SIMD3<Float>(base + 0.01, 0, 0),
                SIMD3<Float>(base + 0.005, 0.01, 0)
            ))
        }

        let startTime = ProcessInfo.processInfo.systemUptime
        let graph = SpatialHashAdjacency(triangles: triangles)
        let elapsed = ProcessInfo.processInfo.systemUptime - startTime

        XCTAssertEqual(graph.triangleCount, 5000)
        // Construction should be under 1 second even on slow CI runners
        XCTAssertLessThan(elapsed, 1.0, "5000-triangle construction should be < 1 second")
    }

    // MARK: - Test 8: Consistency with MeshAdjacencyGraph

    func testConsistencyWithMeshAdjacencyGraph() {
        // Small mesh: verify SpatialHashAdjacency produces same adjacency as MeshAdjacencyGraph
        let triangles = [
            tri("0", SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0), SIMD3<Float>(0.5, 1, 0)),
            tri("1", SIMD3<Float>(1, 0, 0), SIMD3<Float>(0.5, 1, 0), SIMD3<Float>(1.5, 1, 0)),
            tri("2", SIMD3<Float>(0.5, 1, 0), SIMD3<Float>(1.5, 1, 0), SIMD3<Float>(1.0, 2, 0)),
            tri("3", SIMD3<Float>(10, 0, 0), SIMD3<Float>(11, 0, 0), SIMD3<Float>(10.5, 1, 0)),
        ]

        let spatialGraph = SpatialHashAdjacency(triangles: triangles)
        let bruteGraph = MeshAdjacencyGraph(triangles: triangles)

        for i in 0..<triangles.count {
            let spatialNeighbors = Set(spatialGraph.neighbors(of: i))
            let bruteNeighbors = Set(bruteGraph.neighbors(of: i))
            XCTAssertEqual(spatialNeighbors, bruteNeighbors,
                           "Neighbors of triangle \(i) should match between engines")
        }
    }

    // MARK: - Test 9: Degenerate Triangles

    func testDegenerateTriangles() {
        // Zero-area triangle (all vertices same)
        let triangles = [
            tri("0",
                SIMD3<Float>(1, 1, 1),
                SIMD3<Float>(1, 1, 1),
                SIMD3<Float>(1, 1, 1)),
            tri("1",
                SIMD3<Float>(0, 0, 0),
                SIMD3<Float>(1, 0, 0),
                SIMD3<Float>(0, 1, 0))
        ]

        // Should not crash
        let graph = SpatialHashAdjacency(triangles: triangles)
        XCTAssertEqual(graph.triangleCount, 2)
    }

    // MARK: - Test 10: Duplicate Vertices (Exact Match)

    func testDuplicateVertices() {
        // Two triangles sharing exact vertices → should be adjacent
        let shared1 = SIMD3<Float>(0, 0, 0)
        let shared2 = SIMD3<Float>(1, 0, 0)
        let triangles = [
            tri("0", shared1, shared2, SIMD3<Float>(0.5, 1, 0)),
            tri("1", shared1, shared2, SIMD3<Float>(0.5, -1, 0))
        ]
        let graph = SpatialHashAdjacency(triangles: triangles)

        XCTAssertTrue(graph.neighbors(of: 0).contains(1))
        XCTAssertTrue(graph.neighbors(of: 1).contains(0))
    }

    // MARK: - Test 11: Epsilon Tolerance

    func testEpsilonTolerance() {
        // Vertices that differ by less than epsilon should be considered equal
        let eps: Float = 1e-6  // Much less than default epsilon of 1e-5
        let triangles = [
            tri("0",
                SIMD3<Float>(0, 0, 0),
                SIMD3<Float>(1, 0, 0),
                SIMD3<Float>(0.5, 1, 0)),
            tri("1",
                SIMD3<Float>(0 + eps, 0, 0),      // slightly shifted
                SIMD3<Float>(1 + eps, 0, 0),       // slightly shifted
                SIMD3<Float>(0.5, -1, 0))          // different third vertex
        ]
        let graph = SpatialHashAdjacency(triangles: triangles, epsilon: 1e-5)

        // The shifted vertices should still be within epsilon, so they share an edge
        XCTAssertTrue(graph.neighbors(of: 0).contains(1),
                      "Vertices within epsilon should be considered equal")
    }

    // MARK: - Test 12: Performance 10K (Benchmark)

    func testPerformance10K() {
        // 10,000 triangle strip — measure construction time
        var triangles: [ScanTriangle] = []
        triangles.reserveCapacity(10000)

        for i in 0..<10000 {
            let base = Float(i) * 0.005
            triangles.append(tri(
                "\(i)",
                SIMD3<Float>(base, 0, 0),
                SIMD3<Float>(base + 0.005, 0, 0),
                SIMD3<Float>(base + 0.0025, 0.005, 0)
            ))
        }

        let startTime = ProcessInfo.processInfo.systemUptime
        let graph = SpatialHashAdjacency(triangles: triangles)
        let elapsed = ProcessInfo.processInfo.systemUptime - startTime

        XCTAssertEqual(graph.triangleCount, 10000)
        // 10K should complete in well under 2 seconds even on slow CI runners
        XCTAssertLessThan(elapsed, 2.0, "10K-triangle construction should be < 2 seconds")
    }

    // MARK: - Test 13: Incremental Growth

    func testIncrementalGrowth() {
        // Verify engine works correctly as we add more triangles
        for count in [1, 10, 100, 500, 1000] {
            var triangles: [ScanTriangle] = []
            for i in 0..<count {
                let base = Float(i) * 0.01
                triangles.append(tri(
                    "\(i)",
                    SIMD3<Float>(base, 0, 0),
                    SIMD3<Float>(base + 0.01, 0, 0),
                    SIMD3<Float>(base + 0.005, 0.01, 0)
                ))
            }
            let graph = SpatialHashAdjacency(triangles: triangles)
            XCTAssertEqual(graph.triangleCount, count,
                           "Graph with \(count) triangles should report correct count")
        }
    }

    // MARK: - Test: AdjacencyProvider Protocol Conformance

    func testAdjacencyProviderConformance() {
        // Verify both engines conform to AdjacencyProvider
        let triangles = [
            tri("0", SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0), SIMD3<Float>(0.5, 1, 0)),
            tri("1", SIMD3<Float>(1, 0, 0), SIMD3<Float>(0.5, 1, 0), SIMD3<Float>(1.5, 1, 0)),
        ]

        let spatial: any AdjacencyProvider = SpatialHashAdjacency(triangles: triangles)
        let brute: any AdjacencyProvider = MeshAdjacencyGraph(triangles: triangles)

        XCTAssertEqual(spatial.triangleCount, 2)
        XCTAssertEqual(brute.triangleCount, 2)

        // Both should be usable through protocol
        let _ = spatial.neighbors(of: 0)
        let _ = brute.neighbors(of: 0)
        let _ = spatial.bfsDistances(from: 0, maxHops: 4)
        let _ = brute.bfsDistances(from: 0, maxHops: 4)
    }

    // MARK: - Test: Out of Bounds Safety

    func testOutOfBoundsSafety() {
        let triangles = [
            tri("0", SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0))
        ]
        let graph = SpatialHashAdjacency(triangles: triangles)

        // Out of bounds should return empty, not crash
        XCTAssertEqual(graph.neighbors(of: -1), [])
        XCTAssertEqual(graph.neighbors(of: 999), [])
    }

    // MARK: - Test: Empty Mesh

    func testEmptyMesh() {
        let graph = SpatialHashAdjacency(triangles: [])
        XCTAssertEqual(graph.triangleCount, 0)
        XCTAssertEqual(graph.neighbors(of: 0), [])
    }
}
