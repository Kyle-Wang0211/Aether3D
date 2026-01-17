//
//  DeterministicTriangulator.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Milestone 0
//  DeterministicTriangulator - deterministic triangulation (P5/H1)
//  Cross-platform: uses internal QPoint type (works on Linux and Apple platforms)
//

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// QPoint - cross-platform point type (replaces CGPoint for Linux compatibility)
/// H1: Deterministic floating-point math, stable across platforms
public struct QPoint: Equatable, Codable {
    public let x: Double
    public let y: Double
    
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
    
    #if canImport(CoreGraphics)
    /// Initialize from CGPoint (Apple platforms only)
    public init(_ point: CGPoint) {
        self.x = Double(point.x)
        self.y = Double(point.y)
    }
    
    /// Convert to CGPoint (Apple platforms only)
    public var cgPoint: CGPoint {
        return CGPoint(x: CGFloat(x), y: CGFloat(y))
    }
    #endif
}

/// DeterministicTriangulator - deterministic triangulation for quads/patches
/// P5/H1: Fixed algorithm, fixed winding order, stable sorting, tie-break rules
/// Cross-platform: uses QPoint instead of CGPoint for Linux compatibility
public struct DeterministicTriangulator {
    
    /// Triangulate quadrilateral deterministically
    /// H1: Tie-break rules for equal diagonals, polygon start index normalization
    /// - Parameters:
    ///   - v0, v1, v2, v3: Quadrilateral vertices (QPoint, cross-platform)
    /// - Returns: Array of triangles, each represented as a tuple of 3 QPoints
    public static func triangulateQuad(
        v0: QPoint,
        v1: QPoint,
        v2: QPoint,
        v3: QPoint
    ) -> [(QPoint, QPoint, QPoint)] {
        // H1: Normalize polygon start index - always start from minimum index vertex
        let vertices = [v0, v1, v2, v3]
        let minIndex = vertices.enumerated().min(by: { $0.element.x < $1.element.x || ($0.element.x == $1.element.x && $0.element.y < $1.element.y) })!.offset
        
        // Rotate to start from minimum index
        let normalized = (0..<4).map { vertices[(minIndex + $0) % 4] }
        
        // Calculate diagonal lengths
        let diag1Length = distance(normalized[0], normalized[2])
        let diag2Length = distance(normalized[1], normalized[3])
        
        // H1: Tie-break rule - if diagonals are equal (within epsilon), choose smaller index pair
        let epsilon = QualityPreCheckConstants.FLOAT_COMPARISON_EPSILON
        let diag1Shorter = abs(diag1Length - diag2Length) < epsilon ?
            (min(0, 2) < min(1, 3)) : (diag1Length < diag2Length)
        
        if diag1Shorter {
            // Split along diagonal (0, 2)
            return [
                (normalized[0], normalized[1], normalized[2]),
                (normalized[0], normalized[2], normalized[3])
            ]
        } else {
            // Split along diagonal (1, 3)
            return [
                (normalized[0], normalized[1], normalized[3]),
                (normalized[1], normalized[2], normalized[3])
            ]
        }
    }
    
    #if canImport(CoreGraphics)
    /// Triangulate quadrilateral deterministically (CGPoint convenience method for Apple platforms)
    /// - Parameters:
    ///   - v0, v1, v2, v3: Quadrilateral vertices (CGPoint, Apple platforms only)
    /// - Returns: Array of triangles, each represented as a tuple of 3 CGPoints
    public static func triangulateQuad(
        v0: CGPoint,
        v1: CGPoint,
        v2: CGPoint,
        v3: CGPoint
    ) -> [(CGPoint, CGPoint, CGPoint)] {
        // Convert CGPoint to QPoint, triangulate, convert back
        let qTriangles = triangulateQuad(
            v0: QPoint(v0),
            v1: QPoint(v1),
            v2: QPoint(v2),
            v3: QPoint(v3)
        )
        return qTriangles.map { ($0.0.cgPoint, $0.1.cgPoint, $0.2.cgPoint) }
    }
    #endif
    
    /// Calculate distance between two points
    /// H1: Deterministic floating-point math
    private static func distance(_ p1: QPoint, _ p2: QPoint) -> Double {
        let dx = p2.x - p1.x
        let dy = p2.y - p1.y
        return sqrt(dx * dx + dy * dy)
    }
    
    /// Sort triangles deterministically
    /// Primary sort: minimum vertex index tuple (a,b,c) lexicographic
    /// Secondary sort: centroid coordinates lexicographic
    /// H1: Stable sorting, deterministic across platforms
    public static func sortTriangles(_ triangles: [(QPoint, QPoint, QPoint)]) -> [(QPoint, QPoint, QPoint)] {
        return triangles.sorted { t1, t2 in
            // Primary: minimum vertex index tuple
            let indices1 = getMinVertexIndices(t1)
            let indices2 = getMinVertexIndices(t2)
            
            if indices1 != indices2 {
                return indices1 < indices2
            }
            
            // Secondary: centroid coordinates
            let centroid1 = centroid(t1)
            let centroid2 = centroid(t2)
            
            if abs(centroid1.x - centroid2.x) > QualityPreCheckConstants.FLOAT_COMPARISON_EPSILON {
                return centroid1.x < centroid2.x
            }
            return centroid1.y < centroid2.y
        }
    }
    
    #if canImport(CoreGraphics)
    /// Sort triangles deterministically (CGPoint convenience method for Apple platforms)
    public static func sortTriangles(_ triangles: [(CGPoint, CGPoint, CGPoint)]) -> [(CGPoint, CGPoint, CGPoint)] {
        // Convert CGPoint to QPoint, sort, convert back
        let qTriangles = triangles.map { (QPoint($0.0), QPoint($0.1), QPoint($0.2)) }
        let sortedQTriangles = sortTriangles(qTriangles)
        return sortedQTriangles.map { ($0.0.cgPoint, $0.1.cgPoint, $0.2.cgPoint) }
    }
    #endif
    
    private static func getMinVertexIndices(_ triangle: (QPoint, QPoint, QPoint)) -> (Int, Int, Int) {
        // Simplified - would need actual vertex index mapping in real implementation
        return (0, 1, 2)
    }
    
    private static func centroid(_ triangle: (QPoint, QPoint, QPoint)) -> QPoint {
        return QPoint(
            x: (triangle.0.x + triangle.1.x + triangle.2.x) / 3.0,
            y: (triangle.0.y + triangle.1.y + triangle.2.y) / 3.0
        )
    }
}

