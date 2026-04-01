//
// SpatialHashAdjacency.swift
// Aether3D
//
// PR#7 Scan Guidance UI — O(n) Spatial Hash Adjacency Engine
// Drop-in high-performance replacement for MeshAdjacencyGraph
// Pure algorithm — Foundation + simd only, NO platform imports
//

import Foundation
import CAetherNativeBridge
#if canImport(simd)
import simd
#endif

/// O(n) spatial-hash-based mesh adjacency engine
///
/// Replaces MeshAdjacencyGraph's O(n²) brute-force construction with spatial hashing.
/// API is identical to MeshAdjacencyGraph for drop-in compatibility via AdjacencyProvider.
///
/// Performance:
///   - Construction: O(n × k) where k ≈ 6 (avg bucket density) → effectively O(n)
///   - neighbors(): O(1) lookup
///   - bfsDistances(): O(n + m) where m = edges
///   - longestEdge(): O(1)
///   - Supports 50,000+ triangles at interactive frame rates
///
/// The spatial hash quantizes vertices to a configurable grid resolution (default 0.1mm).
/// Two triangles sharing 2+ vertices within epsilon tolerance are considered adjacent.
public final class SpatialHashAdjacency: AdjacencyProvider {

    // MARK: - Configuration

    /// Grid cell size in meters (0.1mm = finest LiDAR resolution)
    /// Smaller = more precise vertex matching, larger = more tolerant
    private let cellSize: Float

    /// Epsilon for vertex equality (meters)
    private let epsilon: Float

    // MARK: - State

    /// Adjacency list: triangle index → [neighbor triangle indices]
    private var adjacencyList: [[Int]]
    private var adjacencyOffsets: [UInt32]
    private var adjacencyNeighbors: [UInt32]

    /// Stored triangles reference
    private let triangles: [ScanTriangle]

    // MARK: - Init

    /// Construct adjacency graph using spatial hashing — O(n)
    ///
    /// - Parameters:
    ///   - triangles: Input mesh triangles
    ///   - cellSize: Spatial hash grid cell size in meters (default: 0.0001 = 0.1mm)
    ///   - epsilon: Vertex equality tolerance in meters (default: 1e-5)
    public init(
        triangles: [ScanTriangle],
        cellSize: Float = 0.0001,
        epsilon: Float = 1e-5
    ) {
        self.triangles = triangles
        self.cellSize = cellSize
        self.epsilon = epsilon
        self.adjacencyList = Array(repeating: [], count: triangles.count)
        self.adjacencyOffsets = Array(repeating: 0, count: max(1, triangles.count + 1))
        self.adjacencyNeighbors = []
        buildWithSpatialHash()
    }

    // MARK: - Public API (mirrors MeshAdjacencyGraph exactly)

    /// Get neighbors of a triangle
    ///
    /// - Parameter triangleIndex: Triangle index
    /// - Returns: Array of neighbor triangle indices
    public func neighbors(of triangleIndex: Int) -> [Int] {
        guard triangleIndex >= 0 && triangleIndex < adjacencyList.count else { return [] }
        return adjacencyList[triangleIndex]
    }

    /// BFS distances from source triangles
    ///
    /// - Parameters:
    ///   - sources: Set of source triangle indices
    ///   - maxHops: Maximum number of hops (default: Int.max)
    /// - Returns: Dictionary mapping triangle index → distance (hops)
    public func bfsDistances(from sources: Set<Int>, maxHops: Int = Int.max) -> [Int: Int] {
        let clampedHops = maxHops < 0 ? 0 : maxHops
        let validSources = sources.compactMap { source -> UInt32? in
            guard source >= 0 && source < triangles.count else { return nil }
            return UInt32(source)
        }
        if !adjacencyOffsets.isEmpty && triangles.count > 0 {
            var outDistances = Array(repeating: Int32(-1), count: triangles.count)
            let rc = adjacencyOffsets.withUnsafeBufferPointer { offsetsPtr in
                adjacencyNeighbors.withUnsafeBufferPointer { neighborsPtr in
                    validSources.withUnsafeBufferPointer { sourcesPtr in
                        outDistances.withUnsafeMutableBufferPointer { distancesPtr in
                            aether_spatial_adjacency_bfs(
                                offsetsPtr.baseAddress,
                                neighborsPtr.baseAddress,
                                Int32(triangles.count),
                                sourcesPtr.baseAddress,
                                Int32(validSources.count),
                                Int32(clampedHops),
                                distancesPtr.baseAddress
                            )
                        }
                    }
                }
            }
            if rc == 0 {
                var distances: [Int: Int] = [:]
                distances.reserveCapacity(triangles.count)
                for (index, value) in outDistances.enumerated() where value >= 0 {
                    distances[index] = Int(value)
                }
                return distances
            }
        }
        var distances: [Int: Int] = [:]
        for source in sources where source >= 0 && source < triangles.count {
            distances[source] = 0
        }
        return distances
    }

    /// BFS distances from a single source triangle
    ///
    /// - Parameters:
    ///   - sourceIndex: Source triangle index
    ///   - maxHops: Maximum number of hops (default: Int.max)
    /// - Returns: Dictionary mapping triangle index → distance (hops)
    public func bfsDistances(from sourceIndex: Int, maxHops: Int = Int.max) -> [Int: Int] {
        return bfsDistances(from: [sourceIndex], maxHops: maxHops)
    }

    /// Find longest edge of a triangle
    ///
    /// - Parameter triangle: Triangle to analyze
    /// - Returns: Tuple of (start vertex, end vertex) of longest edge
    public func longestEdge(of triangle: ScanTriangle) -> (SIMD3<Float>, SIMD3<Float>) {
        let (v0, v1, v2) = triangle.vertices
        var native = aether_scan_triangle_t(
            a: aether_float3_t(x: v0.x, y: v0.y, z: v0.z),
            b: aether_float3_t(x: v1.x, y: v1.y, z: v1.z),
            c: aether_float3_t(x: v2.x, y: v2.y, z: v2.z)
        )
        var start = aether_float3_t()
        var end = aether_float3_t()
        let rc = withUnsafePointer(to: &native) { nativePtr in
            aether_scan_triangle_longest_edge(
                nativePtr,
                &start,
                &end,
                nil
            )
        }
        if rc == 0 {
            return (
                SIMD3<Float>(start.x, start.y, start.z),
                SIMD3<Float>(end.x, end.y, end.z)
            )
        }

        let edge0Len = simdLengthSquared(v1 - v0)
        let edge1Len = simdLengthSquared(v2 - v1)
        let edge2Len = simdLengthSquared(v0 - v2)
        if edge0Len >= edge1Len && edge0Len >= edge2Len {
            return (v0, v1)
        }
        if edge1Len >= edge2Len {
            return (v1, v2)
        }
        return (v2, v0)
    }

    /// Total number of triangles
    public var triangleCount: Int {
        return triangles.count
    }

    // MARK: - Spatial Hash Construction (O(n))

    /// Build adjacency graph using spatial hashing
    ///
    /// Algorithm:
    /// 1. Hash each vertex to a grid cell → each vertex maps to a bucket
    /// 2. Triangles in the same bucket(s) are adjacency CANDIDATES
    /// 3. Only check candidates for shared vertices → O(n × k) where k = avg bucket density ≈ constant
    ///
    /// For LiDAR meshes (spatially well-distributed), k ≈ 2-6 per bucket.
    /// Total comparisons: O(n × k²/n) ≈ O(n × constant) → effectively O(n).
    private func buildWithSpatialHash() {
        guard !triangles.isEmpty else {
            adjacencyOffsets = [0]
            adjacencyNeighbors = []
            return
        }
        _ = buildWithNativeSpatialHash()
    }

    private func buildWithNativeSpatialHash() -> Bool {
        var nativeTriangles = Array(repeating: aether_scan_triangle_t(), count: triangles.count)
        for (index, tri) in triangles.enumerated() {
            let (v0, v1, v2) = tri.vertices
            nativeTriangles[index].a = aether_float3_t(x: v0.x, y: v0.y, z: v0.z)
            nativeTriangles[index].b = aether_float3_t(x: v1.x, y: v1.y, z: v1.z)
            nativeTriangles[index].c = aether_float3_t(x: v2.x, y: v2.y, z: v2.z)
        }

        var offsets = Array(repeating: UInt32(0), count: triangles.count + 1)
        var requiredNeighbors: Int32 = 0

        let probeRC = nativeTriangles.withUnsafeBufferPointer { triPtr in
            offsets.withUnsafeMutableBufferPointer { offsetsPtr in
                aether_spatial_adjacency_build(
                    triPtr.baseAddress,
                    Int32(triangles.count),
                    cellSize,
                    epsilon,
                    offsetsPtr.baseAddress,
                    nil,
                    &requiredNeighbors
                )
            }
        }
        guard probeRC == -3 || probeRC == 0 else {
            return false
        }

        var neighbors = Array(repeating: UInt32(0), count: max(0, Int(requiredNeighbors)))
        let buildRC = nativeTriangles.withUnsafeBufferPointer { triPtr in
            offsets.withUnsafeMutableBufferPointer { offsetsPtr in
                neighbors.withUnsafeMutableBufferPointer { neighborsPtr in
                    aether_spatial_adjacency_build(
                        triPtr.baseAddress,
                        Int32(triangles.count),
                        cellSize,
                        epsilon,
                        offsetsPtr.baseAddress,
                        neighborsPtr.baseAddress,
                        &requiredNeighbors
                    )
                }
            }
        }
        guard buildRC == 0 else {
            return false
        }

        adjacencyOffsets = offsets
        adjacencyNeighbors = Array(neighbors.prefix(Int(requiredNeighbors)))
        adjacencyList = Array(repeating: [], count: triangles.count)
        for tri in 0..<triangles.count {
            let begin = Int(adjacencyOffsets[tri])
            let end = Int(adjacencyOffsets[tri + 1])
            if begin < 0 || end < begin || end > adjacencyNeighbors.count { continue }
            adjacencyList[tri] = adjacencyNeighbors[begin..<end].map { Int($0) }
        }
        return true
    }
}
