// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  DeterministicTriangulator.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Milestone 0
//  DeterministicTriangulator - deterministic triangulation (P5/H1)
//  Cross-platform: uses internal QPoint type (works on Linux and Apple platforms)
//

import Foundation
import CAetherNativeBridge
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
        var quad = [
            aether_point2d_t(x: v0.x, y: v0.y),
            aether_point2d_t(x: v1.x, y: v1.y),
            aether_point2d_t(x: v2.x, y: v2.y),
            aether_point2d_t(x: v3.x, y: v3.y),
        ]
        var outPoints = Array(repeating: aether_point2d_t(), count: 6)
        var outCount: Int32 = Int32(outPoints.count)
        let nativeRC = quad.withUnsafeMutableBufferPointer { quadPtr in
            outPoints.withUnsafeMutableBufferPointer { outPtr in
                aether_deterministic_triangulate_quad(
                    quadPtr.baseAddress,
                    QualityPreCheckConstants.FLOAT_COMPARISON_EPSILON,
                    outPtr.baseAddress,
                    &outCount
                )
            }
        }
        if nativeRC == 0 && outCount >= 6 {
            return [
                (
                    QPoint(x: outPoints[0].x, y: outPoints[0].y),
                    QPoint(x: outPoints[1].x, y: outPoints[1].y),
                    QPoint(x: outPoints[2].x, y: outPoints[2].y)
                ),
                (
                    QPoint(x: outPoints[3].x, y: outPoints[3].y),
                    QPoint(x: outPoints[4].x, y: outPoints[4].y),
                    QPoint(x: outPoints[5].x, y: outPoints[5].y)
                )
            ]
        }
        return [
            (v0, v1, v2),
            (v0, v2, v3)
        ]
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
    
    /// Sort triangles deterministically
    /// Primary sort: minimum vertex index tuple (a,b,c) lexicographic
    /// Secondary sort: centroid coordinates lexicographic
    /// H1: Stable sorting, deterministic across platforms
    public static func sortTriangles(_ triangles: [(QPoint, QPoint, QPoint)]) -> [(QPoint, QPoint, QPoint)] {
        if !triangles.isEmpty {
            var flatInput: [aether_point2d_t] = []
            flatInput.reserveCapacity(triangles.count * 3)
            for tri in triangles {
                flatInput.append(aether_point2d_t(x: tri.0.x, y: tri.0.y))
                flatInput.append(aether_point2d_t(x: tri.1.x, y: tri.1.y))
                flatInput.append(aether_point2d_t(x: tri.2.x, y: tri.2.y))
            }
            var flatOutput = Array(repeating: aether_point2d_t(), count: flatInput.count)
            let nativeRC = flatInput.withUnsafeBufferPointer { inPtr in
                flatOutput.withUnsafeMutableBufferPointer { outPtr in
                    aether_deterministic_sort_triangles(
                        inPtr.baseAddress,
                        Int32(triangles.count),
                        QualityPreCheckConstants.FLOAT_COMPARISON_EPSILON,
                        outPtr.baseAddress
                    )
                }
            }
            if nativeRC == 0 {
                var sorted: [(QPoint, QPoint, QPoint)] = []
                sorted.reserveCapacity(triangles.count)
                for idx in 0..<triangles.count {
                    let base = idx * 3
                    sorted.append((
                        QPoint(x: flatOutput[base].x, y: flatOutput[base].y),
                        QPoint(x: flatOutput[base + 1].x, y: flatOutput[base + 1].y),
                        QPoint(x: flatOutput[base + 2].x, y: flatOutput[base + 2].y)
                    ))
                }
                return sorted
            }
        }
        return triangles
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
    
}
