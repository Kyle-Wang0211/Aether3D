//
// MeshAdjacencyGraph.swift
// Aether3D
//
// PR#7 Scan Guidance UI — Mesh Adjacency Graph
// Compatibility wrapper over native-backed SpatialHashAdjacency.
//

import Foundation
#if canImport(simd)
import simd
#endif

/// Edge in the mesh adjacency graph.
public struct Edge: Hashable {
    public let triangle1: Int
    public let triangle2: Int

    public init(triangle1: Int, triangle2: Int) {
        self.triangle1 = triangle1
        self.triangle2 = triangle2
    }
}

/// Legacy adjacency provider kept for API compatibility.
/// The implementation is delegated to `SpatialHashAdjacency` so the
/// heavy graph build/BFS path stays in core native code.
public final class MeshAdjacencyGraph {
    private let engine: SpatialHashAdjacency

    public init(
        triangles: [ScanTriangle],
        cellSize: Float = 0.0001,
        epsilon: Float = 1e-5
    ) {
        self.engine = SpatialHashAdjacency(
            triangles: triangles,
            cellSize: cellSize,
            epsilon: epsilon
        )
    }

    public func neighbors(of triangleIndex: Int) -> [Int] {
        engine.neighbors(of: triangleIndex)
    }

    public func bfsDistances(from sources: Set<Int>, maxHops: Int = Int.max) -> [Int: Int] {
        engine.bfsDistances(from: sources, maxHops: maxHops)
    }

    public func bfsDistances(from sourceIndex: Int, maxHops: Int = Int.max) -> [Int: Int] {
        engine.bfsDistances(from: sourceIndex, maxHops: maxHops)
    }

    public func longestEdge(of triangle: ScanTriangle) -> (SIMD3<Float>, SIMD3<Float>) {
        engine.longestEdge(of: triangle)
    }

    public var triangleCount: Int {
        engine.triangleCount
    }
}
