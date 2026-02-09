//
// RenderingPlatformProtocol.swift
// Aether3D
//
// PR#7 Scan Guidance UI — Cross-Platform Rendering Protocol
// Pure protocol — Foundation only, compiles on macOS + Linux
// Phase 6: Cross-platform interface
//

import Foundation

#if canImport(simd)
import simd
#endif

/// Cross-platform rendering interface (for Android/HarmonyOS future ports)
/// This protocol allows platform-specific implementations while keeping Core/ code platform-agnostic
public protocol RenderingPlatformProtocol {
    
    /// Render wedge geometry
    /// - Parameters:
    ///   - vertices: Vertex data
    ///   - indices: Index data
    ///   - transform: Camera transform matrix
    func renderWedges(
        vertices: [WedgeVertexCPU],
        indices: [UInt32],
        transform: simd_float4x4
    )
    
    /// Render border strokes
    /// - Parameters:
    ///   - vertices: Vertex data
    ///   - borderWidths: Per-triangle border widths
    func renderBorders(
        vertices: [WedgeVertexCPU],
        borderWidths: [Float]
    )
    
    /// Apply lighting
    /// - Parameters:
    ///   - lightDirection: Primary light direction
    ///   - lightIntensity: Light intensity
    ///   - shCoefficients: Spherical harmonics coefficients (9 × RGB)
    func applyLighting(
        lightDirection: SIMD3<Float>,
        lightIntensity: Float,
        shCoefficients: [SIMD3<Float>]
    )
}

/// Default implementation (no-op for platforms without rendering)
public struct DefaultRenderingPlatform: RenderingPlatformProtocol {
    public init() {}
    
    public func renderWedges(
        vertices: [WedgeVertexCPU],
        indices: [UInt32],
        transform: simd_float4x4
    ) {
        // No-op: platform doesn't support rendering
    }
    
    public func renderBorders(
        vertices: [WedgeVertexCPU],
        borderWidths: [Float]
    ) {
        // No-op: platform doesn't support rendering
    }
    
    public func applyLighting(
        lightDirection: SIMD3<Float>,
        lightIntensity: Float,
        shCoefficients: [SIMD3<Float>]
    ) {
        // No-op: platform doesn't support rendering
    }
}
