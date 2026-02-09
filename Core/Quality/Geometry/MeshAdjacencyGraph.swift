//
// MeshAdjacencyGraph.swift
// Aether3D
//
// PR#7 Scan Guidance UI — Mesh Adjacency Graph
// Pure algorithm — Foundation + simd only
// Phase 3: Full implementation
//

import Foundation
#if canImport(simd)
import simd
#endif

/// Edge in the mesh adjacency graph
public struct Edge: Hashable {
    public let triangle1: Int
    public let triangle2: Int
    
    public init(triangle1: Int, triangle2: Int) {
        self.triangle1 = triangle1
        self.triangle2 = triangle2
    }
}

/// Mesh adjacency graph for BFS propagation
/// Two triangles are neighbors if they share two vertices (an edge)
public final class MeshAdjacencyGraph {
    
    /// Adjacency list: triangle index → [neighbor triangle indices]
    private var adjacencyList: [Int: [Int]] = [:]
    
    /// Triangles array (for vertex access)
    private let triangles: [ScanTriangle]
    
    /// Floating-point tolerance for vertex comparison
    private let epsilon: Float = 1e-5
    
    public init(triangles: [ScanTriangle]) {
        self.triangles = triangles
        buildAdjacencyGraph()
    }
    
    /// Build adjacency graph by finding shared edges
    private func buildAdjacencyGraph() {
        adjacencyList = [:]
        
        for i in 0..<triangles.count {
            adjacencyList[i] = []
        }
        
        // Compare all pairs of triangles
        for i in 0..<triangles.count {
            for j in (i + 1)..<triangles.count {
                if shareEdge(triangle1: triangles[i], triangle2: triangles[j]) {
                    adjacencyList[i, default: []].append(j)
                    adjacencyList[j, default: []].append(i)
                }
            }
        }
    }
    
    /// Check if two triangles share an edge (two vertices)
    private func shareEdge(triangle1: ScanTriangle, triangle2: ScanTriangle) -> Bool {
        let (v1a, v1b, v1c) = triangle1.vertices
        let (v2a, v2b, v2c) = triangle2.vertices
        
        // Count shared vertices
        var sharedCount = 0
        
        let tri1Verts = [v1a, v1b, v1c]
        let tri2Verts = [v2a, v2b, v2c]
        
        for v1 in tri1Verts {
            for v2 in tri2Verts {
                if verticesEqual(v1, v2) {
                    sharedCount += 1
                    break
                }
            }
        }
        
        // Two triangles share an edge if they share exactly 2 vertices
        return sharedCount == 2
    }
    
    /// Check if two vertices are equal (within epsilon tolerance)
    private func verticesEqual(_ v1: SIMD3<Float>, _ v2: SIMD3<Float>) -> Bool {
        let diff = v1 - v2
        let distSq = dot(diff, diff)
        return distSq < epsilon * epsilon
    }
    
    /// Get neighbors of a triangle
    ///
    /// - Parameter triangleIndex: Triangle index
    /// - Returns: Array of neighbor triangle indices
    public func neighbors(of triangleIndex: Int) -> [Int] {
        return adjacencyList[triangleIndex] ?? []
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
        
        // Initialize sources at distance 0
        for source in sources {
            distances[source] = 0
            queue.append((source, 0))
            visited.insert(source)
        }
        
        // BFS
        var queueIndex = 0
        while queueIndex < queue.count {
            let (currentIndex, currentDist) = queue[queueIndex]
            queueIndex += 1
            
            if currentDist >= maxHops {
                continue
            }
            
            let neighbors = self.neighbors(of: currentIndex)
            for neighborIndex in neighbors {
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
        
        let edge0Len = length_squared(v1 - v0)
        let edge1Len = length_squared(v2 - v1)
        let edge2Len = length_squared(v0 - v2)
        
        if edge0Len >= edge1Len && edge0Len >= edge2Len {
            return (v0, v1)
        } else if edge1Len >= edge2Len {
            return (v1, v2)
        } else {
            return (v2, v0)
        }
    }
    
    /// Get total number of triangles
    public var triangleCount: Int {
        return triangles.count
    }
}
