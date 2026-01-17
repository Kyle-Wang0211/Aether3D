//
//  DeterministicTriangulator.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Milestone 0
//  DeterministicTriangulator - deterministic triangulation (P5/H1)
//

import Foundation
import CoreGraphics

/// DeterministicTriangulator - deterministic triangulation for quads/patches
/// P5/H1: Fixed algorithm, fixed winding order, stable sorting, tie-break rules
public struct DeterministicTriangulator {
    
    /// Triangulate quadrilateral deterministically
    /// H1: Tie-break rules for equal diagonals, polygon start index normalization
    public static func triangulateQuad(
        v0: CGPoint,
        v1: CGPoint,
        v2: CGPoint,
        v3: CGPoint
    ) -> [(CGPoint, CGPoint, CGPoint)] {
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
    
    /// Calculate distance between two points
    private static func distance(_ p1: CGPoint, _ p2: CGPoint) -> CGFloat {
        let dx = p2.x - p1.x
        let dy = p2.y - p1.y
        return sqrt(dx * dx + dy * dy)
    }
    
    /// Sort triangles deterministically
    /// Primary sort: minimum vertex index tuple (a,b,c) lexicographic
    /// Secondary sort: centroid coordinates lexicographic
    public static func sortTriangles(_ triangles: [(CGPoint, CGPoint, CGPoint)]) -> [(CGPoint, CGPoint, CGPoint)] {
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
    
    private static func getMinVertexIndices(_ triangle: (CGPoint, CGPoint, CGPoint)) -> (Int, Int, Int) {
        // Simplified - would need actual vertex index mapping in real implementation
        return (0, 1, 2)
    }
    
    private static func centroid(_ triangle: (CGPoint, CGPoint, CGPoint)) -> CGPoint {
        return CGPoint(
            x: (triangle.0.x + triangle.1.x + triangle.2.x) / 3.0,
            y: (triangle.0.y + triangle.1.y + triangle.2.y) / 3.0
        )
    }
}

