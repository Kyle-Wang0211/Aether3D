//
// AdjacencyProvider.swift
// Aether3D
//
// PR#7 Scan Guidance UI — Adjacency Provider Protocol
// Shared interface for adjacency graph implementations
// Pure algorithm — Foundation + simd only
//

import Foundation
#if canImport(simd)
import simd
#endif

/// Protocol for mesh adjacency providers
///
/// Both MeshAdjacencyGraph (O(n²)) and SpatialHashAdjacency (O(n)) conform to this.
/// Consumers (FlipAnimationController, RipplePropagationEngine) accept this protocol
/// instead of a concrete type, enabling seamless engine swapping.
public protocol AdjacencyProvider {
    /// Get neighbor triangle indices
    func neighbors(of triangleIndex: Int) -> [Int]

    /// BFS distances from a set of source triangles
    func bfsDistances(from sources: Set<Int>, maxHops: Int) -> [Int: Int]

    /// BFS distances from a single source triangle
    func bfsDistances(from sourceIndex: Int, maxHops: Int) -> [Int: Int]

    /// Find longest edge of a triangle
    func longestEdge(of triangle: ScanTriangle) -> (SIMD3<Float>, SIMD3<Float>)

    /// Total triangle count
    var triangleCount: Int { get }
}

// MARK: - Retroactive Conformance

/// MeshAdjacencyGraph already implements all methods with matching signatures
extension MeshAdjacencyGraph: AdjacencyProvider {}

/// SpatialHashAdjacency already implements all methods with matching signatures
/// (conformance declared here so both engines are interchangeable from a single import)
// Note: SpatialHashAdjacency declares conformance in its own file
