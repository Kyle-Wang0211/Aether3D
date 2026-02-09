//
// ScanTriangle.swift
// Aether3D
//
// PR#7 Scan Guidance UI — Triangle Data Type
// Pure data type — Foundation + simd only
//

import Foundation
#if canImport(simd)
import simd
#endif

/// Triangle data from ARKit mesh
public struct ScanTriangle: Sendable {
    /// Patch identifier
    public let patchId: String
    
    /// Three vertices of the triangle
    public let vertices: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)
    
    /// Triangle normal vector
    public let normal: SIMD3<Float>
    
    /// Triangle area in square meters
    public let areaSqM: Float
    
    public init(
        patchId: String,
        vertices: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>),
        normal: SIMD3<Float>,
        areaSqM: Float
    ) {
        self.patchId = patchId
        self.vertices = vertices
        self.normal = normal
        self.areaSqM = areaSqM
    }
}
