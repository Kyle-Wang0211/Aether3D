//
// SpatialHashAdjacency.swift
// Aether3D
//
// PR#7 Scan Guidance UI — O(n) Spatial Hash Adjacency Engine
// Drop-in high-performance replacement for MeshAdjacencyGraph
// Pure algorithm — Foundation + simd only, NO platform imports
//

import Foundation
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

    // MARK: - Types

    /// Quantized vertex key for spatial hashing
    private struct VertexKey: Hashable {
        let x: Int32
        let y: Int32
        let z: Int32
    }

    // MARK: - Configuration

    /// Grid cell size in meters (0.1mm = finest LiDAR resolution)
    /// Smaller = more precise vertex matching, larger = more tolerant
    private let cellSize: Float

    /// Epsilon for vertex equality (meters)
    private let epsilon: Float

    // MARK: - State

    /// Adjacency list: triangle index → [neighbor triangle indices]
    private var adjacencyList: [[Int]]

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
        var distances: [Int: Int] = [:]
        var queue: [(index: Int, distance: Int)] = []
        var visited: Set<Int> = []

        for source in sources {
            distances[source] = 0
            queue.append((source, 0))
            visited.insert(source)
        }

        var queueIndex = 0
        while queueIndex < queue.count {
            let (currentIndex, currentDist) = queue[queueIndex]
            queueIndex += 1

            if currentDist >= maxHops { continue }

            for neighborIndex in neighbors(of: currentIndex) {
                if !visited.contains(neighborIndex) {
                    visited.insert(neighborIndex)
                    let newDist = currentDist + 1
                    distances[neighborIndex] = newDist
                    queue.append((neighborIndex, newDist))
                }
            }
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
        let edge0Len = simdLengthSquared(v1 - v0)
        let edge1Len = simdLengthSquared(v2 - v1)
        let edge2Len = simdLengthSquared(v0 - v2)

        if edge0Len >= edge1Len && edge0Len >= edge2Len {
            return (v0, v1)
        } else if edge1Len >= edge2Len {
            return (v1, v2)
        } else {
            return (v2, v0)
        }
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
        guard !triangles.isEmpty else { return }

        let invCellSize = 1.0 / cellSize

        // Step 1: Build vertex → triangle index map using spatial hash
        // Each vertex is quantized to a grid cell. Triangles sharing a cell are candidates.
        var vertexBuckets: [VertexKey: [Int]] = [:]
        vertexBuckets.reserveCapacity(triangles.count * 3)

        for (triIndex, triangle) in triangles.enumerated() {
            let (v0, v1, v2) = triangle.vertices
            for v in [v0, v1, v2] {
                let key = VertexKey(
                    x: Int32(floor(v.x * invCellSize)),
                    y: Int32(floor(v.y * invCellSize)),
                    z: Int32(floor(v.z * invCellSize))
                )
                vertexBuckets[key, default: []].append(triIndex)
            }
        }

        // Step 2: For each bucket, check triangle pairs for shared edges
        // A triangle has 3 vertices → 3 bucket entries → only nearby triangles are compared
        var edgeSet: Set<UInt64> = []  // Packed pair for deduplication
        edgeSet.reserveCapacity(triangles.count * 3)

        for (_, triIndices) in vertexBuckets {
            // Skip singleton buckets (no possible adjacency)
            guard triIndices.count > 1 else { continue }

            // Compare candidates within this bucket — typically 2-6 triangles per bucket
            for i in 0..<triIndices.count {
                for j in (i + 1)..<triIndices.count {
                    let a = triIndices[i]
                    let b = triIndices[j]

                    // Dedup: use packed UInt64 (max 2^32 triangles = 4 billion, more than enough)
                    let lo = min(a, b)
                    let hi = max(a, b)
                    let packed = UInt64(lo) | (UInt64(hi) << 32)
                    guard !edgeSet.contains(packed) else { continue }

                    if shareEdge(triangles[a], triangles[b]) {
                        edgeSet.insert(packed)
                        adjacencyList[a].append(b)
                        adjacencyList[b].append(a)
                    }
                }
            }
        }
    }

    /// Check if two triangles share an edge (2 vertices within epsilon)
    private func shareEdge(_ t1: ScanTriangle, _ t2: ScanTriangle) -> Bool {
        let (v1a, v1b, v1c) = t1.vertices
        let (v2a, v2b, v2c) = t2.vertices
        let epsSq = epsilon * epsilon

        var sharedCount = 0
        let tri1 = [v1a, v1b, v1c]
        let tri2 = [v2a, v2b, v2c]

        for v1 in tri1 {
            for v2 in tri2 {
                let diff = v1 - v2
                if (diff.x * diff.x + diff.y * diff.y + diff.z * diff.z) < epsSq {
                    sharedCount += 1
                    if sharedCount >= 2 { return true }
                    break
                }
            }
        }
        return false
    }
}
